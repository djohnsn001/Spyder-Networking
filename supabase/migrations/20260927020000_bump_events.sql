-- Phone bumps for connecting in person.
--
-- Each phone detects the physical tap with its accelerometer and calls
-- submit_bump() with its (already-prefetched) location. The server pairs two
-- bumps that arrived within a couple of seconds of each other (server time —
-- phone clocks drift) and close enough on the map.
--
-- Privacy: this table is the only place raw GPS ever lands. Coordinates are
-- erased as soon as a bump stops waiting (matched / ambiguous / no_match),
-- and every row is deleted after 10 minutes. connections only ever gets the
-- city name.

create table public.bump_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default clock_timestamp(),
  -- Null once the bump is no longer waiting.
  lat double precision check (lat between -90 and 90),
  lng double precision check (lng between -180 and 180),
  accuracy_m real not null check (accuracy_m > 0),
  city text check (city is null or char_length(city) <= 80),
  status text not null default 'waiting'
    check (status in ('waiting', 'matched', 'ambiguous', 'no_match')),
  matched_user_id uuid references public.profiles (id) on delete set null,
  -- What this bump's owner reads back (outcome + the other person).
  result jsonb,
  constraint bump_events_coords_together check ((lat is null) = (lng is null)),
  constraint bump_events_waiting_has_coords check (status <> 'waiting' or lat is not null)
);

create index bump_events_waiting_idx on public.bump_events (created_at) where status = 'waiting';
create index bump_events_user_idx on public.bump_events (user_id, created_at desc);

-- RLS on with no policies: only the functions below touch this table.
alter table public.bump_events enable row level security;

grant select on public.bump_events to anon;
grant select, insert, update, delete on public.bump_events to authenticated;
grant select, insert, update, delete on public.bump_events to service_role;

-- Called the moment a phone detects a bump.
-- Returns { status, bump_id, ... }:
--   'waiting'       -> no partner yet; poll get_bump_result(bump_id)
--   'matched'       -> connected; includes _connect_in_person's result plus
--                      other_user_id and other_profile
--   'ambiguous'     -> several people bumped nearby at once; use QR instead
--   'poor_location' -> GPS accuracy too poor to match safely (no bump_id)
--   'rate_limited'  -> too many bumps this minute (no bump_id)
--
-- Known limitation: if a third person bumps within the window *after* A and B
-- already matched, that can't be detected. The match card's Undo covers it.
create or replace function public.submit_bump(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m double precision,
  p_city text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunables.
  c_window constant interval := interval '2 seconds';  -- max gap between the two bumps (server time)
  c_min_radius_m constant float8 := 100;                -- always allow at least this distance
  c_max_radius_m constant float8 := 500;                -- never allow more than this
  c_max_accuracy_m constant float8 := 1000;             -- worse GPS than this -> poor_location
  c_max_per_minute constant int := 10;
  c_retention constant interval := interval '10 minutes';

  v_me uuid := auth.uid();
  v_now timestamptz;
  v_id uuid;
  v_city text := nullif(left(trim(coalesce(p_city, '')), 80), '');
  v_other public.bump_events%rowtype;
  v_candidate_ids uuid[];
  v_candidates int;
  v jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_lat is null or p_lng is null or p_lat not between -90 and 90
     or p_lng not between -180 and 180 or p_accuracy_m is null or p_accuracy_m <= 0 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;

  if p_accuracy_m > c_max_accuracy_m then
    return jsonb_build_object('status', 'poor_location');
  end if;

  -- Privacy housekeeping: raw GPS never outlives this.
  delete from public.bump_events where created_at < now() - c_retention;

  if (
    select count(*) from public.bump_events
    where user_id = v_me and created_at > now() - interval '1 minute'
  ) >= c_max_per_minute then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  -- Matching runs one bump at a time so two bumps can't both claim the same
  -- partner. One global lock is fine at this scale; at large scale this should
  -- become a lock per geographic grid cell.
  perform pg_advisory_xact_lock(hashtext('bolas_bump_match'));

  v_now := clock_timestamp();

  insert into public.bump_events (user_id, created_at, lat, lng, accuracy_m, city)
  values (v_me, v_now, p_lat, p_lng, p_accuracy_m, v_city)
  returning id into v_id;

  -- Other people's waiting bumps from the last couple of seconds, within a
  -- radius that grows with how unsure both GPS fixes are (indoor GPS is poor).
  select coalesce(array_agg(b.id), '{}'), count(distinct b.user_id)
  into v_candidate_ids, v_candidates
  from public.bump_events b
  where b.status = 'waiting'
    and b.user_id <> v_me
    and b.created_at >= v_now - c_window
    and public._distance_m(p_lat, p_lng, b.lat, b.lng)
        <= greatest(c_min_radius_m, least(c_max_radius_m, p_accuracy_m + b.accuracy_m));

  if v_candidates = 0 then
    return jsonb_build_object('status', 'waiting', 'bump_id', v_id);
  end if;

  if v_candidates > 1 then
    update public.bump_events set status = 'ambiguous', lat = null, lng = null
    where id = v_id or id = any(v_candidate_ids);
    return jsonb_build_object('status', 'ambiguous', 'bump_id', v_id);
  end if;

  -- Exactly one other person: take their most recent waiting bump.
  select * into v_other
  from public.bump_events
  where id = any(v_candidate_ids)
  order by created_at desc
  limit 1;

  v := public._connect_in_person(
    v_me,
    v_other.user_id,
    'bump',
    coalesce(
      v_city,
      v_other.city,
      nullif(trim((select city from public.profiles where id = v_me)), ''),
      nullif(trim((select city from public.profiles where id = v_other.user_id)), '')
    )
  );

  -- Each side's result names the other person. Coordinates go now.
  update public.bump_events set
    status = 'matched', matched_user_id = v_other.user_id, lat = null, lng = null,
    result = v || jsonb_build_object(
      'other_user_id', v_other.user_id,
      'other_profile', public._profile_card(v_other.user_id)
    )
  where id = v_id;

  update public.bump_events set
    status = 'matched', matched_user_id = v_me, lat = null, lng = null,
    result = v || jsonb_build_object(
      'other_user_id', v_me,
      'other_profile', public._profile_card(v_me)
    )
  where id = v_other.id;

  return jsonb_build_object('status', 'matched', 'bump_id', v_id)
    || (select result from public.bump_events where id = v_id);
end;
$$;

-- Polled (~400ms) by a phone whose bump came back 'waiting'.
-- Returns { status: 'waiting' | 'matched' | 'ambiguous' | 'no_match' | 'not_found', bump_id, ... }.
-- A bump still unmatched after 3 seconds becomes no_match. Owner only.
create or replace function public.get_bump_result(p_bump_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_result_wait constant interval := interval '3 seconds';
  v_bump public.bump_events%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_bump
  from public.bump_events
  where id = p_bump_id and user_id = auth.uid()
  for update;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if v_bump.status = 'waiting' and clock_timestamp() > v_bump.created_at + c_result_wait then
    update public.bump_events set status = 'no_match', lat = null, lng = null
    where id = v_bump.id;
    v_bump.status := 'no_match';
  end if;

  return jsonb_build_object('status', v_bump.status, 'bump_id', v_bump.id)
    || coalesce(v_bump.result, '{}'::jsonb);
end;
$$;

revoke execute on function public.submit_bump(double precision, double precision, double precision, text) from anon, public;
revoke execute on function public.get_bump_result(uuid) from anon, public;
grant execute on function public.submit_bump(double precision, double precision, double precision, text) to authenticated;
grant execute on function public.get_bump_result(uuid) to authenticated;
