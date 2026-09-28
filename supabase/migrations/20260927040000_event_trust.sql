-- Safer map events, part 1: admins, hosting trust, and RPC-only writes.
-- Plan: docs/plans/event-safety.md (Phase 1).
--
-- Before this, any signed-in user could insert or update events directly,
-- so every rule lived only in the app. Now clients can't write to events at
-- all. create_event / update_event (security definer) check every rule and
-- are the only way in. Deleting your own event stays a plain delete.
--
-- Public events need earned trust: not suspended, and either an admin, or
-- approved by one, or an account 7+ days old with 3+ in-person connections.
-- Anyone with a username can still post connections-only events.

-- ---------------------------------------------------------------------------
-- Admins
-- ---------------------------------------------------------------------------

-- Added by hand in the SQL editor, never from the app:
--   insert into public.app_admins (user_id) values ('<uuid>');
create table public.app_admins (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- RLS on with no policies: unreachable from clients.
alter table public.app_admins enable row level security;

grant select on public.app_admins to anon;
grant select, insert, update, delete on public.app_admins to authenticated;
grant select, insert, update, delete on public.app_admins to service_role;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid());
$$;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------------
-- Host permissions: an admin's override of the automatic trust rule
-- ---------------------------------------------------------------------------

create table public.host_permissions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  status text not null check (status in ('approved', 'suspended')),
  note text check (char_length(note) <= 300),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);

alter table public.host_permissions enable row level security;

create policy "Users can see their own host status"
  on public.host_permissions
  for select
  to authenticated
  using (user_id = auth.uid());
-- No insert/update/delete policies: only admin RPCs (Phase 4) write here.

grant select on public.host_permissions to anon;
grant select, insert, update, delete on public.host_permissions to authenticated;
grant select, insert, update, delete on public.host_permissions to service_role;

-- ---------------------------------------------------------------------------
-- Tunable rules: every number in one place
-- ---------------------------------------------------------------------------

-- To change a rule, write a new migration that replaces this function.
create or replace function public._event_rules()
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'min_account_age_days', 7,            -- public hosting
    'min_in_person_connections', 3,       -- public hosting
    'max_active_events', 3,               -- per host: not yet ended, not removed
    'max_creates_per_day', 5,
    'max_days_ahead', 90,                 -- latest allowed starts_at
    'max_duration_hours', 24,
    'fuzz_min_m', 150,
    'fuzz_max_m', 350,
    'circle_radius_m', 400,               -- the app draws this
    'auto_hide_reports', 3,
    'reporter_min_account_age_days', 3,   -- for a report to count toward auto-hide
    'max_reports_per_day', 10,
    'max_rsvps_per_day', 30
  );
$$;

revoke execute on function public._event_rules() from public, anon, authenticated;

