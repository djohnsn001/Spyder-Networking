-- Account deletion: make "delete the auth user" remove everything except
-- anonymized safety reports.
-- Plan: docs/plans/legal-compliance.md (Phase 4.1), plus flags M4 and M10
-- from docs/legal/data-inventory.md.
--
-- Checked every foreign key to profiles (Phase 0 table in the inventory):
-- everything already cascades or sets null except event_reports, fixed
-- below. Chats are deleted for both people when either account is deleted
-- (conversations.user_a_id / user_b_id cascade) — Zane's call on open
-- question 2, 2026-09-28: no change needed.
--
-- The avatar files are deleted by the delete-account Edge Function through
-- the Storage API, before it deletes the auth user.

-- ---------------------------------------------------------------------------
-- Event reports survive account and event deletion (M10)
-- ---------------------------------------------------------------------------

-- A copy of the event at report time, so the report still means something
-- after the event (or its host) is gone.
alter table public.event_reports add column snapshot jsonb;

update public.event_reports r
set snapshot = jsonb_build_object(
  'title', e.title,
  'description', e.description,
  'visibility', e.visibility,
  'starts_at', e.starts_at,
  'creator_id', e.creator_id,
  'creator_username', p.username
)
from public.events e
join public.profiles p on p.id = e.creator_id
where e.id = r.event_id;

alter table public.event_reports
  alter column event_id drop not null,
  alter column reporter_id drop not null,
  drop constraint event_reports_event_id_fkey,
  drop constraint event_reports_reporter_id_fkey,
  add constraint event_reports_event_id_fkey
    foreign key (event_id) references public.events (id) on delete set null,
  add constraint event_reports_reporter_id_fkey
    foreign key (reporter_id) references public.profiles (id) on delete set null;

-- Same as 20260928020000, plus the snapshot.
create or replace function public.report_event(p_event_id uuid, p_reason text, p_details text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  v_me uuid := auth.uid();
  v_admin boolean := public.is_admin();
  v_event public.events%rowtype;
  v_details text := nullif(btrim(p_details), '');
  v_recent int;
  v_counted int;
  v_hidden boolean := false;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if public.is_suspended(v_me) then
    return jsonb_build_object('outcome', 'not_allowed');
  end if;

  -- Locked so two reports at once can't both miss the auto-hide.
  select * into v_event from public.events where id = p_event_id for update;

  -- Definer functions skip RLS, so repeat the events select policy by hand.
  if not found or not (
    v_admin
    or v_event.creator_id = v_me
    or (
      v_event.status = 'active'
      and (v_event.visibility = 'public' or public.is_connected_to(v_event.creator_id))
      and not public._blocked_between(v_me, v_event.creator_id)
      and not public.is_suspended(v_event.creator_id)
    )
  ) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if v_event.creator_id = v_me then
    return jsonb_build_object('outcome', 'self');
  end if;

  if p_reason is null or p_reason not in (
    'spam', 'selling_or_scam', 'unsafe_location', 'harassment', 'inappropriate', 'fake', 'other'
  ) then
    return jsonb_build_object('outcome', 'invalid', 'field', 'reason');
  end if;
  if char_length(coalesce(v_details, '')) > 500 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'details');
  end if;

  if exists (select 1 from public.event_reports where event_id = p_event_id and reporter_id = v_me) then
    return jsonb_build_object('outcome', 'already_reported');
  end if;

  if not v_admin then
    select count(*) into v_recent
    from public.event_reports
    where reporter_id = v_me and created_at > now() - interval '24 hours';
    if v_recent >= (r ->> 'max_reports_per_day')::int then
      return jsonb_build_object('outcome', 'rate_limited', 'limit', r -> 'max_reports_per_day');
    end if;
  end if;

  insert into public.event_reports (event_id, reporter_id, reason, details, snapshot)
  values (
    p_event_id, v_me, p_reason, v_details,
    jsonb_build_object(
      'title', v_event.title,
      'description', v_event.description,
      'visibility', v_event.visibility,
      'starts_at', v_event.starts_at,
      'creator_id', v_event.creator_id,
      'creator_username', (select username from public.profiles where id = v_event.creator_id)
    )
  )
  on conflict (event_id, reporter_id) do nothing;

  -- Only reports from accounts old enough count, so a handful of brand-new
  -- accounts can't knock an event off the map. Age comes from auth.users
  -- (see _account_created_at).
  select count(*) into v_counted
  from public.event_reports er
  where er.event_id = p_event_id
    and er.status = 'open'
    and public._account_created_at(er.reporter_id)
        <= now() - make_interval(days => (r ->> 'reporter_min_account_age_days')::int);

  if v_event.status = 'active' and v_counted >= (r ->> 'auto_hide_reports')::int then
    update public.events set status = 'hidden' where id = p_event_id;
    v_hidden := true;
  end if;

  return jsonb_build_object('outcome', 'reported', 'hidden', v_hidden);
