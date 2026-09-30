-- Security batch fix-ups: problems found reviewing all the security/*
-- branches together (security/all), plus the follow-ups Zane chose.
--
--   1. _require_admin: M5 replaced H4's version and lost the aal2 hint.
--   2. QR codes (H2): 'too_far' answers could be used to find where a code's
--      owner is (test a guessed spot, again and again, for 30 s). Now a code
--      is burned after 3 'too_far' tries, and the allowed distance is capped
--      at 1 km however bad either phone claims its accuracy is.
--   3. Avatar URLs (H5): '..' in the path (avatars/<me>/../<other>/x.jpg)
--      passed the prefix check. Only one plain file name after the folder
--      is allowed now.
--   4. Rate limits (M4): two messages (or requests) sent at the same instant
--      could both be counted before either was saved, slipping past the cap.
--      The checks now take a per-person lock first.
--   5. Two-step verification on the server (everyone who turned it on, not
--      just admins): with a verified authenticator app, a password-only
--      (aal1) session can't read or write anything through the API until the
--      code is entered. The app enforced this on screen only (H4).
--   6. Tighter access:
--        - other people's settings (location_sharing, notifications_enabled,
--          updated_at) aren't readable; your own row comes from
--          get_my_profile();
--        - get_mutuals returns the four card columns, not whole profile rows;
--        - signed-out (anon) and signed-in roles lose table privileges no
--          policy uses, and anon loses execute on functions it never needs
--          (AGENTS.md rule 3).

-- ---------------------------------------------------------------------------
-- 1. _require_admin: M5's checks + H4's hint
-- ---------------------------------------------------------------------------

create or replace function public._require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() or public.is_suspended(auth.uid()) then
    raise exception 'admin_only' using errcode = '42501',
      hint = 'Admins need two-step verification (an aal2 session) and an active account.';
  end if;
end;
$$;

revoke execute on function public._require_admin() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. QR codes: limit 'too_far' tries, cap the distance
-- ---------------------------------------------------------------------------

alter table public.connect_tokens
  add column too_far_count int not null default 0;

-- Same as 20260929020000, except:
--   - allowed distance = max(300 m, min(owner accuracy + scanner accuracy, 1 km))
--   - each 'too_far' is counted on the code; the 3rd burns it (marked used,
--     with no result, and its location erased). The owner's phone sees
--     'used' and shows a fresh code.
create or replace function public.redeem_connect_token(
  p_token text,
  p_city text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_m double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunables.
  c_min_distance_m constant float8 := 300;   -- always allow at least this
  c_max_distance_m constant float8 := 1000;  -- never allow more than this
  c_max_accuracy_m constant float8 := 1000;  -- worse -> poor_location
  c_max_too_far constant int := 3;           -- then the code is burned

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

  -- Both phones must say where they are, and be close enough.
  if p_lat is null or p_lng is null or p_accuracy_m is null or v_tok.lat is null then
    return jsonb_build_object('outcome', 'location_required');
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy_m <= 0 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;
  if p_accuracy_m > c_max_accuracy_m then
    return jsonb_build_object('outcome', 'poor_location');
  end if;
  if public._distance_m(p_lat, p_lng, v_tok.lat, v_tok.lng)
     > greatest(c_min_distance_m, least(v_tok.accuracy_m + p_accuracy_m, c_max_distance_m)) then
    -- A GPS glitch gets a couple more tries; after that the code is spent,
    -- so nobody can keep guessing where its owner is.
    update public.connect_tokens set
      too_far_count = too_far_count + 1,
      used_at = case when too_far_count + 1 >= c_max_too_far then now() end,
      lat = case when too_far_count + 1 >= c_max_too_far then null else lat end,
      lng = case when too_far_count + 1 >= c_max_too_far then null else lng end,
      accuracy_m = case when too_far_count + 1 >= c_max_too_far then null else accuracy_m end
    where token = p_token;
    return jsonb_build_object('outcome', 'too_far');
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

  -- The owner's copy names the scanner as "the other person". The code's
  -- location isn't needed any more, so it goes now.
  update public.connect_tokens set
    used_at = now(),
    used_by = v_me,
    lat = null,
    lng = null,
    accuracy_m = null,
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

revoke execute on function
  public.redeem_connect_token(text, text, double precision, double precision, double precision)
  from public, anon;
grant execute on function
  public.redeem_connect_token(text, text, double precision, double precision, double precision)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Avatar URLs: one plain file name inside the owner's folder
-- ---------------------------------------------------------------------------

-- Same allowed projects as 20260929040000. After "<project>/.../avatars/<id>/"
-- only a single file name made of letters, digits, '.', '_' and '-' may
-- follow (what uploadAvatar and the seed script produce: <ms>.jpg,
-- seed-<ms>.jpg), and never '..'. No more slashes, '%', '?', '#' or '\'.
-- The check constraint calls this function, so replacing it is enough.
create or replace function public.avatar_url_allowed(p_profile_id uuid, p_url text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_url is null
    or (
      (
        starts_with(
          p_url,
          -- PRODUCTION project.
          'https://fhevoocpcnrjxyjvitai.supabase.co/storage/v1/object/public/avatars/'
            || p_profile_id::text || '/'
        )
        or starts_with(
          p_url,
          -- DEV project (bolas-dev).
          'https://ojrtebubjvkhpiryilum.supabase.co/storage/v1/object/public/avatars/'
            || p_profile_id::text || '/'
        )
      )
      and split_part(p_url, '/avatars/' || p_profile_id::text || '/', 2) ~ '^[A-Za-z0-9._-]{1,100}$'
      and strpos(split_part(p_url, '/avatars/' || p_profile_id::text || '/', 2), '..') = 0
    );
$$;

-- ---------------------------------------------------------------------------
-- 4. Rate limits: one check at a time per person
-- ---------------------------------------------------------------------------

-- Same as 20260929070000 plus the advisory lock (held until the insert's
-- transaction ends, so a second message from the same person waits and then
-- counts the first).
create or replace function public.messages_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._rate_limits();
  v_new boolean;
  v_per_minute int;
  v_per_day int;
  v_count int;
begin
  if not public._is_untrusted_write() then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bolas.messages_rate_limit:' || new.sender_id::text, 0));

  -- The insert policy doesn't restrict created_at, so a client could send
  -- it backdated and slip under the per-minute count (and jump the chat's
  -- order). Always stamp it with the real time.
  new.created_at := now();

  v_new := public._is_new_account(new.sender_id);
  v_per_minute := (r ->> case when v_new then 'new_account_messages_per_minute' else 'messages_per_minute' end)::int;
  v_per_day := (r ->> case when v_new then 'new_account_messages_per_day' else 'messages_per_day' end)::int;

  select count(*) into v_count
  from (
    select 1 from public.messages m
    where m.sender_id = new.sender_id and m.created_at > now() - interval '1 minute'
    limit v_per_minute
  ) recent;
  if v_count >= v_per_minute then
    raise exception 'message_rate_limited' using errcode = 'P0001', detail = 'minute';
  end if;

  select count(*) into v_count
  from (
    select 1 from public.messages m
    where m.sender_id = new.sender_id and m.created_at > now() - interval '24 hours'
    limit v_per_day
  ) recent;
  if v_count >= v_per_day then
    raise exception 'message_rate_limited' using errcode = 'P0001', detail = 'day';
  end if;

  return new;
end;
$$;

revoke execute on function public.messages_rate_limit() from public, anon, authenticated;

create or replace function public.connections_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._rate_limits();
  v_per_day int;
  v_count int;
begin
  if not public._is_untrusted_write() then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bolas.connections_rate_limit:' || new.requester_id::text, 0));

  v_per_day := (r ->> case when public._is_new_account(new.requester_id)
                        then 'new_account_connection_requests_per_day'
                        else 'connection_requests_per_day' end)::int;

  select count(*) into v_count
  from (
    select 1 from public.connection_request_log l
    where l.user_id = new.requester_id and l.created_at > now() - interval '24 hours'
    limit v_per_day
  ) recent;
  if v_count >= v_per_day then
    raise exception 'connection_rate_limited' using errcode = 'P0001', detail = 'day';
  end if;

  return new;
end;
$$;

revoke execute on function public.connections_rate_limit() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Two-step verification enforced by the database
-- ---------------------------------------------------------------------------

-- True unless the caller has a verified authenticator app (auth.mfa_factors)
-- and this session hasn't entered a code (aal1). Signed-out callers and
-- accounts without two-step are unaffected. Definer: clients can't read the
-- auth schema.
create or replace function public._mfa_ok()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is null
    or coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
    or not exists (
      select 1 from auth.mfa_factors f
      where f.user_id = auth.uid() and f.status = 'verified'
    );
$$;

revoke execute on function public._mfa_ok() from public, anon;
-- Policies run as the caller, so the caller must be able to execute it.
grant execute on function public._mfa_ok() to authenticated;

-- 5a. Every API request (tables AND RPCs): PostgREST calls this before the
-- request runs, and the error stops it. The app's code screen talks only to
-- Supabase Auth (not this API), so it keeps working.
create or replace function public._check_request()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._mfa_ok() then
    raise exception 'mfa_required' using errcode = '42501',
      hint = 'Enter your two-step verification code first.';
  end if;
end;
$$;

revoke execute on function public._check_request() from public;
grant execute on function public._check_request() to anon, authenticated;

-- Supabase's API role reads this setting. Only set where that role exists
-- (not in local test databases).
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    alter role authenticator set pgrst.db_pre_request = 'public._check_request';
    notify pgrst, 'reload config';
  end if;
end
$$;

-- 5b. The same rule as RESTRICTIVE policies on every table clients can
-- touch, which also covers Realtime (live messages) and Storage, which
-- don't go through the pre-request check. (select ...) = once per query.
create policy "Two-step code required" on public.account_restrictions
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.connections
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.conversation_participants
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.conversations
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.event_attendees
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.event_locations
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.events
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.host_permissions
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.messages
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.profiles
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.user_blocks
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on public.user_consents
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));
create policy "Two-step code required" on storage.objects
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));

-- ---------------------------------------------------------------------------
-- 6. Tighter access
-- ---------------------------------------------------------------------------

-- 6a. Profiles: everyone signed in can read the public columns; settings
-- and timestamps only through get_my_profile(). Column grants apply to
-- every row, so the owner reads their own full row through the RPC.
-- Updates still work: the app updates its own row by id and doesn't ask for
-- the row back.
revoke select on public.profiles from anon, authenticated;
grant select (id, username, full_name, avatar_url, bio, interests, business_stage, city)
  on public.profiles to authenticated;

-- The caller's own profile row (all columns), or no row.
create or replace function public.get_my_profile()
returns setof public.profiles
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  return query select * from public.profiles where id = auth.uid();
end;
$$;

revoke execute on function public.get_my_profile() from public, anon;
grant execute on function public.get_my_profile() to authenticated;

-- 6b. get_mutuals: only the card columns (it used to return whole rows,
-- settings included). Same people as 20260928020000.
drop function public.get_mutuals(uuid);

create function public.get_mutuals(other_user uuid)
returns table (id uuid, username text, full_name text, avatar_url text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url
  from public.profiles p
  where auth.uid() is not null
    and not public._blocked_between(auth.uid(), other_user)
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

revoke execute on function public.get_mutuals(uuid) from public, anon;
grant execute on function public.get_mutuals(uuid) to authenticated;

-- 6c. Table privileges no policy uses. RLS already blocks these (no policy =
-- no rows), so nothing that works today changes; this is the second lock.
-- For every public table: anon keeps only what an anon policy allows,
-- authenticated keeps only the commands it has a policy for, and nobody
-- keeps TRUNCATE / REFERENCES / TRIGGER (TRUNCATE ignores RLS).
do $$
declare
  t record;
  v_cmd text;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
  loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', t.relname);
    foreach v_cmd in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if not exists (
        select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = t.relname
          and p.permissive = 'PERMISSIVE' and p.cmd in (v_cmd, 'ALL')
          and p.roles && array['anon', 'public']::name[]
      ) then
        execute format('revoke %s on public.%I from anon', v_cmd, t.relname);
      end if;
      if not exists (
        select 1 from pg_policies p
        where p.schemaname = 'public' and p.tablename = t.relname
          and p.permissive = 'PERMISSIVE' and p.cmd in (v_cmd, 'ALL')
          and p.roles && array['authenticated', 'public']::name[]
      ) then
        execute format('revoke %s on public.%I from authenticated', v_cmd, t.relname);
      end if;
    end loop;
  end loop;
end
$$;

-- 6d. Functions anon never needs. The trigger functions can't be called
-- through the API anyway; the rest return nothing without a signed-in user.
revoke execute on function public.handle_new_message() from public, anon, authenticated;
revoke execute on function public.handle_updated_at() from public, anon, authenticated;
revoke execute on function public.get_total_unread_count() from public, anon;
revoke execute on function public.get_unread_counts() from public, anon;
revoke execute on function public.avatar_url_allowed(uuid, text) from public, anon;
revoke execute on function public.profile_interest_options() from public, anon;
revoke execute on function public.profile_interests_valid(text[]) from public, anon;
revoke execute on function public.username_is_reserved(text) from public, anon;
-- Signed-in users still need these (revoking from public can take away a
-- grant they only had through public).
grant execute on function public.get_total_unread_count() to authenticated;
grant execute on function public.get_unread_counts() to authenticated;
grant execute on function public.avatar_url_allowed(uuid, text) to authenticated;
grant execute on function public.profile_interest_options() to authenticated;
grant execute on function public.profile_interests_valid(text[]) to authenticated;
grant execute on function public.username_is_reserved(text) to authenticated;
