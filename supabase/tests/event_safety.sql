-- Safer map events tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run against the live database: everything happens inside one DO
-- block that ALWAYS ends by raising an exception, which rolls back every test
-- user and row it created. The exception message is the test report — look
-- for "TEST RESULTS" and any FAIL lines.
--
--   npx supabase db query --linked -f supabase/tests/event_safety.sql
--
-- Sections: A = hosting trust, B = write lock + validation, C = location,
-- D = attendee privacy, E = reports + admin.

-- Admin logins carry 'aal': 'aal2': since 20260929030000 (security item H4)
-- admin power needs two-step verification.
do $tests$
declare
  -- Hosts
  u_new uuid := gen_random_uuid();       -- 1 day old, 0 in-person
  u_trusted uuid := gen_random_uuid();   -- 8 days old, 3 in-person
  u_acq uuid := gen_random_uuid();       -- 8 days old, 3 acquaintances only
  u_appr uuid := gen_random_uuid();      -- 1 day old, approved by an admin
  u_susp uuid := gen_random_uuid();      -- 8 days old, 3 in-person, suspended
  u_admin uuid := gen_random_uuid();     -- 1 day old, admin
  u_noname uuid := gen_random_uuid();    -- no username yet
  u_rate uuid := gen_random_uuid();      -- approved; used for the daily limit
  -- People to connect with
  f1 uuid := gen_random_uuid();
  f2 uuid := gen_random_uuid();
  f3 uuid := gen_random_uuid();

  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  v jsonb;
  v2 jsonb;
  n int;
  eid uuid;
  eid_conn uuid;
  eid_a uuid;
  eid_h uuid;
  eid_r uuid;
  eid_e uuid;
  x uuid;
  succ int;
  eid_c2 uuid;
  rec record;
  e public.events%rowtype;
  t0 timestamptz := date_trunc('minute', now()) + interval '1 day';
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - age
  from (values
    (u_new, interval '1 day'),
    (u_trusted, interval '8 days'),
    (u_acq, interval '8 days'),
    (u_appr, interval '1 day'),
    (u_susp, interval '8 days'),
    (u_admin, interval '1 day'),
    (u_noname, interval '8 days'),
    (u_rate, interval '1 day'),
    (f1, interval '30 days'),
    (f2, interval '30 days'),
    (f3, interval '30 days')
  ) as t (id, age);

  -- handle_new_user made the profile rows; give everyone but u_noname a username.
  update public.profiles
  set username = 'es_' || left(replace(id::text, '-', ''), 12)
  where id in (u_new, u_trusted, u_acq, u_appr, u_susp, u_admin, u_rate, f1, f2, f3);

  perform public._connect_in_person(u_trusted, f, 'qr', null) from unnest(array[f1, f2, f3]) as f;
  perform public._connect_in_person(u_susp, f, 'qr', null) from unnest(array[f1, f2, f3]) as f;
  insert into public.connections (requester_id, addressee_id, status)
  select u_acq, f, 'accepted' from unnest(array[f1, f2, f3]) as f;

  insert into public.host_permissions (user_id, status) values
    (u_appr, 'approved'), (u_susp, 'suspended'), (u_rate, 'approved');
  insert into public.app_admins (user_id) values (u_admin);

  -- =====================================================================
  -- A. Hosting trust
  -- =====================================================================

  perform set_config('role', 'authenticated', true);

  -- A1: a 1-day-old account can't post public...
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  v := public.create_event('Coffee chat', null, 'Flying M', 43.6, -116.2, t0, null, 'public');
  ok := v ->> 'outcome' = 'public_locked' and v ->> 'reason' = 'new_account'
        and (v ->> 'in_person_count')::int = 0 and (v ->> 'needed_in_person')::int = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A1 new account: public -> public_locked (' || v::text || ')';
  if not ok then fails := fails + 1; end if;

  -- A2: ...but can post connections-only.
  v := public.create_event('Coffee chat', null, 'Flying M', 43.6, -116.2, t0, null, 'connections');
  eid_conn := (v ->> 'event_id')::uuid;
  ok := v ->> 'outcome' = 'created' and eid_conn is not null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A2 new account: connections-only -> created';
  if not ok then fails := fails + 1; end if;

  -- A3: 8 days old + 3 in-person -> public works.
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.create_event('Pitch night', 'Bring a deck', 'Trailhead', 43.6, -116.2, t0, t0 + interval '2 hours', 'public');
  eid := (v ->> 'event_id')::uuid;
  ok := v ->> 'outcome' = 'created';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A3 8 days + 3 in-person: public -> created';
  if not ok then fails := fails + 1; end if;

  -- A4: 8 days old + 3 acquaintances only -> still locked.
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  v := public.create_event('Study session', null, null, 43.6, -116.2, t0, null, 'public');
  ok := v ->> 'outcome' = 'public_locked' and v ->> 'reason' = 'needs_in_person';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A4 8 days + 3 acquaintances: public -> public_locked/needs_in_person';
  if not ok then fails := fails + 1; end if;

  -- A5: approved host, 1 day old -> public works.
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.create_event('Founder lunch', null, null, 43.6, -116.2, t0, null, 'public');
  ok := v ->> 'outcome' = 'created';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A5 approved 1-day-old host: public -> created';
  if not ok then fails := fails + 1; end if;

  -- A6: suspended -> not_allowed for both kinds.
  perform set_config('request.jwt.claims', json_build_object('sub', u_susp, 'role', 'authenticated')::text, true);
  v := public.create_event('Meetup', null, null, 43.6, -116.2, t0, null, 'public');
  v2 := public.create_event('Meetup', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := v ->> 'outcome' = 'not_allowed' and v ->> 'reason' = 'suspended'
        and v2 ->> 'outcome' = 'not_allowed' and v2 ->> 'reason' = 'suspended';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A6 suspended: public and connections -> not_allowed';
  if not ok then fails := fails + 1; end if;

  -- A7: no username yet -> not_allowed / no_profile.
  perform set_config('request.jwt.claims', json_build_object('sub', u_noname, 'role', 'authenticated')::text, true);
  v := public.create_event('Meetup', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := v ->> 'outcome' = 'not_allowed' and v ->> 'reason' = 'no_profile';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A7 no username: -> not_allowed/no_profile';
  if not ok then fails := fails + 1; end if;

  -- A8: the admin (1 day old) posts public and skips the limits: 6 creates
  -- in a row (over both the active and the daily limit) all succeed.
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  n := 0;
  for i in 1..6 loop
    v := public.create_event('Admin event ' || i, null, null, 43.6, -116.2, t0, null, 'public');
    if v ->> 'outcome' = 'created' then n := n + 1; end if;
  end loop;
  ok := n = 6;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A8 admin: 6 public creates in a row all created (got ' || n || ')';
  if not ok then fails := fails + 1; end if;

  -- A9: get_my_hosting_status progress numbers.
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  v := public.get_my_hosting_status();
  ok := (v ->> 'can_host')::boolean and not (v ->> 'can_host_public')::boolean
        and v ->> 'reason' = 'new_account' and (v ->> 'account_age_days')::int = 1
        and (v ->> 'in_person_count')::int = 0 and (v ->> 'needed_age_days')::int = 7
        and (v ->> 'active_events')::int = 1 and (v ->> 'max_active_events')::int = 3
        and not (v ->> 'is_admin')::boolean;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A9 status for new account (' || v::text || ')';
  if not ok then fails := fails + 1; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.get_my_hosting_status();
  ok := (v ->> 'can_host_public')::boolean and v -> 'reason' = 'null'::jsonb
        and (v ->> 'account_age_days')::int = 8 and (v ->> 'in_person_count')::int = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A10 status for trusted account: can_host_public, reason null';
  if not ok then fails := fails + 1; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.get_my_hosting_status();
  ok := (v ->> 'is_admin')::boolean and (v ->> 'can_host_public')::boolean;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A11 status for admin: is_admin, can_host_public';
  if not ok then fails := fails + 1; end if;

  -- A12: backdating your own profiles.created_at doesn't skip the wait.
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  update public.profiles set created_at = now() - interval '1 year' where id = u_new;
  v := public.get_my_hosting_status();
  ok := (v ->> 'account_age_days')::int = 1 and v ->> 'reason' = 'new_account';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A12 backdated profiles.created_at is ignored (age from auth.users)';
  if not ok then fails := fails + 1; end if;

  -- A13: signed-out callers can't use the RPCs or read the internal tables.
  reset role;
  perform set_config('role', 'anon', true);
  n := 0;
  begin perform public.get_my_hosting_status(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.create_event('x', null, null, 0, 0, t0, null, 'connections'); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.is_admin(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A13 anon is refused by get_my_hosting_status / create_event / is_admin (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- A14: signed-in users can't reach the internal tables or helpers.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  n := 0;
  select n + count(*) into n from public.app_admins;
  select n + count(*) into n from public.event_creation_log;
  select n + count(*) into n from public.blocked_terms;   -- was event_blocked_terms (merged in 20260928020000)
  select n + count(*) into n from public.host_permissions;   -- u_trusted has no row
  begin perform public._hosting_status(u_new); n := n + 100; exception when others then null; end;
  begin perform public._event_rules(); n := n + 100; exception when others then null; end;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A14 internal tables read as empty, private helpers refused';
  if not ok then fails := fails + 1; end if;

  -- A15: a user can read their own host_permissions row.
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  select count(*) into n from public.host_permissions;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A15 users see their own host_permissions row';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- B. Write lock + validation
  -- =====================================================================

  -- B1: a direct insert into events fails.
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  err := null;
  begin
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (u_trusted, 'Sneaky', 43.6, -116.2, t0, 'public');
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B1 direct insert into events is refused (' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- B2: a direct update of your own event changes nothing.
  update public.events set title = 'Hacked', approx_latitude = 0 where id = eid;
  reset role;
  select * into e from public.events where id = eid;
  ok := e.title = 'Pitch night' and e.approx_latitude <> 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B2 direct update of own event changes nothing';
  if not ok then fails := fails + 1; end if;

  -- B3: validation.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.create_event('Late', null, null, 43.6, -116.2, now() - interval '1 hour', null, 'connections');
  ok := v ->> 'outcome' = 'invalid' and v ->> 'field' = 'starts_at';
  v := public.create_event('Far', null, null, 43.6, -116.2, now() + interval '100 days', null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'starts_at';
  v := public.create_event('Long', null, null, 43.6, -116.2, t0, t0 + interval '30 hours', 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'ends_at';
  v := public.create_event('Backwards', null, null, 43.6, -116.2, t0, t0 - interval '1 hour', 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'ends_at';
  v := public.create_event('   ', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'title';
  v := public.create_event(repeat('x', 61), null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'title';
  v := public.create_event('Desc', repeat('x', 501), null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'description';
  v := public.create_event('Place', null, repeat('x', 101), 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'location_name';
  v := public.create_event('Pole', null, null, 95, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'location';
  v := public.create_event('Secret', null, null, 43.6, -116.2, t0, null, 'secret');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'visibility';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B3 validation: past/far start, 30h, backwards end, title, description, place, coords, visibility';
  if not ok then fails := fails + 1; end if;

  -- B4: blocked terms, matched as whole words/phrases, any case/spacing.
  v := public.create_event('Passive Income night', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := v ->> 'outcome' = 'blocked_content';
  v := public.create_event('Networking', 'Interested? DM   me', null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'blocked_content';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B4 blocked terms in title / description -> blocked_content';
  if not ok then fails := fails + 1; end if;

  -- B5: no false positive for a phrase that only starts the same way.
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.create_event('Founders DM meetup', 'Information session', null, 43.6, -116.2, t0, null, 'connections');
  ok := v ->> 'outcome' = 'created';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B5 "DM meetup" / "Information" are not blocked';
  if not ok then fails := fails + 1; end if;

  -- B6: the 4th active event -> too_many_active (u_appr already has 1).
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.create_event('Second', null, null, 43.6, -116.2, t0, null, 'connections');
  v := public.create_event('Third', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := v ->> 'outcome' = 'created';
  v := public.create_event('Fourth', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'too_many_active';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B6 4th active event -> too_many_active';
  if not ok then fails := fails + 1; end if;

  -- B7: the 6th create in 24 h -> rate_limited, even after deleting.
  -- Create 3, delete them all, create 2 more (5 total, 2 active), then #6.
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  for i in 1..3 loop
    perform public.create_event('Throwaway ' || i, null, null, 43.6, -116.2, t0, null, 'connections');
  end loop;
  delete from public.events where creator_id = u_rate;
  get diagnostics n = row_count;
  ok := n = 3;
  v := public.create_event('Four', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'created';
  v := public.create_event('Five', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'created';
  v := public.create_event('Six', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'rate_limited';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B7 6th create in 24h -> rate_limited, deleting does not reset it';
  if not ok then fails := fails + 1; end if;

  -- B8: update_event by someone else -> not_found, and nothing changes.
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.update_event(eid, 'Mine now', null, t0, null, 'public');
  reset role;
  select * into e from public.events where id = eid;
  ok := v ->> 'outcome' = 'not_found' and e.title = 'Pitch night';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B8 update_event by a non-creator -> not_found';
  if not ok then fails := fails + 1; end if;

  -- B9: a text-only edit leaves time_changed_at alone; a time change sets it.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.update_event(eid, '  Pitch night v2 ', 'Bring a deck', t0, t0 + interval '2 hours', 'public');
  select * into e from public.events where id = eid;
  ok := v ->> 'outcome' = 'updated' and e.title = 'Pitch night v2' and e.time_changed_at is null
        and exists (select 1 from public.event_locations where event_id = eid and latitude = 43.6);
  v := public.update_event(eid, 'Pitch night v2', 'Bring a deck', t0 + interval '1 hour', t0 + interval '3 hours', 'public');
  select * into e from public.events where id = eid;
  ok := ok and v ->> 'outcome' = 'updated' and e.time_changed_at is not null
        and e.starts_at = t0 + interval '1 hour';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B9 text edit keeps time_changed_at null; moving the time sets it';
  if not ok then fails := fails + 1; end if;

  -- B10: update_event also validates and checks content.
  v := public.update_event(eid, 'Pitch night v2', null, t0, t0 + interval '30 hours', 'public');
  ok := v ->> 'outcome' = 'invalid' and v ->> 'field' = 'ends_at';
  v := public.update_event(eid, 'Forex pitch night', null, t0, null, 'public');
  ok := ok and v ->> 'outcome' = 'blocked_content';
  v := public.update_event(eid, 'Pitch night v2', null, now() - interval '1 hour', null, 'public');
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'starts_at';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B10 update_event validates times, content, and moving start into the past';
  if not ok then fails := fails + 1; end if;

  -- B11: an event already underway can still be edited if its start doesn't move.
  reset role;
  update public.events set starts_at = now() - interval '1 hour', ends_at = null where id = eid;
  select * into e from public.events where id = eid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.update_event(eid, 'Pitch night (now!)', null, e.starts_at, null, 'public');
  ok := v ->> 'outcome' = 'updated';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B11 event underway: edit with unchanged past start -> updated';
  if not ok then fails := fails + 1; end if;

  -- B12: untrusted host can't switch connections -> public, but can go the
  -- other way.
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  v := public.update_event(eid_conn, 'Coffee chat', null, t0, null, 'public');
  ok := v ->> 'outcome' = 'public_locked';
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.update_event(eid, 'Pitch night (now!)', null, e.starts_at, null, 'connections');
  ok := ok and v ->> 'outcome' = 'updated';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B12 untrusted connections->public -> public_locked; public->connections ok';
  if not ok then fails := fails + 1; end if;

  -- B13: hidden events: the host still sees theirs but can't delete it;
  -- others can't see it; an admin can delete it.
  reset role;
  update public.events set status = 'hidden', visibility = 'public' where id = eid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  select count(*) into n from public.events where id = eid;
  ok := n = 1;
  delete from public.events where id = eid;
  get diagnostics n = row_count;
  ok := ok and n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', f1, 'role', 'authenticated')::text, true);
  select count(*) into n from public.events where id = eid;
  ok := ok and n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select count(*) into n from public.events where id = eid;
  ok := ok and n = 1;
  delete from public.events where id = eid;
  get diagnostics n = row_count;
  ok := ok and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B13 hidden: host sees but cannot delete; others cannot see; admin deletes';
  if not ok then fails := fails + 1; end if;

  -- B14: update_event on a removed event -> event_removed.
  reset role;
  update public.events set status = 'removed' where id = eid_conn;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  v := public.update_event(eid_conn, 'Coffee chat', null, t0, null, 'connections');
  ok := v ->> 'outcome' = 'event_removed';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B14 update_event on a removed event -> event_removed';
  if not ok then fails := fails + 1; end if;

  -- B15: the host still counts as going (handle_new_event ran inside the RPC).
  reset role;
  select count(*) into n
  from public.events ev
  join public.event_attendees a on a.event_id = ev.id and a.user_id = ev.creator_id
  where ev.creator_id = u_appr;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B15 host auto-RSVP still added for RPC-created events (got ' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- C. Approximate location until you RSVP
  -- =====================================================================

  -- A public event by u_trusted. u_acq is a stranger to them (not connected);
  -- f1 is connected to them but not going.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  v := public.create_event('Library cowork', null, '  Boise Library  ', 43.615, -116.2023, t0, null, 'public');
  eid := (v ->> 'event_id')::uuid;

  -- C1: a stranger sees the fuzzed point only.
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries s
  where s.id = eid
    and s.approx_latitude is not null and s.approx_longitude is not null
    and s.exact_latitude is null and s.exact_longitude is null and s.location_name is null;
  ok := v ->> 'outcome' = 'created' and n = 1;
  select count(*) into n from public.event_locations where event_id = eid;
  ok := ok and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C1 stranger: approx only; exact_*, location_name null; event_locations empty';
  if not ok then fails := fails + 1; end if;

  -- C2: after tapping Going, the exact spot and place name unlock.
  insert into public.event_attendees (event_id, user_id) values (eid, u_acq);
  select count(*) into n from public.event_summaries s
  where s.id = eid and s.exact_latitude = 43.615 and s.exact_longitude = -116.2023
    and s.location_name = 'Boise Library' and s.is_going;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C2 after RSVP: exact spot + trimmed place name visible';
  if not ok then fails := fails + 1; end if;

  -- C3: after un-RSVP, hidden again.
  delete from public.event_attendees where event_id = eid and user_id = u_acq;
  select count(*) into n from public.event_summaries s
  where s.id = eid and s.exact_latitude is null and s.location_name is null and not s.is_going;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C3 after un-RSVP: exact spot hidden again';
  if not ok then fails := fails + 1; end if;

  -- C4: the host and an admin always see it; a connection who isn't going doesn't.
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries s where s.id = eid and s.exact_latitude = 43.615;
  ok := n = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select count(*) into n from public.event_summaries s where s.id = eid and s.exact_latitude = 43.615;
  ok := ok and n = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', f1, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries s where s.id = eid and s.exact_latitude is null;
  ok := ok and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C4 host + admin see exact; a non-going connection does not';
  if not ok then fails := fails + 1; end if;

  -- C5: nobody can write event_locations directly (not even the host).
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  update public.event_locations set latitude = 0, location_name = 'My house' where event_id = eid;
  get diagnostics n = row_count;
  ok := n = 0;
  err := null;
  begin
    insert into public.event_locations (event_id, latitude, longitude) values (eid_conn, 0, 0);
  exception when others then err := sqlstate;
  end;
  ok := ok and err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C5 direct insert/update of event_locations refused';
  if not ok then fails := fails + 1; end if;

  -- C6: the fuzzed point is stored, not re-rolled on every read.
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  select s.approx_latitude::text || ',' || s.approx_longitude::text into err
  from public.event_summaries s where s.id = eid;
  select count(*) into n from public.event_summaries s
  where s.id = eid and s.approx_latitude::text || ',' || s.approx_longitude::text = err;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C6 approx point is stable across reads';
  if not ok then fails := fails + 1; end if;
  reset role;

  -- C7: every event (including real ones backfilled by the migration) has an
  -- exact row, and its fuzzed point is 150–350 m away (0.5 m float slack).
  select count(*) into n
  from public.events ev
  left join public.event_locations l on l.event_id = ev.id
  where l.event_id is null
     or public._distance_m(ev.approx_latitude, ev.approx_longitude, l.latitude, l.longitude)
        not between 149.5 and 350.5;
  ok := n = 0;
  select count(*) into n from public.events;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C7 all ' || n || ' events: has exact row, approx is 150–350 m away';
  if not ok then fails := fails + 1; end if;

  -- C8: 2,000 fuzzes of one spot: always in range, the whole range gets
  -- used, and every direction shows up (each quadrant gets a fair share).
  select
    min(d) >= 149.5 and max(d) <= 350.5 and min(d) < 160 and max(d) > 340
    and least(
      count(*) filter (where f.lat > 43.615 and f.lng > -116.2023),
      count(*) filter (where f.lat > 43.615 and f.lng <= -116.2023),
      count(*) filter (where f.lat <= 43.615 and f.lng > -116.2023),
      count(*) filter (where f.lat <= 43.615 and f.lng <= -116.2023)
    ) > 400
  into ok
  from generate_series(1, 2000) g
  -- "+ 0 * g" ties each call to its row; with constant arguments Postgres
  -- runs the function once and reuses the answer for all 2,000 rows.
  cross join lateral public._fuzz_point(43.615 + 0 * g, -116.2023) f
  cross join lateral (select public._distance_m(43.615, -116.2023, f.lat, f.lng) as d) dd;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C8 2,000 fuzzes: 150–350 m, full range, all directions';
  if not ok then fails := fails + 1; end if;

  -- C9: the old exact columns are gone from events.
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'events'
    and column_name in ('latitude', 'longitude', 'location_name');
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C9 events.latitude / longitude / location_name dropped';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- D. Attendee privacy
  -- =====================================================================

  -- eid is u_trusted's public event from C (only the host is going so far).
  -- Who knows whom: f1 met u_trusted in person; u_acq is an acquaintance of
  -- f1, f2, f3; u_new is (from here on) an acquaintance of f2; u_rate knows
  -- nobody.
  insert into public.connections (requester_id, addressee_id, status) values (u_new, f2, 'accepted');
  perform set_config('role', 'authenticated', true);
  foreach x in array array[f1, f2, u_acq] loop
    perform set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
    insert into public.event_attendees (event_id, user_id) values (eid, x);
  end loop;

  -- D1: a stranger sees the right count but no attendee rows.
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  select s.going_count into n from public.event_summaries s where s.id = eid;
  ok := n = 4;
  select count(*) into n from public.event_attendees where event_id = eid;
  ok := ok and n = 0;
  select count(*) into n from public.get_event_attendees(eid);
  ok := ok and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D1 stranger: going_count = 4, sees no attendee rows';
  if not ok then fails := fails + 1; end if;

  -- D2: someone connected to one attendee sees just that attendee.
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_event_attendees(eid);
  ok := n = 1 and exists (
    select 1 from public.get_event_attendees(eid) g where g.user_id = f2 and g.is_connection and not g.is_host
  );
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D2 connection of one attendee sees only that attendee';
  if not ok then fails := fails + 1; end if;

  -- D3: an attendee sees themselves plus their connections who are going
  -- (f1: self, the host, u_acq — not f2), host listed first.
  perform set_config('request.jwt.claims', json_build_object('sub', f1, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_event_attendees(eid);
  ok := n = 3
    and (select g.user_id from public.get_event_attendees(eid) g limit 1) = u_trusted
    and not exists (select 1 from public.get_event_attendees(eid) g where g.user_id = f2);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D3 attendee sees self + own connections (host first), not strangers';
  if not ok then fails := fails + 1; end if;

  -- D4: the host and an admin see everyone.
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_event_attendees(eid);
  ok := n = 4
    and (select count(*) from public.get_event_attendees(eid) g where g.is_host and g.user_id = u_trusted) = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select count(*) into n from public.get_event_attendees(eid);
  ok := ok and n = 4;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D4 host and admin see all 4 attendees';
  if not ok then fails := fails + 1; end if;

  -- D5: RSVP to a hidden, removed, or ended event fails; an active one works.
  eid_h := (public.create_event('Hidden', null, null, 43.6, -116.2, t0, null, 'public') ->> 'event_id')::uuid;
  eid_r := (public.create_event('Removed', null, null, 43.6, -116.2, t0, null, 'public') ->> 'event_id')::uuid;
  eid_e := (public.create_event('Ended', null, null, 43.6, -116.2, t0, null, 'public') ->> 'event_id')::uuid;
  eid_a := (public.create_event('Active', null, null, 43.6, -116.2, t0, null, 'public') ->> 'event_id')::uuid;
  reset role;
  update public.events set status = 'hidden' where id = eid_h;
  update public.events set status = 'removed' where id = eid_r;
  update public.events set starts_at = now() - interval '5 hours', ends_at = null where id = eid_e;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  n := 0;
  foreach x in array array[eid_h, eid_r, eid_e] loop
    begin
      insert into public.event_attendees (event_id, user_id) values (x, u_rate);
    exception when others then n := n + 1;
    end;
  end loop;
  insert into public.event_attendees (event_id, user_id) values (eid_a, u_rate);
  delete from public.event_attendees where event_id = eid_a and user_id = u_rate;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D5 RSVP to hidden / removed / ended refused (' || n || '/3); active works';
  if not ok then fails := fails + 1; end if;

  -- D6: the 31st RSVP in a day fails — even when every one of them was
  -- un-tapped straight away. u_rate has 1 so far (D5), so 29 more succeed.
  succ := 0;
  err := null;
  for i in 1..40 loop
    begin
      insert into public.event_attendees (event_id, user_id) values (eid_a, u_rate);
      delete from public.event_attendees where event_id = eid_a and user_id = u_rate;
      succ := succ + 1;
    exception when others then
      err := sqlerrm;
      exit;
    end;
  end loop;
  ok := succ = 29 and err = 'rsvp_rate_limited';
  begin
    insert into public.event_attendees (event_id, user_id) values (eid, u_rate);
    ok := false;
  exception when others then
    ok := ok and sqlerrm = 'rsvp_rate_limited';
  end;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D6 31st RSVP in 24h -> rsvp_rate_limited, tapping off does not reset it (' || succ || ' ok)';
  if not ok then fails := fails + 1; end if;

  -- D7: admins are exempt (35 taps on someone else's event).
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  succ := 0;
  for i in 1..35 loop
    begin
      insert into public.event_attendees (event_id, user_id) values (eid, u_admin);
      delete from public.event_attendees where event_id = eid and user_id = u_admin;
      succ := succ + 1;
    exception when others then exit;
    end;
  end loop;
  ok := succ = 35;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D7 admin is exempt from the RSVP limit (' || succ || '/35)';
  if not ok then fails := fails + 1; end if;

  -- D8: nobody can set going_count directly, not even the host.
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  update public.events set going_count = 999 where id = eid;
  select s.going_count into n from public.event_summaries s where s.id = eid;
  ok := n = 4;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D8 direct update of going_count does nothing (still ' || n || ')';
  if not ok then fails := fails + 1; end if;

  -- D9: the host can't un-RSVP; an attendee can leave even after the event
  -- is hidden.
  delete from public.event_attendees where event_id = eid and user_id = u_trusted;
  get diagnostics n = row_count;
  ok := n = 0;
  reset role;
  update public.events set status = 'hidden' where id = eid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  delete from public.event_attendees where event_id = eid and user_id = u_acq;
  get diagnostics n = row_count;
  ok := ok and n = 1;
  reset role;
  update public.events set status = 'active' where id = eid;
  select going_count into n from public.events where id = eid;
  ok := ok and n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D9 host cannot un-RSVP; attendee can leave a hidden event (count now ' || n || ')';
  if not ok then fails := fails + 1; end if;

  -- D10: RSVPs don't bump the event's updated_at (that means "host edited").
  update public.events set updated_at = '2020-01-01' where id = eid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', f3, 'role', 'authenticated')::text, true);
  insert into public.event_attendees (event_id, user_id) values (eid, f3);
  reset role;
  select * into e from public.events where id = eid;
  ok := e.updated_at = '2020-01-01' and e.going_count = 4;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D10 RSVP changes going_count but not updated_at';
  if not ok then fails := fails + 1; end if;

  -- D11: deleting an event with attendees works, hosts' automatic RSVPs are
  -- never logged, and going_count matches the real rows for every event.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', f3, 'role', 'authenticated')::text, true);
  insert into public.event_attendees (event_id, user_id) values (eid_a, f3);
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  delete from public.events where id = eid_a;
  get diagnostics n = row_count;
  ok := n = 1;
  reset role;
  select count(*) into n
  from public.event_rsvp_log l join public.events ev on ev.id = l.event_id
  where ev.creator_id = l.user_id;
  ok := ok and n = 0;
  select count(*) into n
  from public.events ev
  where ev.going_count <> (select count(*) from public.event_attendees a where a.event_id = ev.id);
  ok := ok and n = 0;
  select count(*) into n from public.events;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D11 event delete ok; host RSVPs not logged; going_count right for all ' || n || ' events';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- E. Reports and admin tools
  -- =====================================================================

  -- eid is u_trusted's public event (active, 4 going). Account ages:
  -- f1/f2/f3 30 days, u_acq 8 days (all count toward auto-hide); u_new and
  -- u_rate 1 day (don't count).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  eid_c2 := (public.create_event('Friends only', null, null, 43.6, -116.2, t0, null, 'connections') ->> 'event_id')::uuid;

  -- E1: can't report your own event, one you can't see, or with a bad reason.
  v := public.report_event(eid, 'spam', null);
  ok := v ->> 'outcome' = 'self';
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  v := public.report_event(eid_c2, 'spam', null);
  ok := ok and v ->> 'outcome' = 'not_found';
  v := public.report_event(gen_random_uuid(), 'spam', null);
  ok := ok and v ->> 'outcome' = 'not_found';
  v := public.report_event(eid, 'boring', null);
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'reason';
  v := public.report_event(eid, 'other', repeat('x', 501));
  ok := ok and v ->> 'outcome' = 'invalid' and v ->> 'field' = 'details';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E1 report own -> self; invisible/missing -> not_found; bad reason/details -> invalid';
  if not ok then fails := fails + 1; end if;

  -- E2: 2 old-enough reports + 1 from a 1-day-old account -> still active;
  -- reporting twice -> already_reported; users can't read reports.
  perform set_config('request.jwt.claims', json_build_object('sub', f1, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'spam', '  Selling a course  ');
  ok := v ->> 'outcome' = 'reported' and not (v ->> 'hidden')::boolean;
  v := public.report_event(eid, 'fake', null);
  ok := ok and v ->> 'outcome' = 'already_reported';
  perform set_config('request.jwt.claims', json_build_object('sub', u_new, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'fake', null);
  ok := ok and v ->> 'outcome' = 'reported' and not (v ->> 'hidden')::boolean;
  perform set_config('request.jwt.claims', json_build_object('sub', f2, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'spam', null);
  ok := ok and v ->> 'outcome' = 'reported' and not (v ->> 'hidden')::boolean;
  select count(*) into n from public.event_reports;
  ok := ok and n = 0;
  reset role;
  select * into e from public.events where id = eid;
  ok := ok and e.status = 'active';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E2 3 reports incl. a 1-day-old account -> still active; twice -> already_reported; reports unreadable';
  if not ok then fails := fails + 1; end if;

  -- E3: a third old-enough report hides it.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', f3, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'unsafe_location', 'The address is a house');
  reset role;
  select * into e from public.events where id = eid;
  ok := v ->> 'outcome' = 'reported' and (v ->> 'hidden')::boolean and e.status = 'hidden';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E3 3rd report from an account 3+ days old -> hidden';
  if not ok then fails := fails + 1; end if;

  -- E4: hidden -> gone for others (can't report it either), still there
  -- for the host with status hidden.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eid;
  ok := n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'spam', null);
  ok := ok and v ->> 'outcome' = 'not_found';
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eid and status = 'hidden';
  ok := ok and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E4 hidden event: invisible to others, visible to host as hidden';
  if not ok then fails := fails + 1; end if;

  -- E5: non-admins get 42501 from every admin RPC.
  n := 0;
  begin perform public.admin_list_flagged_events(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.admin_set_event_status(eid, 'active', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.admin_set_host_status(u_trusted, 'approved', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.admin_find_user('es_'); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  ok := n = 4;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E5 non-admin refused by all 4 admin RPCs (' || n || '/4)';
  if not ok then fails := fails + 1; end if;

  -- E6: the flagged list shows the event with its exact spot and report breakdown.
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select * into rec from public.admin_list_flagged_events() f where f.event_id = eid;
  ok := rec.event_id is not null and rec.status = 'hidden' and rec.open_reports = 4 and rec.counted_reports = 3
    and rec.reports_by_reason = '{"spam": 2, "fake": 1, "unsafe_location": 1}'::jsonb
    and rec.latitude = 43.615 and rec.location_name = 'Boise Library'
    and jsonb_array_length(rec.recent_reports) = 4
    -- (every test report has the same created_at, so check membership, not order)
    and rec.recent_reports @> '[{"details": "The address is a house", "counts": true}]'::jsonb
    and not exists (select 1 from public.admin_list_flagged_events() f where f.event_id = eid_c2);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E6 admin flagged list: hidden event, 4 open / 3 counted, by reason, exact spot'
    || case when ok then '' else ' (' || coalesce(rec::text, 'no row') || ')' end;
  if not ok then fails := fails + 1; end if;

  -- E7: restore -> active, reports dismissed, off the list, logged.
  v := public.admin_set_event_status(eid, 'active', 'Checked it, looks fine');
  ok := v ->> 'outcome' = 'updated'
    and not exists (select 1 from public.admin_list_flagged_events() f where f.event_id = eid);
  reset role;
  select * into e from public.events where id = eid;
  select count(*) into n from public.event_reports where event_id = eid and status = 'dismissed';
  ok := ok and e.status = 'active' and n = 4
    and exists (
      select 1 from public.moderation_log
      where event_id = eid and admin_id = u_admin and action = 'event_active' and note = 'Checked it, looks fine'
    );
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E7 restore: active, 4 reports dismissed, off the list, logged';
  if not ok then fails := fails + 1; end if;

  -- E8: after a restore, one new report doesn't re-hide it (the count starts over).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_acq, 'role', 'authenticated')::text, true);
  v := public.report_event(eid, 'spam', null);
  ok := v ->> 'outcome' = 'reported' and not (v ->> 'hidden')::boolean;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E8 after restore, 1 new report does not re-hide';
  if not ok then fails := fails + 1; end if;

  -- E9: remove -> removed; the host still sees it but can't delete or edit it;
  -- others can't see it; open reports actioned.
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_event_status(eid, 'removed', null);
  ok := v ->> 'outcome' = 'updated';
  v := public.admin_set_event_status(eid, 'hidden', null);
  ok := ok and v ->> 'outcome' = 'invalid';
  perform set_config('request.jwt.claims', json_build_object('sub', f1, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eid;
  ok := ok and n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', u_trusted, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eid and status = 'removed';
  ok := ok and n = 1;
  delete from public.events where id = eid;
  get diagnostics n = row_count;
  ok := ok and n = 0;
  v := public.update_event(eid, 'Please', null, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'event_removed';
  reset role;
  select count(*) into n from public.event_reports where event_id = eid and status = 'actioned';
  ok := ok and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E9 remove: hidden from others, host sees it but cannot delete/edit, report actioned';
  if not ok then fails := fails + 1; end if;

  -- E10: suspending a host removes their upcoming events and blocks hosting.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_host_status(u_appr, 'suspended', 'Spam events');
  ok := v ->> 'outcome' = 'updated' and (v ->> 'events_removed')::int = 3;
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.create_event('Back again', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'not_allowed' and v ->> 'reason' = 'suspended';
  v := public.get_my_hosting_status();
  ok := ok and not (v ->> 'can_host')::boolean and v ->> 'reason' = 'suspended';
  reset role;
  select count(*) into n from public.events where creator_id = u_appr and status <> 'removed';
  ok := ok and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E10 suspend: 3 upcoming events removed, host gets not_allowed';
  if not ok then fails := fails + 1; end if;

  -- E11: clearing the row drops them back to the automatic rule (1 day old ->
  -- connections-only); approving unlocks public.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_host_status(u_appr, null, null);
  ok := v ->> 'outcome' = 'updated';
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.create_event('Back again', null, null, 43.6, -116.2, t0, null, 'public');
  ok := ok and v ->> 'outcome' = 'public_locked';
  v := public.create_event('Back again', null, null, 43.6, -116.2, t0, null, 'connections');
  ok := ok and v ->> 'outcome' = 'created';
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_host_status(u_appr, 'approved', null);
  v2 := public.admin_set_host_status(u_appr, 'banned', null);
  ok := ok and v ->> 'outcome' = 'updated' and v2 ->> 'outcome' = 'invalid';
  perform set_config('request.jwt.claims', json_build_object('sub', u_appr, 'role', 'authenticated')::text, true);
  v := public.create_event('Public again', null, null, 43.6, -116.2, t0, null, 'public');
  ok := ok and v ->> 'outcome' = 'created';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E11 clear -> automatic rule (public locked); approve -> public ok; bad status invalid';
  if not ok then fails := fails + 1; end if;

  -- E12: admin_find_user by a case-insensitive username prefix.
  reset role;
  select upper(left(username, 9)) into err from public.profiles where id = u_appr;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select * into rec from public.admin_find_user(err) f where f.user_id = u_appr;
  ok := rec.user_id is not null and rec.host_status = 'approved'
    and (rec.hosting ->> 'can_host_public')::boolean;
  select count(*) into n from public.admin_find_user('%');
  ok := ok and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E12 admin_find_user: prefix match with hosting status; % is literal';
  if not ok then fails := fails + 1; end if;

  -- E13: the 11th report in a day -> rate_limited.
  for i in 1..11 loop
    perform public.create_event('Report target ' || i, null, null, 43.6, -116.2, t0, null, 'public');
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', u_rate, 'role', 'authenticated')::text, true);
  succ := 0;
  n := 0;
  for x in select s.id from public.event_summaries s where s.title like 'Report target %' order by s.title loop
    v := public.report_event(x, 'spam', null);
    if v ->> 'outcome' = 'reported' then succ := succ + 1; end if;
    if v ->> 'outcome' = 'rate_limited' then n := n + 1; end if;
  end loop;
  ok := succ = 10 and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E13 11th report in 24h -> rate_limited (' || succ || ' reported, ' || n || ' limited)';
  if not ok then fails := fails + 1; end if;

  -- E14: signed-out callers can't report.
  reset role;
  perform set_config('role', 'anon', true);
  err := null;
  begin perform public.report_event(eid_c2, 'spam', null); exception when others then err := sqlstate; end;
  reset role;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E14 anon refused by report_event';
  if not ok then fails := fails + 1; end if;

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
