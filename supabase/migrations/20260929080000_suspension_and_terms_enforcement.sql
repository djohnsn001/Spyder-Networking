-- Security item M5: the database enforces suspension and Terms consent.
--
-- src/lib/auth.tsx checks both on the client and fails open (a network blip
-- lets you in), and anyone can call the API directly anyway. So:
--
--   1. Suspended accounts can't write anything, except: read their own data,
--      accept the Terms, delete their account (Edge Function, service role),
--      unblock someone, and report.
--   2. Sending messages, creating events, RSVPing and every way of connecting
--      (request, accept, QR, bump) needs the current Terms accepted.
--
-- How:
--   - Tables clients write directly: RESTRICTIVE policies. Postgres ANDs them
--     with the existing (permissive) policies, so nothing existing had to be
--     dropped and rewritten. They cover writes only; reads are unchanged.
--   - RPCs (security definer, so RLS doesn't apply): a check in the function,
--     or a trigger on the table the RPC writes to when another security
--     branch rewrites that RPC (create_connect_token is replaced in H2, so a
--     trigger on connect_tokens keeps working whichever version is live).
--
-- The audit table (every write path, before and after) is in
-- docs/security/m5-write-path-audit.md.

-- ---------------------------------------------------------------------------
-- 1. has_accepted_current_terms
-- ---------------------------------------------------------------------------

-- True when p_uid accepted the Terms version the server currently requires.
-- Definer so it can read _current_terms_version() and user_consents; granted
-- to authenticated because RLS policies run as the caller.
create or replace function public.has_accepted_current_terms(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_consents c
    where c.user_id = p_uid
      and c.terms_version = public._current_terms_version()
  );
$$;

revoke execute on function public.has_accepted_current_terms(uuid) from public, anon;
grant execute on function public.has_accepted_current_terms(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Direct table writes: suspended accounts
-- ---------------------------------------------------------------------------
-- Every table with an insert/update/delete policy for authenticated. Tables
-- without one (user_blocks, user_reports, user_consents, conversations, ...)
-- are only written by RPCs, covered in section 4.

create policy "Suspended accounts can't send requests"
  on public.connections as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't respond to requests"
  on public.connections as restrictive for update to authenticated
  using (not public.is_suspended(auth.uid()))
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't remove connections"
  on public.connections as restrictive for delete to authenticated
  using (not public.is_suspended(auth.uid()));

create policy "Suspended accounts can't update read state"
  on public.conversation_participants as restrictive for update to authenticated
  using (not public.is_suspended(auth.uid()))
  with check (not public.is_suspended(auth.uid()));

create policy "Suspended accounts can't RSVP"
  on public.event_attendees as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't remove RSVPs"
  on public.event_attendees as restrictive for delete to authenticated
  using (not public.is_suspended(auth.uid()));

-- Also covers "Admins can delete any event": a suspended admin can't.
create policy "Suspended accounts can't delete events"
  on public.events as restrictive for delete to authenticated
  using (not public.is_suspended(auth.uid()));

create policy "Suspended accounts can't send messages"
  on public.messages as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));

create policy "Suspended accounts can't create profiles"
  on public.profiles as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't edit profiles"
  on public.profiles as restrictive for update to authenticated
  using (not public.is_suspended(auth.uid()))
  with check (not public.is_suspended(auth.uid()));

-- Avatars. Deleting an account removes the files with the service role,
-- which skips RLS, so that still works.
create policy "Suspended accounts can't upload files"
  on storage.objects as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't replace files"
  on storage.objects as restrictive for update to authenticated
  using (not public.is_suspended(auth.uid()))
  with check (not public.is_suspended(auth.uid()));
