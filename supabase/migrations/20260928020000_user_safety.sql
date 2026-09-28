-- User safety: blocking, account suspension, user reports, a profile
-- content filter, and admin tools (Apple Guideline 1.2 for apps with
-- user-generated content).
-- Plan: docs/plans/legal-compliance.md (Phase 3).
--
-- Deviations from the plan (told to Zane):
-- - Policies call is_blocked_with(other), which always compares against the
--   caller, instead of a client-callable is_blocked_between(a, b). A
--   two-person version would let anyone probe whether two strangers blocked
--   each other (the same reason is_connected_to is one-argument). The
--   two-person check exists as _blocked_between, for definer functions only.
-- - event_blocked_terms becomes blocked_terms (one shared list) and the old
--   table is dropped rather than kept in sync.
-- - Blocking removes event RSVPs both ways (Zane's call on open question 3).
--
-- A blocked person is never told. Everything they hit looks like "not found"
-- / "not available", the same as a profile that doesn't exist.

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

create table public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

-- The primary key covers "who did I block"; this covers the other direction.
create index user_blocks_blocked_idx on public.user_blocks (blocked_id, blocker_id);

alter table public.user_blocks enable row level security;

create policy "Users see their own blocks"
  on public.user_blocks
  for select
  to authenticated
  using (blocker_id = auth.uid());
-- No insert/update/delete policies: block_user / unblock_user only.

grant select on public.user_blocks to anon;
grant select, insert, update, delete on public.user_blocks to authenticated;
grant select, insert, update, delete on public.user_blocks to service_role;

-- Either person blocked the other. Internal: definer functions only.
create or replace function public._blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = p_a and blocked_id = p_b)
       or (blocker_id = p_b and blocked_id = p_a)
  );
$$;

revoke execute on function public._blocked_between(uuid, uuid) from public, anon, authenticated;

-- The caller and p_other, either direction. Policies use this. Security
-- definer because the caller can't see blocks made against them.
create or replace function public.is_blocked_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._blocked_between(auth.uid(), p_other);
$$;

