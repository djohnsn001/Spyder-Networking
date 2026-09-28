-- Safer map events, part 2: approximate location until you RSVP.
-- Plan: docs/plans/event-safety.md (Phase 2).
--
-- The exact pin and place name move out of events into event_locations,
-- which only the host, people who tapped Going, and admins can read.
-- Everyone else gets approx_latitude / approx_longitude: the real spot moved
-- 150–350 m in a random direction. The app draws a 400 m circle around it,
-- so the real spot is always inside the circle.
--
-- The fuzzed point is picked ONCE, at create time, and stored. Since the
-- location can never change, nobody can make the server re-fuzz an event
-- and average many answers to find the real spot.

-- ---------------------------------------------------------------------------
-- Exact locations
-- ---------------------------------------------------------------------------

create table public.event_locations (
  event_id uuid primary key references public.events (id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location_name text check (char_length(location_name) <= 100)
);

alter table public.event_locations enable row level security;

-- No recursion: the events and event_attendees policies never read
-- event_locations.
create policy "Exact location for host, admins and attendees"
  on public.event_locations
  for select
  to authenticated
  using (
    public.is_admin()
    or exists (
      select 1 from public.events e
      where e.id = event_locations.event_id and e.creator_id = auth.uid()
    )
    or exists (
      select 1 from public.event_attendees a
      where a.event_id = event_locations.event_id and a.user_id = auth.uid()
    )
  );
-- No insert/update/delete policies: only create_event writes here.

grant select on public.event_locations to anon;
grant select, insert, update, delete on public.event_locations to authenticated;
grant select, insert, update, delete on public.event_locations to service_role;

-- ---------------------------------------------------------------------------
-- Fuzzing
-- ---------------------------------------------------------------------------

-- A random bearing and a random distance between fuzz_min_m and fuzz_max_m.
-- Meters-per-degree uses the same Earth radius as _distance_m (6,371 km), so
-- the offset measures the same way everywhere else in the database.
create or replace function public._fuzz_point(p_lat double precision, p_lng double precision)
returns table (lat double precision, lng double precision)
language plpgsql
volatile
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  c_m_per_degree constant double precision := 6371000 * pi() / 180;
  v_min double precision := (r ->> 'fuzz_min_m')::double precision;
  v_max double precision := (r ->> 'fuzz_max_m')::double precision;
  v_bearing double precision := random() * 2 * pi();
  v_distance double precision := v_min + random() * (v_max - v_min);
begin
  lat := p_lat + v_distance * cos(v_bearing) / c_m_per_degree;
  -- A degree of longitude shrinks toward the poles. greatest() keeps this
  -- finite right at a pole (not that anyone's hosting a meetup there).
  lng := p_lng + v_distance * sin(v_bearing)
    / (c_m_per_degree * greatest(cos(radians(p_lat)), 0.01));

  lat := least(greatest(lat, -90), 90);
  if lng > 180 then
    lng := lng - 360;
  elsif lng < -180 then
    lng := lng + 360;
  end if;
  return next;
end;
$$;

revoke execute on function public._fuzz_point(double precision, double precision)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Backfill and cleanup (order matters)
-- ---------------------------------------------------------------------------

-- 1. The view depends on the old columns.
drop view public.event_summaries;

-- 2. Copy every exact spot across.
insert into public.event_locations (event_id, latitude, longitude, location_name)
select id, latitude, longitude, location_name from public.events;

-- 3. Fuzz every existing event once.
alter table public.events
  add column approx_latitude double precision check (approx_latitude between -90 and 90),
  add column approx_longitude double precision check (approx_longitude between -180 and 180);

update public.events e
set (approx_latitude, approx_longitude) = (
  select f.lat, f.lng from public._fuzz_point(e.latitude, e.longitude) f
);

alter table public.events
  alter column approx_latitude set not null,
  alter column approx_longitude set not null;

-- The map asks for "events inside this rectangle" — latitude first since
-- that's the range the index can narrow on directly.
create index events_approx_lat_lng_idx on public.events (approx_latitude, approx_longitude);

-- 4. The exact values now live only in event_locations.
drop index if exists public.events_lat_lng_idx;
alter table public.events
  drop column latitude,
  drop column longitude,
  drop column location_name;

-- ---------------------------------------------------------------------------
-- create_event: same rules as part 1, now writing the exact spot to
-- event_locations and only the fuzzed one to events
-- ---------------------------------------------------------------------------

create or replace function public.create_event(
  p_title text,
  p_description text,
  p_location_name text,
  p_latitude double precision,
  p_longitude double precision,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_visibility text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  v_me uuid := auth.uid();
  v_status jsonb;
  v_field text;
  v_recent int;
  v_id uuid;
  v_approx record;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- One create at a time per person, so two taps at once can't both slip
  -- under the limits.
  perform pg_advisory_xact_lock(hashtextextended('bolas.create_event:' || v_me::text, 0));

  v_status := public._hosting_status(v_me);

  if not coalesce((v_status ->> 'can_host')::boolean, false) then
    return jsonb_build_object('outcome', 'not_allowed', 'reason', v_status -> 'reason');
  end if;

  if p_visibility = 'public' and not coalesce((v_status ->> 'can_host_public')::boolean, false) then
    return v_status || jsonb_build_object('outcome', 'public_locked');
  end if;

  v_field := public._event_invalid_field(
    p_title, p_description, p_starts_at, p_ends_at, p_visibility, true, true
  );
  if v_field is null and char_length(btrim(coalesce(p_location_name, ''))) > 100 then
    v_field := 'location_name';
  end if;
  if v_field is null and (
    p_latitude is null or p_longitude is null
    or p_latitude not between -90 and 90
    or p_longitude not between -180 and 180
  ) then
    v_field := 'location';
  end if;
  if v_field is not null then
    return jsonb_build_object('outcome', 'invalid', 'field', v_field);
  end if;

  if public._event_text_blocked(p_title || ' ' || coalesce(p_description, '')) then
    return jsonb_build_object('outcome', 'blocked_content');
  end if;

  if not coalesce((v_status ->> 'is_admin')::boolean, false) then
    if (v_status ->> 'active_events')::int >= (r ->> 'max_active_events')::int then
      return jsonb_build_object('outcome', 'too_many_active', 'limit', r -> 'max_active_events');
    end if;

    select count(*) into v_recent
    from public.event_creation_log l
    where l.creator_id = v_me and l.created_at > now() - interval '24 hours';
    if v_recent >= (r ->> 'max_creates_per_day')::int then
      return jsonb_build_object('outcome', 'rate_limited', 'limit', r -> 'max_creates_per_day');
    end if;
  end if;

  select f.lat, f.lng into v_approx from public._fuzz_point(p_latitude, p_longitude) f;

  -- handle_new_event (trigger) adds the host as attending.
  insert into public.events
    (creator_id, title, description, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (
    v_me,
    btrim(p_title),
    nullif(btrim(p_description), ''),
    v_approx.lat,
    v_approx.lng,
    p_starts_at,
    p_ends_at,
    p_visibility
  )
  returning id into v_id;

  insert into public.event_locations (event_id, latitude, longitude, location_name)
  values (v_id, p_latitude, p_longitude, nullif(btrim(p_location_name), ''));

  insert into public.event_creation_log (creator_id, event_id) values (v_me, v_id);

  return jsonb_build_object('outcome', 'created', 'event_id', v_id);
end;
$$;

-- create or replace keeps the grants from part 1; restated so this file
-- reads correctly on its own.
revoke execute on function
  public.create_event(text, text, text, double precision, double precision, timestamptz, timestamptz, text)
  from public, anon;
grant execute on function
  public.create_event(text, text, text, double precision, double precision, timestamptz, timestamptz, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- event_summaries, rebuilt
-- ---------------------------------------------------------------------------

-- What the app reads: each event plus its creator, attendee count, whether
-- the caller is going, and effective_ends_at (events without an end time
-- count as over 3 hours after they start).
--
-- approx_* is always there. exact_* and location_name come from a LEFT JOIN
-- on event_locations, whose RLS hides rows you can't see — so for everyone
-- but the host, people going, and admins they're simply null.
--
-- security_invoker makes the view run as the caller, so every RLS policy
-- still applies — it can never show more than the tables would.
create view public.event_summaries
with (security_invoker = true)
as
select
  e.id,
  e.creator_id,
  e.title,
  e.description,
  e.approx_latitude,
  e.approx_longitude,
  l.latitude as exact_latitude,
  l.longitude as exact_longitude,
  l.location_name,
  e.starts_at,
  e.ends_at,
  e.visibility,
  e.status,
  e.time_changed_at,
  e.created_at,
  e.updated_at,
  coalesce(e.ends_at, e.starts_at + interval '3 hours') as effective_ends_at,
  p.username as creator_username,
  p.full_name as creator_full_name,
  p.avatar_url as creator_avatar_url,
  -- Replaced by a stored going_count in part 3, once attendee rows go private.
  (select count(*) from public.event_attendees a where a.event_id = e.id)::integer as attendee_count,
  exists (
    select 1 from public.event_attendees a
    where a.event_id = e.id and a.user_id = auth.uid()
  ) as is_going
from public.events e
join public.profiles p on p.id = e.creator_id
left join public.event_locations l on l.event_id = e.id;

revoke all on public.event_summaries from anon;
grant select on public.event_summaries to authenticated;