create policy "Suspended accounts can't delete files"
  on storage.objects as restrictive for delete to authenticated
  using (not public.is_suspended(auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. Direct table writes: current Terms
-- ---------------------------------------------------------------------------

create policy "Current Terms required to send messages"
  on public.messages as restrictive for insert to authenticated
  with check (public.has_accepted_current_terms(auth.uid()));

create policy "Current Terms required to RSVP"
  on public.event_attendees as restrictive for insert to authenticated
  with check (public.has_accepted_current_terms(auth.uid()));

create policy "Current Terms required to send requests"
  on public.connections as restrictive for insert to authenticated
  with check (public.has_accepted_current_terms(auth.uid()));

-- The only client update on connections is the addressee accepting.
create policy "Current Terms required to accept requests"
  on public.connections as restrictive for update to authenticated
  using (public.has_accepted_current_terms(auth.uid()))
  with check (public.has_accepted_current_terms(auth.uid()));

-- ---------------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------------

-- 4a. QR codes and bumps: a trigger on the rows they create, so it holds
-- whichever version of create_connect_token / submit_bump is live (H2
-- replaces create_connect_token). Raises, which rolls the whole call back.
create or replace function public._require_can_connect()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_suspended(new.user_id) then
    raise exception 'account_suspended' using errcode = '42501';
  end if;
  if not public.has_accepted_current_terms(new.user_id) then
    raise exception 'terms_not_accepted' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public._require_can_connect() from public, anon, authenticated;

create trigger connect_tokens_require_can_connect
  before insert on public.connect_tokens
  for each row execute function public._require_can_connect();

create trigger bump_events_require_can_connect
  before insert on public.bump_events
  for each row execute function public._require_can_connect();

-- 4b. _connect_in_person: every in-person connect (QR redeem, bump match)
-- goes through here. p_a is always the caller; p_b is the other person.
-- Same as 20260928020000, plus the Terms checks.
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

  -- M5: the caller gets a clear error (the app sends them to the Terms);
  -- the other person's consent state isn't revealed.
  if not public.has_accepted_current_terms(p_a) then
    raise exception 'terms_not_accepted' using errcode = '42501';
  end if;
  if not public.has_accepted_current_terms(p_b) then
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
  from public, anon, authenticated;

-- 4c. create_event: needs the current Terms. Suspension was already covered
-- (_hosting_status -> not_allowed / suspended). Same as 20260927050000, plus
-- the Terms check.
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

  -- M5
  if not public.has_accepted_current_terms(v_me) then
    return jsonb_build_object('outcome', 'not_allowed', 'reason', 'terms_not_accepted');
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

-- 4d. block_user: not on the allowed list, so refused while suspended.
-- Same as 20260928020000, plus the check.
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
  if public.is_suspended(v_me) then
    return jsonb_build_object('outcome', 'not_allowed');
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

-- 4e. undo_in_person_connection. Same as 20260927000000, plus the check.
create or replace function public.undo_in_person_connection(p_connection_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_conn public.connections%rowtype;
  v_snap jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if public.is_suspended(v_me) then
    return jsonb_build_object('outcome', 'not_allowed');
  end if;

  select * into v_conn
  from public.connections
  where id = p_connection_id
    and (requester_id = v_me or addressee_id = v_me)
  for update;

  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if v_conn.undo_until is null or now() > v_conn.undo_until then
    return jsonb_build_object('outcome', 'too_late');
  end if;

  perform set_config('bolas.trusted_write', 'on', true);

  v_snap := v_conn.undo_snapshot;
  if v_snap is null then
    delete from public.connections where id = v_conn.id;
  else
    update public.connections set
      status = v_snap ->> 'status',
      level = (v_snap ->> 'level')::public.connection_level,
      method = (v_snap ->> 'method')::public.connection_method,
      met_at = (v_snap ->> 'met_at')::timestamptz,
      met_city = v_snap ->> 'met_city',
      undo_until = null,
      undo_snapshot = null
    where id = v_conn.id;
  end if;

  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object('outcome', 'undone');
end;
$$;

-- 4f. update_my_location. Suspended accounts are already hidden from the
-- map; this stops them storing a spot at all. Same as 20260928000000, plus
-- the check.
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
  if public.is_suspended(v_me) then
    raise exception 'account_suspended' using errcode = '42501';
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

-- 4g. Admin RPCs: a suspended admin loses admin power. Every admin RPC
-- starts with _require_admin(). (The events "Admins can delete" policy is
-- covered by the restrictive delete policy above.)
create or replace function public._require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() or public.is_suspended(auth.uid()) then
    raise exception 'admin_only' using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public._require_admin() from public, anon, authenticated;

-- 4h. report_user: suspended accounts may now report (they were refused).
-- Same as 20260928020000 without the suspended check.
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

-- 4i. report_event: suspended accounts may report, but their reports don't
-- count toward auto-hiding an event (so a banned account's sock puppets
-- can't knock events off the map). An admin still sees them.
-- Same as 20260928030000 with those two changes.
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

  -- Only reports from accounts old enough (and not suspended) count, so a
  -- handful of brand-new or banned accounts can't knock an event off the
  -- map. Age comes from auth.users (see _account_created_at).
  select count(*) into v_counted
  from public.event_reports er
  where er.event_id = p_event_id
    and er.status = 'open'
    and not public.is_suspended(er.reporter_id)
    and public._account_created_at(er.reporter_id)
        <= now() - make_interval(days => (r ->> 'reporter_min_account_age_days')::int);

  if v_event.status = 'active' and v_counted >= (r ->> 'auto_hide_reports')::int then
    update public.events set status = 'hidden' where id = p_event_id;
    v_hidden := true;
  end if;

  return jsonb_build_object('outcome', 'reported', 'hidden', v_hidden);
end;
$$;
