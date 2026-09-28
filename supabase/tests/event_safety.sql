-- Safer map events tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run against the live database: everything happens inside one DO
-- block that ALWAYS ends by raising an exception, which rolls back every test
-- user and row it created. The exception message is the test report — look
-- for "TEST RESULTS" and any FAIL lines.
--
--   npx supabase db query --linked -f supabase/tests/event_safety.sql
--
-- Sections: A = hosting trust, B = write lock + validation, C = location.

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
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
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

  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
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
  select n + count(*) into n from public.event_blocked_terms;
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
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
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
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
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
  perform set_config('request.jwt.claims', json_build_object('sub', u_admin, 'role', 'authenticated')::text, true);
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

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