-- When the account was made. Deliberately read from auth.users, not
-- profiles.created_at: the profiles update policy lets a user edit any
-- column of their own row, so profiles.created_at could be backdated to skip
-- the waiting period. Nobody can edit auth.users from the app.
create or replace function public._account_created_at(p_uid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select created_at from auth.users where id = p_uid;
$$;

revoke execute on function public._account_created_at(uuid) from public, anon, authenticated;

-- Whether someone may host, and why not. Internal: the app gets its own via
-- get_my_hosting_status() below.
create or replace function public._hosting_status(p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  v_min_age int := (r ->> 'min_account_age_days')::int;
  v_min_in_person int := (r ->> 'min_in_person_connections')::int;
  v_max_active int := (r ->> 'max_active_events')::int;

  v_has_profile boolean;
  v_created timestamptz;
  v_age int := 0;
  v_in_person int := 0;
  v_active int := 0;
  v_host_status text;
  v_admin boolean;
  v_can_host boolean;
  v_can_public boolean;
  v_reason text;
begin
  select p.username is not null into v_has_profile
  from public.profiles p
  where p.id = p_uid;
  v_has_profile := coalesce(v_has_profile, false);

  v_created := public._account_created_at(p_uid);
  if v_created is not null then
    v_age := floor(extract(epoch from (now() - v_created)) / 86400)::int;
  end if;

  select count(*) into v_in_person
  from public.connections c
  where c.status = 'accepted'
    and c.level = 'in_person'
    and (c.requester_id = p_uid or c.addressee_id = p_uid);

  select count(*) into v_active
  from public.events e
  where e.creator_id = p_uid
    and e.status <> 'removed'
    and coalesce(e.ends_at, e.starts_at + interval '3 hours') > now();

  select h.status into v_host_status from public.host_permissions h where h.user_id = p_uid;
  v_admin := exists (select 1 from public.app_admins a where a.user_id = p_uid);

  -- "is [not] distinct from" rather than "=": v_host_status is null when an
  -- admin never set one, and null = 'approved' is null, not false — which
  -- would make can_host_public null and skip the public lock entirely.
  v_can_host := v_has_profile and v_host_status is distinct from 'suspended';
  v_can_public := v_can_host and (
    v_admin
    or v_host_status is not distinct from 'approved'
    or (v_age >= v_min_age and v_in_person >= v_min_in_person)
  );

  v_reason := case
    when v_host_status = 'suspended' then 'suspended'
    when not v_has_profile then 'no_profile'
    when v_can_public then null
    when v_age < v_min_age then 'new_account'   -- wins when both are short
    else 'needs_in_person'
  end;

  return jsonb_build_object(
    'can_host', v_can_host,
    'can_host_public', v_can_public,
    'reason', v_reason,
    'account_age_days', v_age,
    'in_person_count', v_in_person,
    'needed_in_person', v_min_in_person,
    'needed_age_days', v_min_age,
    'active_events', v_active,
    'max_active_events', v_max_active,
    'is_admin', v_admin
  );
end;
$$;

revoke execute on function public._hosting_status(uuid) from public, anon, authenticated;

create or replace function public.get_my_hosting_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public._hosting_status(auth.uid());
$$;

revoke execute on function public.get_my_hosting_status() from public, anon;
grant execute on function public.get_my_hosting_status() to authenticated;

-- ---------------------------------------------------------------------------
-- New columns on events
-- ---------------------------------------------------------------------------

alter table public.events
  -- active = shown normally, hidden = auto-hidden by reports and waiting for
  -- an admin, removed = taken down by an admin.
  add column status text not null default 'active'
    check (status in ('active', 'hidden', 'removed')),
  -- Set when an update moves starts_at / ends_at, so the app can flag it.
  add column time_changed_at timestamptz;

create index events_status_idx on public.events (status);

-- Only create_event inserts now and it always passes a visibility, but a
-- safe default costs nothing.
alter table public.events alter column visibility set default 'connections';

-- ---------------------------------------------------------------------------
-- Create log: the daily limit counts this, not events
-- ---------------------------------------------------------------------------

-- Counting events for "creates in the last 24 h" can be dodged by deleting
-- and recreating, because a deleted row is gone. This log survives deletes
-- (event_id just becomes null).
create table public.event_creation_log (
  id bigint generated always as identity primary key,
  creator_id uuid not null references public.profiles (id) on delete cascade,
  event_id uuid references public.events (id) on delete set null,
  created_at timestamptz not null default now()
);

create index event_creation_log_creator_idx
  on public.event_creation_log (creator_id, created_at desc);

-- RLS on with no policies: unreachable from clients.
alter table public.event_creation_log enable row level security;

grant select on public.event_creation_log to anon;
grant select, insert, update, delete on public.event_creation_log to authenticated;
grant select, insert, update, delete on public.event_creation_log to service_role;

insert into public.event_creation_log (creator_id, event_id, created_at)
select creator_id, id, created_at from public.events;

-- ---------------------------------------------------------------------------
-- Blocked terms: a speed bump, not a wall (reports are the main defense)
-- ---------------------------------------------------------------------------

-- Admins manage the list in the SQL editor. Terms are matched as whole words
-- or phrases, so 'dm me' doesn't catch 'dm meetup'.
create table public.event_blocked_terms (
  term text primary key check (term = lower(term) and char_length(btrim(term)) > 0)
);

alter table public.event_blocked_terms enable row level security;

grant select on public.event_blocked_terms to anon;
grant select, insert, update, delete on public.event_blocked_terms to authenticated;
grant select, insert, update, delete on public.event_blocked_terms to service_role;

insert into public.event_blocked_terms (term) values
  ('passive income'), ('dm me'), ('cash app'), ('cashapp'), ('venmo me'),
  ('crypto signals'), ('forex'), ('make money fast'), ('mlm'), ('onlyfans');

create or replace function public._event_text_blocked(p_text text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.event_blocked_terms t
    where regexp_replace(lower(coalesce(p_text, '')), '\s+', ' ', 'g')
      -- \m / \M are word boundaries. The inner regexp_replace escapes any
      -- regex characters an admin puts in a term.
      ~ ('\m' || regexp_replace(t.term, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
  );
$fn$;

revoke execute on function public._event_text_blocked(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Shared validation for create_event and update_event
-- ---------------------------------------------------------------------------

-- Returns the name of the first invalid field, or null when everything's
-- fine. The form checks the same things for fast feedback; this is the real
-- guard. p_check_start / p_check_times let update_event skip the time rules
-- when the host didn't touch the times (an event underway has a start in
-- the past, and that's fine).
create or replace function public._event_invalid_field(
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_visibility text,
  p_check_start boolean,
  p_check_times boolean
)
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
begin
  if p_title is null or char_length(btrim(p_title)) not between 1 and 60 then
    return 'title';
  end if;
  if char_length(btrim(coalesce(p_description, ''))) > 500 then
    return 'description';
  end if;
  if p_visibility is null or p_visibility not in ('public', 'connections') then
    return 'visibility';
  end if;
  if p_starts_at is null then
    return 'starts_at';
  end if;
  if p_check_start and (
    p_starts_at < now() - interval '5 minutes'
    or p_starts_at > now() + make_interval(days => (r ->> 'max_days_ahead')::int)
  ) then
    return 'starts_at';
  end if;
  if p_check_times and p_ends_at is not null and (
    p_ends_at <= p_starts_at
    or p_ends_at > p_starts_at + make_interval(hours => (r ->> 'max_duration_hours')::int)
  ) then
    return 'ends_at';
  end if;
  return null;
end;
$$;

revoke execute on function
  public._event_invalid_field(text, text, timestamptz, timestamptz, text, boolean, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lock down direct writes
-- ---------------------------------------------------------------------------

-- With no insert or update policy, clients can't write. The definer RPCs
-- below run as the table owner, which RLS doesn't apply to.
drop policy "Users can create their own events" on public.events;
drop policy "Creators can update their events" on public.events;

-- Hosts can delete their own events, but not one that's under review or was
-- removed: that would erase it (and its reports) before an admin looks.
drop policy "Creators can delete their events" on public.events;
create policy "Creators can delete their active events"
  on public.events
  for delete
  to authenticated
  using (creator_id = auth.uid() and status = 'active');

create policy "Admins can delete any event"
  on public.events
  for delete
  to authenticated
  using (public.is_admin());

-- Hosts always see their own events, even hidden or removed ones, so the app
-- can show them a banner. Everyone else only sees active ones.
drop policy "Users can view events visible to them" on public.events;
create policy "Users can view events visible to them"
  on public.events
  for select
  to authenticated
  using (
    public.is_admin()
    or creator_id = auth.uid()
    or (status = 'active' and (visibility = 'public' or public.is_connected_to(creator_id)))
  );

-- ---------------------------------------------------------------------------
-- create_event
-- ---------------------------------------------------------------------------

-- Returns one of:
--   { outcome: 'created', event_id }
--   { outcome: 'not_allowed', reason }             suspended / no_profile
--   { outcome: 'public_locked', ...hosting status } can't post public yet
--   { outcome: 'invalid', field }
--   { outcome: 'blocked_content' }
--   { outcome: 'too_many_active', limit }
--   { outcome: 'rate_limited', limit }
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

  -- handle_new_event (trigger) adds the host as attending.
  insert into public.events
    (creator_id, title, description, location_name, latitude, longitude, starts_at, ends_at, visibility)
  values (
    v_me,
    btrim(p_title),
    nullif(btrim(p_description), ''),
    nullif(btrim(p_location_name), ''),
    p_latitude,
    p_longitude,
    p_starts_at,
    p_ends_at,
    p_visibility
  )
  returning id into v_id;

  insert into public.event_creation_log (creator_id, event_id) values (v_me, v_id);

  return jsonb_build_object('outcome', 'created', 'event_id', v_id);
end;
$$;

revoke execute on function
  public.create_event(text, text, text, double precision, double precision, timestamptz, timestamptz, text)
  from public, anon;
grant execute on function
  public.create_event(text, text, text, double precision, double precision, timestamptz, timestamptz, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- update_event
-- ---------------------------------------------------------------------------

-- The location (pin and place name) is not an argument: it can never change
-- after people have RSVP'd. To move an event, delete it and drop a new pin.
--
-- Returns { outcome: 'updated' } or one of:
--   not_found (no such event, or not yours), event_removed, not_allowed,
--   public_locked, invalid, blocked_content — shaped like create_event's.
create or replace function public.update_event(
  p_event_id uuid,
  p_title text,
  p_description text,
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
  v_me uuid := auth.uid();
  v_event public.events%rowtype;
  v_status jsonb;
  v_start_changed boolean;
  v_time_changed boolean;
  v_field text;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id and creator_id = v_me
  for update;

  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if v_event.status = 'removed' then
    return jsonb_build_object('outcome', 'event_removed');
  end if;

  v_status := public._hosting_status(v_me);

  if not coalesce((v_status ->> 'can_host')::boolean, false) then
    return jsonb_build_object('outcome', 'not_allowed', 'reason', v_status -> 'reason');
  end if;

  -- Going to connections-only is always fine; going public needs trust.
  if p_visibility = 'public'
     and v_event.visibility <> 'public'
     and not coalesce((v_status ->> 'can_host_public')::boolean, false) then
    return v_status || jsonb_build_object('outcome', 'public_locked');
  end if;

  v_start_changed := p_starts_at is distinct from v_event.starts_at;
  v_time_changed := v_start_changed or p_ends_at is distinct from v_event.ends_at;

  v_field := public._event_invalid_field(
    p_title, p_description, p_starts_at, p_ends_at, p_visibility,
    v_start_changed, v_time_changed
  );
  if v_field is not null then
    return jsonb_build_object('outcome', 'invalid', 'field', v_field);
  end if;

  if public._event_text_blocked(p_title || ' ' || coalesce(p_description, '')) then
    return jsonb_build_object('outcome', 'blocked_content');
  end if;

  update public.events set
    title = btrim(p_title),
    description = nullif(btrim(p_description), ''),
    starts_at = p_starts_at,
    ends_at = p_ends_at,
    visibility = p_visibility,
    time_changed_at = case when v_time_changed then now() else time_changed_at end
  where id = p_event_id;

  return jsonb_build_object('outcome', 'updated');
end;
$$;

revoke execute on function
  public.update_event(uuid, text, text, timestamptz, timestamptz, text)
  from public, anon;
grant execute on function
  public.update_event(uuid, text, text, timestamptz, timestamptz, text)
  to authenticated;