end;
$$;

revoke execute on function public.report_event(uuid, text, text) from public, anon;
grant execute on function public.report_event(uuid, text, text) to authenticated;

-- Same as 20260927070000, except reports whose reporter deleted their
-- account still count toward the list (left join; reporter_username null).
create or replace function public.admin_list_flagged_events()
returns table (
  event_id uuid,
  title text,
  description text,
  status text,
  visibility text,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz,
  going_count integer,
  creator_id uuid,
  creator_username text,
  creator_full_name text,
  host_status text,
  latitude double precision,
  longitude double precision,
  location_name text,
  open_reports integer,
  counted_reports integer,
  reports_by_reason jsonb,
  latest_report_at timestamptz,
  recent_reports jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_min_age interval := make_interval(
    days => (public._event_rules() ->> 'reporter_min_account_age_days')::int
  );
begin
  perform public._require_admin();

  return query
  with open_reports as (
    select er.*, pr.username as reporter_username,
      coalesce(public._account_created_at(er.reporter_id) <= now() - v_min_age, false) as counts
    from public.event_reports er
    left join public.profiles pr on pr.id = er.reporter_id
    where er.status = 'open'
  )
  select
    e.id,
    e.title,
    e.description,
    e.status,
    e.visibility,
    e.starts_at,
    e.ends_at,
    e.created_at,
    e.going_count,
    e.creator_id,
    p.username,
    p.full_name,
    h.status,
    l.latitude,
    l.longitude,
    l.location_name,
    coalesce(agg.open_reports, 0)::integer,
    coalesce(agg.counted_reports, 0)::integer,
    coalesce(agg.by_reason, '{}'::jsonb),
    agg.latest_at,
    coalesce(agg.recent, '[]'::jsonb)
  from public.events e
  join public.profiles p on p.id = e.creator_id
  left join public.host_permissions h on h.user_id = e.creator_id
  left join public.event_locations l on l.event_id = e.id
  left join lateral (
    select
      count(*) as open_reports,
      count(*) filter (where o.counts) as counted_reports,
      max(o.created_at) as latest_at,
      (
        select jsonb_object_agg(x.reason, x.n)
        from (select o2.reason, count(*) as n from open_reports o2 where o2.event_id = e.id group by o2.reason) x
      ) as by_reason,
      (
        select jsonb_agg(jsonb_build_object(
          'reason', y.reason,
          'details', y.details,
          'reporter_username', y.reporter_username,
          'counts', y.counts,
          'created_at', y.created_at
        ) order by y.created_at desc)
        from (select * from open_reports o3 where o3.event_id = e.id order by o3.created_at desc limit 5) y
      ) as recent
    from open_reports o
    where o.event_id = e.id
  ) agg on true
  where e.status = 'hidden' or coalesce(agg.open_reports, 0) > 0
  order by agg.latest_at desc nulls last, e.created_at desc;
end;
$$;

revoke execute on function public.admin_list_flagged_events() from public, anon;
grant execute on function public.admin_list_flagged_events() to authenticated;

-- Same as 20260928000000, except old events are now kept only while they
-- have an OPEN report: resolved reports survive the event (set null +
-- snapshot), so they no longer need the event kept around.
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
  -- (cascade), unless a report is still waiting for an admin.
  delete from public.events e
  where coalesce(e.ends_at, e.starts_at + interval '3 hours') < now() - interval '30 days'
    and not exists (
      select 1 from public.event_reports r where r.event_id = e.id and r.status = 'open'
    );
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

-- ---------------------------------------------------------------------------
-- Avatars: nobody can list other people's files (M4)
-- ---------------------------------------------------------------------------

-- The bucket is public, so photo URLs keep working without any select
-- policy. The old policy (no role limit) also let anyone with the app's
-- public key LIST every file in the bucket, including old photos.
-- Owners still need select on their own folder: the Storage API checks it
-- when they delete a file (replacing a photo deletes the old one).
drop policy "Avatar images are publicly accessible" on storage.objects;

create policy "Users can see their own avatar files"
  on storage.objects
  for select
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
