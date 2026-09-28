-- Data retention and map-location defaults.
-- Plan: docs/plans/legal-compliance.md (Phase 1b, added after the Phase 1
-- minimization review; flags M2, M5, M7, M8, M11 in docs/legal/data-inventory.md).
--
-- 1. A cleanup job runs every minute (Supabase Cron / pg_cron). Before this,
--    old tap coordinates, QR codes and log rows were only swept when someone
--    else happened to tap or make a code, so "deleted within minutes" wasn't
--    guaranteed.
-- 2. Web Map location: new accounts start hidden, the server refuses to keep
--    a location while sharing is off, turning sharing off deletes the saved
--    spot, and saved spots expire after 7 days without an update. Existing
--    accounts keep their current setting (Zane's call, 2026-09-28).

-- ---------------------------------------------------------------------------
-- Map location
-- ---------------------------------------------------------------------------

alter table public.profiles alter column location_sharing set default 'off';

-- Grid the saved position is snapped to. 0.02° of latitude (~2.2 km) by
-- 0.03° of longitude (~2.4 km around Boise) is ~5 km² — over Google Play's
-- 3 km² line, so it counts as "approximate location" for both stores. (The
-- cell shrinks toward the poles; it stays over 3 km² up to ~65° latitude.)
create or replace function public._coarsen_location(p_lat double precision, p_lng double precision)
returns table (lat double precision, lng double precision)
language sql
immutable
set search_path = public
as $$
  select
    (round((p_lat / 0.02)::numeric) * 0.02)::double precision,
    (round((p_lng / 0.03)::numeric) * 0.03)::double precision;
$$;

revoke execute on function public._coarsen_location(double precision, double precision)
  from public, anon, authenticated;

-- Same signature as before. Now: signed in only, coarser grid, and nothing
-- is kept while the caller's sharing is off (any leftover row is deleted),
-- so even an old app build can't store a hidden user's location.
create or replace function public.update_my_location(lat double precision, lng double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_sharing text;
  v_cell record;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if lat < -90 or lat > 90 or lng < -180 or lng > 180 then
    raise exception 'invalid coordinates';
  end if;

  select p.location_sharing into v_sharing from public.profiles p where p.id = v_me;

  if v_sharing is distinct from 'connections' then
    delete from public.user_locations where user_id = v_me;
    return;
  end if;

  select c.lat, c.lng into v_cell from public._coarsen_location(lat, lng) c;

  insert into public.user_locations (user_id, lat, lng, updated_at)
  values (v_me, v_cell.lat, v_cell.lng, now())
  on conflict (user_id)
  do update set lat = excluded.lat, lng = excluded.lng, updated_at = excluded.updated_at;
end;
$$;

revoke execute on function public.update_my_location(double precision, double precision) from anon, public;
grant execute on function public.update_my_location(double precision, double precision) to authenticated;

-- Turning sharing off deletes the saved spot right away. Security definer
-- because clients have no delete rights on user_locations.
create or replace function public.handle_location_sharing_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.location_sharing = 'off' then
    delete from public.user_locations where user_id = new.id;
  end if;
  return new;
end;
$$;

revoke execute on function public.handle_location_sharing_change() from public, anon, authenticated;

create trigger on_location_sharing_changed
  after update of location_sharing on public.profiles
  for each row
  when (new.location_sharing is distinct from old.location_sharing)
  execute function public.handle_location_sharing_change();

-- Existing rows: drop anyone who's hidden, and re-snap the rest to the
-- coarser grid.
delete from public.user_locations ul
using public.profiles p
where p.id = ul.user_id and p.location_sharing <> 'connections';

update public.user_locations ul
set (lat, lng) = (select c.lat, c.lng from public._coarsen_location(ul.lat, ul.lng) c);

-- ---------------------------------------------------------------------------
-- Cleanup job
-- ---------------------------------------------------------------------------

-- Every number here is a promise in the privacy policy / data inventory.
-- Change them together. Returns how many rows each step touched (handy in
-- the SQL editor: select public._retention_sweep();).
create or replace function public._retention_sweep()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  n_bump_stale int;
  n_bump_deleted int;
  n_tokens int;
  n_events int;
  n_creation_log int;
  n_rsvp_log int;
  n_undo int;
  n_locations int;
begin
  -- Taps nobody polled (app closed mid-tap). Matching only looks back 2 s
  -- and get_bump_result gives up after 3 s, so a minute is well past both.
  update public.bump_events
  set status = 'no_match', lat = null, lng = null
  where status = 'waiting' and created_at < now() - interval '1 minute';
  get diagnostics n_bump_stale = row_count;

  delete from public.bump_events where created_at < now() - interval '10 minutes';
  get diagnostics n_bump_deleted = row_count;

  delete from public.connect_tokens where created_at < now() - interval '1 hour';
  get diagnostics n_tokens = row_count;

  -- Events 30 days after they ended, with their exact spot and RSVPs
  -- (cascade). Events with ANY report are kept for now: reports still
  -- cascade-delete with their event until Phase 4 changes that (flag M10).
  delete from public.events e
  where coalesce(e.ends_at, e.starts_at + interval '3 hours') < now() - interval '30 days'
    and not exists (select 1 from public.event_reports r where r.event_id = e.id);
  get diagnostics n_events = row_count;

  -- Rate-limit logs: the limits only look back 24 hours.
  delete from public.event_creation_log where created_at < now() - interval '7 days';
  get diagnostics n_creation_log = row_count;

  delete from public.event_rsvp_log where created_at < now() - interval '7 days';
  get diagnostics n_rsvp_log = row_count;

  -- Undo info after the undo window. connections_guard only lets trusted
  -- functions touch these columns.
  perform set_config('bolas.trusted_write', 'on', true);
  update public.connections
  set undo_until = null, undo_snapshot = null
  where undo_until < now() - interval '1 minute';
  get diagnostics n_undo = row_count;
  perform set_config('bolas.trusted_write', 'off', true);

  -- Map spots not refreshed for a week (the app refreshes on every Map visit).
  delete from public.user_locations where updated_at < now() - interval '7 days';
  get diagnostics n_locations = row_count;

  return jsonb_build_object(
    'bump_stale', n_bump_stale,
    'bump_deleted', n_bump_deleted,
    'connect_tokens', n_tokens,
    'events', n_events,
    'event_creation_log', n_creation_log,
    'event_rsvp_log', n_rsvp_log,
    'undo_cleared', n_undo,
    'user_locations', n_locations
  );
end;
$$;

revoke execute on function public._retention_sweep() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;

-- Same job name again updates it in place rather than adding a second one.
select cron.schedule('bolas-retention-sweep', '* * * * *', $$select public._retention_sweep()$$);