revoke execute on function public.is_blocked_with(uuid) from public, anon;
grant execute on function public.is_blocked_with(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Account restrictions (app-wide suspension)
-- ---------------------------------------------------------------------------

-- Separate from host_permissions (which only affects hosting events).
create table public.account_restrictions (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  status text not null check (status in ('suspended')),
  reason text check (char_length(reason) <= 300),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null
);

alter table public.account_restrictions enable row level security;

-- The app reads this to show "Your account is suspended".
create policy "Users can see their own restriction"
  on public.account_restrictions
  for select
  to authenticated
  using (user_id = auth.uid());
-- No insert/update/delete policies: admin_set_account_status only.

grant select on public.account_restrictions to anon;
grant select, insert, update, delete on public.account_restrictions to authenticated;
grant select, insert, update, delete on public.account_restrictions to service_role;

-- Policies call this, so authenticated needs execute. It only answers yes/no
-- about a user id.
create or replace function public.is_suspended(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.account_restrictions where user_id = p_uid);
$$;

revoke execute on function public.is_suspended(uuid) from public, anon;
grant execute on function public.is_suspended(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Profiles: hidden if blocked either way or suspended
-- ---------------------------------------------------------------------------

-- You always see yourself; admins see everyone. (select ...) lets Postgres
-- work out auth.uid() / is_admin() once per query instead of once per row.
drop policy "Profiles are viewable by authenticated users" on public.profiles;
create policy "Profiles visible unless blocked or suspended"
  on public.profiles
  for select
  to authenticated
  using (
    id = (select auth.uid())
    or (select public.is_admin())
    or (not public.is_blocked_with(id) and not public.is_suspended(id))
  );

-- ---------------------------------------------------------------------------
-- Connections
-- ---------------------------------------------------------------------------

drop policy "Users can send connection requests" on public.connections;
create policy "Users can send connection requests"
  on public.connections
  for insert
  to authenticated
  with check (
    auth.uid() = requester_id
    and not public.is_blocked_with(addressee_id)
    and not public.is_suspended(auth.uid())
    and not public.is_suspended(addressee_id)
  );

drop policy "Addressee can respond to a request" on public.connections;
create policy "Addressee can respond to a request"
  on public.connections
  for update
  to authenticated
  using (auth.uid() = addressee_id)
  with check (
    auth.uid() = addressee_id
    and not public.is_blocked_with(requester_id)
    and not public.is_suspended(auth.uid())
  );

-- Mutuals: never between people who blocked each other, and never showing a
-- blocked or suspended person.
create or replace function public.get_mutuals(other_user uuid)
returns setof public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select p.*
  from public.profiles p
  where not public._blocked_between(auth.uid(), other_user)
    and not public._blocked_between(auth.uid(), p.id)
    and not public.is_suspended(p.id)
    and p.id in (
      select case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end
      from public.connections c
      where c.status = 'accepted'
        and (c.requester_id = auth.uid() or c.addressee_id = auth.uid())
    )
    and p.id in (
      select case when c.requester_id = other_user then c.addressee_id else c.requester_id end
      from public.connections c
      where c.status = 'accepted'
        and (c.requester_id = other_user or c.addressee_id = other_user)
    );
$$;

revoke execute on function public.get_mutuals(uuid) from anon, public;
grant execute on function public.get_mutuals(uuid) to authenticated;

-- 0 for someone you can't see (blocked either way, or suspended).
create or replace function public.get_connection_count(target_user uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case
    when target_user <> auth.uid()
      and (public._blocked_between(auth.uid(), target_user) or public.is_suspended(target_user))
      then 0
    else (
      select count(*)::integer
      from public.connections c
      where c.status = 'accepted'
        and (c.requester_id = target_user or c.addressee_id = target_user)
    )
  end;
$$;

revoke execute on function public.get_connection_count(uuid) from anon, public;
grant execute on function public.get_connection_count(uuid) to authenticated;

-- Web Map: same as 20260927030000 plus "not suspended". Blocked people are
-- never your connections (block_user deletes the connection).
create or replace function public.get_connection_locations()
returns table (
  id uuid,
  username text,
  full_name text,
  avatar_url text,
  lat double precision,
  lng double precision,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url, ul.lat, ul.lng, ul.updated_at
  from public.user_locations ul
  join public.profiles p on p.id = ul.user_id
  where p.location_sharing = 'connections'
    and not public.is_suspended(p.id)
    and (
      p.id = auth.uid()
      or exists (
        select 1
        from public.connections c
        where c.status = 'accepted'
          and c.level = 'in_person'
          and (
            (c.requester_id = auth.uid() and c.addressee_id = p.id)
            or (c.addressee_id = auth.uid() and c.requester_id = p.id)
          )
      )
    );
$$;

revoke execute on function public.get_connection_locations() from anon, public;
grant execute on function public.get_connection_locations() to authenticated;

create or replace function public.get_connection_edges()
returns table (
  user_a uuid,
  user_b uuid
)
language sql
stable
security definer
set search_path = public
as $$
  with my_connections as (
    select case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end as connection_id
    from public.connections c
    where c.status = 'accepted'
      and c.level = 'in_person'
      and (c.requester_id = auth.uid() or c.addressee_id = auth.uid())
  ),
  visible as (
    select mc.connection_id
    from my_connections mc
    join public.profiles p on p.id = mc.connection_id
    where p.location_sharing = 'connections'
      and not public.is_suspended(mc.connection_id)
      and exists (select 1 from public.user_locations ul where ul.user_id = mc.connection_id)
  )
  select least(c.requester_id, c.addressee_id) as user_a,
         greatest(c.requester_id, c.addressee_id) as user_b
  from public.connections c
  where c.status = 'accepted'
    and c.level = 'in_person'
    and c.requester_id in (select connection_id from visible)
    and c.addressee_id in (select connection_id from visible)
    and c.requester_id <> auth.uid()
    and c.addressee_id <> auth.uid();
$$;

revoke execute on function public.get_connection_edges() from anon, public;
grant execute on function public.get_connection_edges() to authenticated;

-- ---------------------------------------------------------------------------
-- In person (QR and tap)
-- ---------------------------------------------------------------------------

-- Same as 20260927000000, with the blocks placeholder filled in: blocked
-- either way, or either person suspended -> 'unavailable', nothing written.
create or replace function public._connect_in_person(
  p_a uuid,
  p_b uuid,
  p_method public.connection_method,
  p_city text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conn public.connections%rowtype;
  v_outcome text;
  v_city text := nullif(left(trim(coalesce(p_city, '')), 80), '');
begin
  if p_a = p_b then
    raise exception 'self_connect' using errcode = 'P0001';
  end if;

  if public._blocked_between(p_a, p_b) or public.is_suspended(p_a) or public.is_suspended(p_b) then
    return jsonb_build_object('outcome', 'unavailable');
  end if;

  perform set_config('bolas.trusted_write', 'on', true);

  select * into v_conn
  from public.connections
  where (requester_id = p_a and addressee_id = p_b)
     or (requester_id = p_b and addressee_id = p_a)
  for update;

  if not found then
    begin
      insert into public.connections
        (requester_id, addressee_id, status, level, method, met_at, met_city, undo_until, undo_snapshot)
      values
        (p_a, p_b, 'accepted', 'in_person', p_method, now(), v_city, now() + interval '30 seconds', null)
      returning * into v_conn;
      v_outcome := 'created';
    exception when unique_violation then
      -- Both phones raced and the other call created it first.
      select * into v_conn
      from public.connections
      where (requester_id = p_a and addressee_id = p_b)
         or (requester_id = p_b and addressee_id = p_a);
      v_outcome := 'already_connected';
    end;

  elsif v_conn.level = 'in_person' then
    v_outcome := 'already_connected';

  else
    update public.connections set
      undo_snapshot = jsonb_build_object(
        'status', v_conn.status,
        'level', v_conn.level,
        'method', v_conn.method,
        'met_at', v_conn.met_at,
        'met_city', v_conn.met_city
      ),
      status = 'accepted',
      level = 'in_person',
      method = p_method,
      met_at = now(),
      met_city = v_city,
      undo_until = now() + interval '30 seconds'
    where id = v_conn.id
    returning * into v_conn;
    v_outcome := 'upgraded';
  end if;

  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object(
    'outcome', v_outcome,
    'connection_id', v_conn.id,
    'met_city', v_conn.met_city,
    'undo_until', v_conn.undo_until
  );
end;
$$;

revoke execute on function public._connect_in_person(uuid, uuid, public.connection_method, text)
  from anon, authenticated, public;

-- Same as 20260927010000, except an 'unavailable' connect returns just
-- { outcome: 'unavailable' } (no profile) and leaves the code unused, so
-- the code's owner sees nothing happen. The app shows its generic
-- "this code didn't work" message.
create or replace function public.redeem_connect_token(p_token text, p_city text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_tok public.connect_tokens%rowtype;
  v_city text;
  v jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  select * into v_tok from public.connect_tokens where token = p_token for update;

  if not found then
    return jsonb_build_object('outcome', 'invalid');
  elsif v_tok.user_id = v_me then
    return jsonb_build_object('outcome', 'self');
  elsif v_tok.used_at is not null then
    return jsonb_build_object('outcome', 'used');
  elsif v_tok.expires_at < now() then
    return jsonb_build_object('outcome', 'expired');
  end if;

  v_city := coalesce(
    nullif(trim(p_city), ''),
    nullif(trim((select city from public.profiles where id = v_me)), ''),
    nullif(trim((select city from public.profiles where id = v_tok.user_id)), '')
  );

  v := public._connect_in_person(v_me, v_tok.user_id, 'qr', v_city);

  if v ->> 'outcome' = 'unavailable' then
    return jsonb_build_object('outcome', 'unavailable');
  end if;

  -- The owner's copy names the scanner as "the other person".
  update public.connect_tokens set
    used_at = now(),
    used_by = v_me,
    result = v || jsonb_build_object(
      'other_user_id', v_me,
      'other_profile', public._profile_card(v_me)
    )
  where token = p_token;

  return v || jsonb_build_object(
    'other_user_id', v_tok.user_id,
    'other_profile', public._profile_card(v_tok.user_id)
  );
end;
$$;

revoke execute on function public.redeem_connect_token(text, text) from anon, public;
grant execute on function public.redeem_connect_token(text, text) to authenticated;

-- Same as 20260927020000, except: a suspended caller never matches, and
-- people blocked either way (or suspended) are never candidates for each
-- other — to both phones it looks like nobody else tapped.
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

  -- Suspended accounts can't connect; nothing is stored.
  if public.is_suspended(v_me) then
    return jsonb_build_object('status', 'no_match');
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
        <= greatest(c_min_radius_m, least(c_max_radius_m, p_accuracy_m + b.accuracy_m))
    and not public._blocked_between(v_me, b.user_id)
    and not public.is_suspended(b.user_id);

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

  -- Can't normally happen (candidates are filtered above), but never
  -- reveal anything if it does.
  if v ->> 'outcome' = 'unavailable' then
    update public.bump_events set status = 'no_match', lat = null, lng = null
    where id in (v_id, v_other.id);
    return jsonb_build_object('status', 'no_match', 'bump_id', v_id);
  end if;

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

revoke execute on function public.submit_bump(double precision, double precision, double precision, text) from anon, public;
grant execute on function public.submit_bump(double precision, double precision, double precision, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

-- A conversation where any other participant is blocked (either way) or
-- suspended. Hidden from the caller entirely, including Realtime.
create or replace function public.is_conversation_hidden(_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_participants cp
    where cp.conversation_id = _conversation_id
      and cp.user_id <> auth.uid()
      and (public._blocked_between(auth.uid(), cp.user_id) or public.is_suspended(cp.user_id))
  );
$$;

revoke execute on function public.is_conversation_hidden(uuid) from anon, public;
grant execute on function public.is_conversation_hidden(uuid) to authenticated;

drop policy "Members can view their conversations" on public.conversations;
create policy "Members can view their conversations"
  on public.conversations
  for select
  to authenticated
  using (public.is_conversation_participant(id) and not public.is_conversation_hidden(id));

drop policy "Members can view participants in their conversations" on public.conversation_participants;
create policy "Members can view participants in their conversations"
  on public.conversation_participants
  for select
  to authenticated
  using (
    public.is_conversation_participant(conversation_id)
    and not public.is_conversation_hidden(conversation_id)
  );

drop policy "Members can view messages in their conversations" on public.messages;
create policy "Members can view messages in their conversations"
  on public.messages
  for select
  to authenticated
  using (
    public.is_conversation_participant(conversation_id)
    and not public.is_conversation_hidden(conversation_id)
  );

-- Same as 20260921233000, plus: not suspended, and the conversation isn't
-- hidden. (Blocking already deletes the connection, which stops sending on
-- its own; this is the belt to that suspender.)
drop policy "Members can send messages if still connected" on public.messages;
create policy "Members can send messages if still connected"
  on public.messages
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and not public.is_suspended(auth.uid())
    and public.is_conversation_participant(conversation_id)
    and not public.is_conversation_hidden(conversation_id)
    and not exists (
      select 1 from public.conversation_participants other
      where other.conversation_id = messages.conversation_id
        and other.user_id <> auth.uid()
        and not exists (
          select 1 from public.connections c
          where c.status = 'accepted'
            and (
              (c.requester_id = auth.uid() and c.addressee_id = other.user_id)
              or (c.requester_id = other.user_id and c.addressee_id = auth.uid())
            )
        )
    )
  );

-- Same as 20260921230000, plus the suspended / blocked checks (same generic
-- 'not connected' error either way).
create or replace function public.get_or_create_direct_conversation(other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  lo uuid := least(auth.uid(), other_user);
  hi uuid := greatest(auth.uid(), other_user);
  found_id uuid;
begin
  if me is null then
    raise exception 'not authenticated';
  end if;
  if me = other_user then
    raise exception 'cannot start a conversation with yourself';
  end if;

  if public.is_suspended(me)
     or public.is_suspended(other_user)
     or public._blocked_between(me, other_user)
     or not exists (
       select 1 from public.connections c
       where c.status = 'accepted'
         and (
           (c.requester_id = me and c.addressee_id = other_user)
           or (c.requester_id = other_user and c.addressee_id = me)
         )
     ) then
    raise exception 'not connected';
  end if;

  select id into found_id
  from public.conversations
  where not is_group and least(user_a_id, user_b_id) = lo and greatest(user_a_id, user_b_id) = hi;

  if found_id is not null then
    return found_id;
  end if;

  -- Two people could hit this at once (both starting the chat from their
  -- own side simultaneously); the unique index turns the loser's insert
  -- into a unique_violation instead of a duplicate row, and this just
  -- looks up the row the winner created.
  begin
    insert into public.conversations (user_a_id, user_b_id)
    values (lo, hi)
    returning id into found_id;
  exception when unique_violation then
    select id into found_id
    from public.conversations
    where not is_group and least(user_a_id, user_b_id) = lo and greatest(user_a_id, user_b_id) = hi;
  end;

  insert into public.conversation_participants (conversation_id, user_id)
  values (found_id, lo), (found_id, hi)
  on conflict (conversation_id, user_id) do nothing;

  return found_id;
end;
$$;

revoke execute on function public.get_or_create_direct_conversation(uuid) from anon, public;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Same as 20260927040000, plus: never an event from someone blocked either
-- way, or a suspended host.
drop policy "Users can view events visible to them" on public.events;
create policy "Users can view events visible to them"
  on public.events
  for select
  to authenticated
  using (
    (select public.is_admin())
    or creator_id = (select auth.uid())
    or (
      status = 'active'
      and (visibility = 'public' or public.is_connected_to(creator_id))
      and not public.is_blocked_with(creator_id)
      and not public.is_suspended(creator_id)
    )
  );

-- Same as 20260927060000, plus: blocked people drop out of attendee lists.
drop policy "Attendees visible to self, host, admins, and your connections" on public.event_attendees;
create policy "Attendees visible to self, host, admins, and your connections"
  on public.event_attendees
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or (
      -- Still has to be an event you can see (the events policy applies here).
      exists (select 1 from public.events e where e.id = event_attendees.event_id)
      and not public.is_blocked_with(user_id)
      and (
        exists (
          select 1 from public.events e
          where e.id = event_attendees.event_id and e.creator_id = auth.uid()
        )
        or public.is_connected_to(user_id)
      )
    )
  );

-- Same as 20260927060000, plus: suspended accounts can't RSVP.
drop policy "Users can RSVP to visible active events" on public.event_attendees;
create policy "Users can RSVP to visible active events"
  on public.event_attendees
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and not public.is_suspended(auth.uid())
    and exists (
      select 1 from public.events e
      where e.id = event_attendees.event_id
        and e.status = 'active'
        and coalesce(e.ends_at, e.starts_at + interval '3 hours') > now()
    )
  );

-- Same as 20260927040000, plus: an account suspension also stops hosting
-- (reason 'suspended', same as a hosting suspension).
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
  v_account_suspended boolean;
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
  v_account_suspended := public.is_suspended(p_uid);
  v_admin := exists (select 1 from public.app_admins a where a.user_id = p_uid);

  -- "is [not] distinct from" rather than "=": v_host_status is null when an
  -- admin never set one, and null = 'approved' is null, not false — which
  -- would make can_host_public null and skip the public lock entirely.
  v_can_host := v_has_profile
    and v_host_status is distinct from 'suspended'
    and not v_account_suspended;
  v_can_public := v_can_host and (
    v_admin
    or v_host_status is not distinct from 'approved'
    or (v_age >= v_min_age and v_in_person >= v_min_in_person)
  );

  v_reason := case
    when v_account_suspended or v_host_status = 'suspended' then 'suspended'
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

-- Same as 20260927070000, plus: suspended accounts can't report
-- ('not_allowed'), and events from someone blocked either way (or a
-- suspended host) are 'not_found', matching what the events policy shows.
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

  insert into public.event_reports (event_id, reporter_id, reason, details)
  values (p_event_id, v_me, p_reason, v_details)
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

-- ---------------------------------------------------------------------------
-- block_user / unblock_user / get_my_blocked_users
-- ---------------------------------------------------------------------------

-- Returns { outcome: 'blocked' } or 'self' / 'not_found'. Blocking twice is
-- fine. It also:
--   - deletes any connection between the two (any status or level), which
--     also ends messaging and removes pending requests
--   - removes RSVPs both ways: theirs to your events, yours to theirs
-- Chat history stays, hidden from both, and comes back if you unblock (but
-- messaging needs a new connection).
create or replace function public.block_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user_id = v_me then
    return jsonb_build_object('outcome', 'self');
  end if;
  if p_user_id is null or not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  insert into public.user_blocks (blocker_id, blocked_id)
  values (v_me, p_user_id)
  on conflict (blocker_id, blocked_id) do nothing;

  delete from public.connections
  where (requester_id = v_me and addressee_id = p_user_id)
     or (requester_id = p_user_id and addressee_id = v_me);

  -- A host's own attendance row is never matched here (user_id <> creator).
  delete from public.event_attendees a
  using public.events e
  where a.event_id = e.id
    and (
      (e.creator_id = v_me and a.user_id = p_user_id)
      or (e.creator_id = p_user_id and a.user_id = v_me)
    );

  return jsonb_build_object('outcome', 'blocked');
end;
$$;

revoke execute on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

-- Doesn't restore the connection or RSVPs.
create or replace function public.unblock_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  delete from public.user_blocks where blocker_id = auth.uid() and blocked_id = p_user_id;

  return jsonb_build_object('outcome', 'unblocked');
end;
$$;

revoke execute on function public.unblock_user(uuid) from public, anon;
grant execute on function public.unblock_user(uuid) to authenticated;

-- For Settings > Blocked users. Definer because the profiles policy hides
-- people you've blocked.
create or replace function public.get_my_blocked_users()
returns table (
  user_id uuid,
  username text,
  full_name text,
  avatar_url text,
  blocked_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url, b.created_at
  from public.user_blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid()
  order by b.created_at desc;
$$;

revoke execute on function public.get_my_blocked_users() from public, anon;
grant execute on function public.get_my_blocked_users() to authenticated;

-- ---------------------------------------------------------------------------
-- User reports
-- ---------------------------------------------------------------------------

create table public.user_reports (
  id uuid primary key default gen_random_uuid(),
  -- Both set null (not cascade): a report survives either account being
  -- deleted, so evidence can't be erased by deleting an account.
  reporter_id uuid references public.profiles (id) on delete set null,
  reported_user_id uuid references public.profiles (id) on delete set null,
  context text not null check (context in ('profile', 'message', 'in_person', 'other')),
  context_id uuid,   -- e.g. the message id
  reason text not null check (reason in (
    'spam', 'scam_or_selling', 'harassment', 'hate', 'sexual_content',
    'impersonation', 'underage', 'unsafe_meetup', 'other'
  )),
  details text check (char_length(details) <= 500),
  -- Built by the server at report time (profile fields, and the message for
  -- message reports). Never taken from the client.
  snapshot jsonb,
  status text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at timestamptz not null default now()
);

create index user_reports_reporter_idx on public.user_reports (reporter_id, created_at desc);
create index user_reports_reported_idx on public.user_reports (reported_user_id, status);
create index user_reports_open_idx on public.user_reports (created_at desc) where status = 'open';

-- RLS on with no policies: reports are only reachable through the RPCs.
alter table public.user_reports enable row level security;

grant select on public.user_reports to anon;
grant select, insert, update, delete on public.user_reports to authenticated;
grant select, insert, update, delete on public.user_reports to service_role;

-- Returns one of:
--   { outcome: 'reported' }        the app says "Thanks, we'll review this" and offers to block
--   { outcome: 'self' }
--   { outcome: 'not_found' }       no such person / message, or you can't see them
--   { outcome: 'invalid', field }  context / reason / details / context_id
--   { outcome: 'rate_limited', limit }
--   { outcome: 'not_allowed' }     your account is suspended
create or replace function public.report_user(
  p_user_id uuid,
  p_context text,
  p_context_id uuid,
  p_reason text,
  p_details text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunable (kept in step with _event_rules' max_reports_per_day).
  c_max_per_day constant int := 10;

  v_me uuid := auth.uid();
  v_details text := nullif(btrim(p_details), '');
  v_target public.profiles%rowtype;
  v_message public.messages%rowtype;
  v_snapshot jsonb;
  v_recent int;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if public.is_suspended(v_me) then
    return jsonb_build_object('outcome', 'not_allowed');
  end if;

  if p_user_id = v_me then
    return jsonb_build_object('outcome', 'self');
  end if;

  if p_context is null or p_context not in ('profile', 'message', 'in_person', 'other') then
    return jsonb_build_object('outcome', 'invalid', 'field', 'context');
  end if;
  if p_reason is null or p_reason not in (
    'spam', 'scam_or_selling', 'harassment', 'hate', 'sexual_content',
    'impersonation', 'underage', 'unsafe_meetup', 'other'
  ) then
    return jsonb_build_object('outcome', 'invalid', 'field', 'reason');
  end if;
  if char_length(coalesce(v_details, '')) > 500 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'details');
  end if;
  if p_context = 'message' and p_context_id is null then
    return jsonb_build_object('outcome', 'invalid', 'field', 'context_id');
  end if;

  -- Definer functions skip RLS, so check visibility by hand. You can report
  -- someone you blocked (you saw them before), but not someone who blocked
  -- you or a suspended account: those look like they don't exist.
  select * into v_target from public.profiles where id = p_user_id;
  if not found
     or public.is_suspended(p_user_id)
     or exists (select 1 from public.user_blocks where blocker_id = p_user_id and blocked_id = v_me) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  -- A message report: the message must be theirs, in a conversation you're in.
  if p_context = 'message' then
    select m.* into v_message
    from public.messages m
    where m.id = p_context_id
      and m.sender_id = p_user_id
      and exists (
        select 1 from public.conversation_participants cp
        where cp.conversation_id = m.conversation_id and cp.user_id = v_me
      );
    if not found then
      return jsonb_build_object('outcome', 'not_found');
    end if;
  end if;

  if not public.is_admin() then
    select count(*) into v_recent
    from public.user_reports
    where reporter_id = v_me and created_at > now() - interval '24 hours';
    if v_recent >= c_max_per_day then
      return jsonb_build_object('outcome', 'rate_limited', 'limit', c_max_per_day);
    end if;
  end if;

  v_snapshot := jsonb_build_object(
    'username', v_target.username,
    'full_name', v_target.full_name,
    'bio', v_target.bio,
    'avatar_url', v_target.avatar_url,
    'city', v_target.city,
    'business_stage', v_target.business_stage,
    'interests', to_jsonb(v_target.interests)
  );
  if p_context = 'message' then
    v_snapshot := v_snapshot || jsonb_build_object('message', jsonb_build_object(
      'id', v_message.id,
      'conversation_id', v_message.conversation_id,
      'body', v_message.body,
      'sent_at', v_message.created_at
    ));
  end if;

  insert into public.user_reports
    (reporter_id, reported_user_id, context, context_id, reason, details, snapshot)
  values
    (v_me, p_user_id, p_context, case when p_context = 'profile' then null else p_context_id end,
     p_reason, v_details, v_snapshot);

  return jsonb_build_object('outcome', 'reported');
end;
$$;

revoke execute on function public.report_user(uuid, text, uuid, text, text) from public, anon;
grant execute on function public.report_user(uuid, text, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Content filter: one shared list for events and profiles
-- ---------------------------------------------------------------------------

-- Admins manage the list in the SQL editor:
--   insert into public.blocked_terms (term) values ('some phrase');
create table public.blocked_terms (
  term text primary key check (term = lower(term) and char_length(btrim(term)) > 0)
);

alter table public.blocked_terms enable row level security;

grant select on public.blocked_terms to anon;
grant select, insert, update, delete on public.blocked_terms to authenticated;
grant select, insert, update, delete on public.blocked_terms to service_role;

insert into public.blocked_terms (term)
select term from public.event_blocked_terms
on conflict (term) do nothing;

-- Whole words or phrases, so 'dm me' doesn't catch 'dm meetup'.
create or replace function public._text_blocked(p_text text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.blocked_terms t
    where regexp_replace(lower(coalesce(p_text, '')), '\s+', ' ', 'g')
      -- \m / \M are word boundaries. The inner regexp_replace escapes any
      -- regex characters an admin puts in a term.
      ~ ('\m' || regexp_replace(t.term, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
  );
$fn$;

revoke execute on function public._text_blocked(text) from public, anon, authenticated;

-- Usernames can't have spaces, so words get glued together ("fo_rex99").
-- Strip underscores and digits from the username (and spaces, underscores
-- and digits from each term) and look for the term anywhere inside it.
-- Substring matching can catch innocent names for very short terms; keep
-- terms at least 4-5 letters where possible.
create or replace function public._username_blocked(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $fn$
  select exists (
    select 1
    from public.blocked_terms t
    cross join lateral (select regexp_replace(t.term, '[\s_0-9]', '', 'g') as squashed) s
    where s.squashed <> ''
      and position(s.squashed in regexp_replace(lower(coalesce(p_username, '')), '[_0-9]', '', 'g')) > 0
  );
$fn$;

revoke execute on function public._username_blocked(text) from public, anon, authenticated;

-- Events now read the shared list. create_event / update_event keep calling
-- this name.
create or replace function public._event_text_blocked(p_text text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._text_blocked(p_text);
$$;

revoke execute on function public._event_text_blocked(text) from public, anon, authenticated;

drop table public.event_blocked_terms;

-- Only checks fields that changed, so adding a term later doesn't stop
-- someone with an old bio from editing their city. Error: P0001
-- 'blocked_content', with the field name in DETAIL.
create or replace function public.profiles_content_filter()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT' or new.username is distinct from old.username)
     and new.username is not null
     and (public._username_blocked(new.username) or public._text_blocked(new.username)) then
    raise exception 'blocked_content' using errcode = 'P0001', detail = 'username';
  end if;

  if (tg_op = 'INSERT' or new.full_name is distinct from old.full_name)
     and public._text_blocked(new.full_name) then
    raise exception 'blocked_content' using errcode = 'P0001', detail = 'full_name';
  end if;

  if (tg_op = 'INSERT' or new.bio is distinct from old.bio)
     and public._text_blocked(new.bio) then
    raise exception 'blocked_content' using errcode = 'P0001', detail = 'bio';
  end if;

  return new;
end;
$$;

revoke execute on function public.profiles_content_filter() from public, anon, authenticated;

create trigger profiles_content_filter
  before insert or update of username, full_name, bio on public.profiles
  for each row execute function public.profiles_content_filter();

-- ---------------------------------------------------------------------------
-- Admin RPCs (each refuses non-admins with 42501 via _require_admin)
-- ---------------------------------------------------------------------------

-- Reports grouped by the reported person (reports about deleted accounts
-- stand alone), 'underage' groups first, then most recently reported.
create or replace function public.admin_list_user_reports(p_status text default 'open')
returns table (
  reported_user_id uuid,
  username text,
  full_name text,
  is_suspended boolean,
  report_count integer,
  reports_by_reason jsonb,
  has_underage boolean,
  latest_report_at timestamptz,
  latest_snapshot jsonb,
  reports jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public._require_admin();

  return query
  with r as (
    select ur.*, coalesce(ur.reported_user_id, ur.id) as grp, pr.username as reporter_username
    from public.user_reports ur
    left join public.profiles pr on pr.id = ur.reporter_id
    where ur.status = p_status
  ),
  g as (
    select
      r.grp,
      (array_agg(r.reported_user_id))[1] as reported_user_id,
      count(*)::integer as report_count,
      bool_or(r.reason = 'underage') as has_underage,
      max(r.created_at) as latest_at,
      (array_agg(r.snapshot order by r.created_at desc))[1] as latest_snapshot,
      jsonb_agg(jsonb_build_object(
        'id', r.id,
        'context', r.context,
        'context_id', r.context_id,
        'reason', r.reason,
        'details', r.details,
        'reporter_username', r.reporter_username,
        'created_at', r.created_at
      ) order by r.created_at desc) as reports
    from r
    group by r.grp
  )
  select
    g.reported_user_id,
    p.username,
    p.full_name,
    exists (select 1 from public.account_restrictions a where a.user_id = g.reported_user_id),
    g.report_count,
    (
      select jsonb_object_agg(x.reason, x.n)
      from (select r2.reason, count(*) as n from r r2 where r2.grp = g.grp group by r2.reason) x
    ),
    g.has_underage,
    g.latest_at,
    g.latest_snapshot,
    g.reports
  from g
  left join public.profiles p on p.id = g.reported_user_id
  order by g.has_underage desc, g.latest_at desc;
end;
$$;

revoke execute on function public.admin_list_user_reports(text) from public, anon;
grant execute on function public.admin_list_user_reports(text) to authenticated;

-- Mark one report dismissed or actioned (logged with the note).
create or replace function public.admin_resolve_user_report(p_report_id uuid, p_status text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(p_note), '');
  v_reported uuid;
begin
  perform public._require_admin();

  if p_status is null or p_status not in ('dismissed', 'actioned') then
    return jsonb_build_object('outcome', 'invalid', 'field', 'status');
  end if;
  if char_length(coalesce(v_note, '')) > 300 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'note');
  end if;

  update public.user_reports set status = p_status
  where id = p_report_id
  returning reported_user_id into v_reported;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  insert into public.moderation_log (admin_id, action, user_id, note)
  values (auth.uid(), 'user_report_' || p_status, v_reported, v_note);

  return jsonb_build_object('outcome', 'updated', 'status', p_status);
end;
$$;

revoke execute on function public.admin_resolve_user_report(uuid, text, text) from public, anon;
grant execute on function public.admin_resolve_user_report(uuid, text, text) to authenticated;

-- 'suspended' suspends (and removes their events that haven't ended, and
-- marks open reports about them actioned); null lifts it. Lifting doesn't
-- bring removed events back.
create or replace function public.admin_set_account_status(p_user_id uuid, p_status text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text := nullif(btrim(p_reason), '');
  v_removed int := 0;
begin
  perform public._require_admin();

  if p_status is not null and p_status <> 'suspended' then
    return jsonb_build_object('outcome', 'invalid', 'field', 'status');
  end if;
  if char_length(coalesce(v_reason, '')) > 300 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'reason');
  end if;
  if p_user_id = auth.uid() then
    return jsonb_build_object('outcome', 'self');
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if p_status is null then
    delete from public.account_restrictions where user_id = p_user_id;
  else
    insert into public.account_restrictions (user_id, status, reason, created_by)
    values (p_user_id, p_status, v_reason, auth.uid())
    on conflict (user_id) do update set
      status = excluded.status,
      reason = excluded.reason,
      created_at = now(),
      created_by = excluded.created_by;

    with removed as (
      update public.events
      set status = 'removed'
      where creator_id = p_user_id
        and status in ('active', 'hidden')
        and coalesce(ends_at, starts_at + interval '3 hours') > now()
      returning id
    ),
    event_reports_done as (
      update public.event_reports
      set status = 'actioned'
      where status = 'open' and event_id in (select id from removed)
    )
    select count(*) into v_removed from removed;

    update public.user_reports
    set status = 'actioned'
    where reported_user_id = p_user_id and status = 'open';
  end if;

  insert into public.moderation_log (admin_id, action, user_id, note)
  values (
    auth.uid(),
    case when p_status is null then 'account_restored' else 'account_suspended' end,
    p_user_id,
    v_reason
  );

  return jsonb_build_object('outcome', 'updated', 'status', p_status, 'events_removed', v_removed);
end;
$$;

revoke execute on function public.admin_set_account_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_account_status(uuid, text, text) to authenticated;
