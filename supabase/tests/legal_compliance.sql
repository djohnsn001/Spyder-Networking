-- Legal compliance tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run against the live database: everything happens inside one DO
-- block that ALWAYS ends by raising an exception, which rolls back every test
-- user and row it created. The exception message is the test report — look
-- for "TEST RESULTS" and any FAIL lines.
--
--   npx supabase db query --linked -f supabase/tests/legal_compliance.sql
--
-- Sections: A = consent, L = map location defaults, R = retention sweep,
-- B = blocking, C = reports + admin + suspension, E = content filter,
-- D = deletion cascade (+ avatar listing).

-- Admin logins carry 'aal': 'aal2': since 20260929030000 (security item H4)
-- admin power needs two-step verification.
do $tests$
declare
  u1 uuid := gen_random_uuid();   -- sharing on
  u2 uuid := gen_random_uuid();   -- sharing off
  u3 uuid := gen_random_uuid();   -- event host / misc
  -- Consent
  ua_ok uuid := gen_random_uuid();     -- signed up with current version + 18+
  ua_noage uuid := gen_random_uuid();  -- signed up without the 18+ flag
  ua_stale uuid := gen_random_uuid();  -- signed up with an old terms version
  v_current text := public._current_terms_version();
  -- Blocking
  bA uuid := gen_random_uuid();   -- blocks bB
  bB uuid := gen_random_uuid();   -- gets blocked
  bC uuid := gen_random_uuid();   -- connected to both, unaffected
  eA uuid;                        -- hosted by bA, bB going
  eB uuid;                        -- hosted by bB, bA going
  conv uuid;
  tok text;
  -- Reports, suspension, filter
  rR uuid := gen_random_uuid();   -- reporter, in a chat with rT
  rT uuid := gen_random_uuid();   -- reported, later suspended
  rOut uuid := gen_random_uuid(); -- not in the chat
  rU uuid := gen_random_uuid();   -- reported as underage
  adm uuid := gen_random_uuid();  -- admin
  mT uuid;                        -- message from rT to rR
  mR uuid;                        -- message from rR to rT
  eT uuid;                        -- upcoming event hosted by rT
  rep uuid;
  x uuid;
  -- Deletion
  dX uuid := gen_random_uuid();   -- the account being deleted
  dY uuid := gen_random_uuid();   -- in-person connection, chat partner
  dZ uuid := gen_random_uuid();   -- sent dX a pending request; dX blocked them
  dW uuid := gen_random_uuid();   -- blocked dX
  eX uuid;                        -- hosted by dX, dY going
  eY uuid;                        -- hosted by dY, dX going
  eY2 uuid;                       -- hosted by dY, reported by dX
  tbl text;
  v2 jsonb;
  succ int;
  i int;

  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  v jsonb;
  n int;
  rec record;
  b_stale uuid;
  b_old uuid;
  b_fresh uuid;
  e_old uuid;
  e_recent uuid;
  e_reported uuid;
  e_resolved uuid;
  c_past uuid;
  c_future uuid;
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
  from unnest(array[u1, u2, u3]) as id;

  -- The server requires the current Terms to connect, message, RSVP and host
  -- (M5), so the test users have accepted them.
  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  select id, public._current_terms_version(), now(), now()
  from unnest(array[u1, u2, u3]) as id;

  update public.profiles
  set username = 'lc_' || left(replace(id::text, '-', ''), 12)
  where id in (u1, u2, u3);

  -- =====================================================================
  -- A. Consent
  -- =====================================================================

  -- Sign-ups, the way supabase.auth.signUp({ options: { data } }) lands.
  insert into auth.users (id, email, aud, role, raw_user_meta_data) values
    (ua_ok, ua_ok || '@test.bolas.invalid', 'authenticated', 'authenticated',
      jsonb_build_object('terms_version', v_current, 'age_confirmed', true)),
    (ua_noage, ua_noage || '@test.bolas.invalid', 'authenticated', 'authenticated',
      jsonb_build_object('terms_version', v_current)),
    (ua_stale, ua_stale || '@test.bolas.invalid', 'authenticated', 'authenticated',
      jsonb_build_object('terms_version', '2000-01-01', 'age_confirmed', true));

  -- A1: current version + 18+ -> consent recorded with server time; profile still created.
  select * into rec from public.user_consents where user_id = ua_ok;
  ok := rec.terms_version = v_current and rec.accepted_at = now() and rec.age_confirmed_at = now()
        and exists (select 1 from public.profiles where id = ua_ok);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A1 sign-up with current version + 18+ -> consent recorded (server time)';
  if not ok then fails := fails + 1; end if;

  -- A2: no 18+ flag, or a stale version -> nothing recorded, gate says needs_acceptance.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua_noage, 'role', 'authenticated')::text, true);
  v := public.get_my_consent_status();
  ok := (v ->> 'needs_acceptance')::boolean and v ->> 'current_version' = v_current
        and v -> 'accepted_version' = 'null'::jsonb;
  reset role;
  ok := ok and not exists (select 1 from public.user_consents where user_id in (ua_noage, ua_stale));
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A2 sign-up without 18+ / with stale version -> nothing recorded, needs_acceptance (' || v::text || ')';
  if not ok then fails := fails + 1; end if;

  -- A3: accept_terms outcomes.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua_noage, 'role', 'authenticated')::text, true);
  v := public.accept_terms('2000-01-01', true);
  ok := v ->> 'outcome' = 'stale_version' and v ->> 'current_version' = v_current;
  v := public.accept_terms(v_current, false);
  ok := ok and v ->> 'outcome' = 'age_required';
  v := public.accept_terms(v_current, null);
  ok := ok and v ->> 'outcome' = 'age_required';
  select count(*) into n from public.user_consents where user_id = ua_noage;
  ok := ok and n = 0;
  v := public.accept_terms(v_current, true);
  ok := ok and v ->> 'outcome' = 'accepted';
  v := public.get_my_consent_status();
  ok := ok and not (v ->> 'needs_acceptance')::boolean and v ->> 'accepted_version' = v_current;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A3 accept_terms: stale_version / age_required x2 / accepted, then gate clears';
  if not ok then fails := fails + 1; end if;

  -- A4: users can't write consent rows directly (no insert/update/delete policies).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua_stale, 'role', 'authenticated')::text, true);
  err := null;
  begin
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    values (ua_stale, v_current, now() - interval '1 year', now() - interval '1 year');
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  perform set_config('request.jwt.claims', json_build_object('sub', ua_ok, 'role', 'authenticated')::text, true);
  update public.user_consents set accepted_at = now() - interval '1 year' where user_id = ua_ok;
  get diagnostics n = row_count;
  ok := ok and n = 0;
  delete from public.user_consents where user_id = ua_ok;
  get diagnostics n = row_count;
  ok := ok and n = 0;
  reset role;
  ok := ok and exists (select 1 from public.user_consents where user_id = ua_ok and accepted_at = now());
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A4 direct insert refused (' || coalesce(err, 'no error') || '), update/delete change nothing';
  if not ok then fails := fails + 1; end if;

  -- A5: a normal profile edit still works.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua_ok, 'role', 'authenticated')::text, true);
  update public.profiles set bio = 'Building things' where id = ua_ok;
  get diagnostics n = row_count;
  reset role;
  ok := n = 1 and exists (select 1 from public.profiles where id = ua_ok and bio = 'Building things');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A5 profile bio edit still works';
  if not ok then fails := fails + 1; end if;

  -- A6: you see only your own consent rows.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', ua_ok, 'role', 'authenticated')::text, true);
  select count(*) into n from public.user_consents where user_id in (ua_ok, ua_noage);
  reset role;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A6 consent rows visible only to their owner (' || n || ' seen)';
  if not ok then fails := fails + 1; end if;

  -- A7: signed-out callers are refused.
  perform set_config('role', 'anon', true);
  err := null;
  begin perform public.accept_terms(v_current, true); exception when others then err := sqlstate; end;
  ok := err = '42501';
  err := null;
  begin perform public.get_my_consent_status(); exception when others then err := sqlstate; end;
  ok := ok and err = '42501';
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A7 anon refused by accept_terms and get_my_consent_status';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- L. Map location
  -- =====================================================================

  -- L1: new accounts start hidden.
  select count(*) into n from public.profiles
  where id in (u1, u2, u3) and location_sharing = 'off';
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L1 new accounts default to location_sharing = off';
  if not ok then fails := fails + 1; end if;

  update public.profiles set location_sharing = 'connections' where id = u1;

  perform set_config('role', 'authenticated', true);

  -- L2: sharing off -> update_my_location stores nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  perform public.update_my_location(43.61234, -116.20321);
  reset role;
  select count(*) into n from public.user_locations where user_id = u2;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L2 sharing off: location not saved';
  if not ok then fails := fails + 1; end if;

  -- L3: sharing on -> saved, snapped to the 0.02 x 0.03 grid, within half a
  -- cell of the real spot.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  perform public.update_my_location(43.61234, -116.20321);
  reset role;
  select * into rec from public.user_locations where user_id = u1;
  ok := rec.user_id is not null
        and abs(rec.lat / 0.02 - round(rec.lat / 0.02)) < 1e-6
        and abs(rec.lng / 0.03 - round(rec.lng / 0.03)) < 1e-6
        and abs(rec.lat - 43.61234) <= 0.01 + 1e-9
        and abs(rec.lng - (-116.20321)) <= 0.015 + 1e-9;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L3 sharing on: saved on the coarse grid (' || coalesce(rec.lat::text, 'null') || ', ' || coalesce(rec.lng::text, 'null') || ')';
  if not ok then fails := fails + 1; end if;

  -- L4: turning sharing off (a normal profile update by the user) deletes the row.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  update public.profiles set location_sharing = 'off' where id = u1;
  reset role;
  select count(*) into n from public.user_locations where user_id = u1;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L4 turning sharing off deletes the saved spot';
  if not ok then fails := fails + 1; end if;

  -- L5: a leftover row for a hidden user is removed by their next update call.
  insert into public.user_locations (user_id, lat, lng) values (u2, 43.6, -116.2);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  perform public.update_my_location(43.6, -116.2);
  reset role;
  select count(*) into n from public.user_locations where user_id = u2;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L5 hidden user: leftover spot deleted on next update';
  if not ok then fails := fails + 1; end if;

  -- L6: signed-out callers can't save a location.
  perform set_config('role', 'anon', true);
  err := null;
  begin perform public.update_my_location(43.6, -116.2); exception when others then err := sqlstate; end;
  reset role;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  L6 anon refused by update_my_location (' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- R. Retention sweep
  -- =====================================================================

  -- Taps: one waiting for 2 minutes (app closed mid-tap), one 11 minutes
  -- old, one fresh.
  insert into public.bump_events (user_id, created_at, lat, lng, accuracy_m, status)
  values (u1, now() - interval '2 minutes', 43.6, -116.2, 10, 'waiting')
  returning id into b_stale;
  insert into public.bump_events (user_id, created_at, lat, lng, accuracy_m, status)
  values (u1, now() - interval '11 minutes', null, null, 10, 'no_match')
  returning id into b_old;
  insert into public.bump_events (user_id, created_at, lat, lng, accuracy_m, status)
  values (u1, now(), 43.6, -116.2, 10, 'waiting')
  returning id into b_fresh;

  -- QR codes: 2 hours old and fresh.
  insert into public.connect_tokens (token, user_id, created_at, expires_at) values
    (encode(extensions.gen_random_bytes(16), 'hex'), u1, now() - interval '2 hours', now() - interval '119 minutes'),
    ('lc_fresh_' || u1, u1, now(), now() + interval '1 minute');

  -- Events: ended 31 days ago, ended 29 days ago, ended 31 days ago but reported.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (u3, 'LC old', 43.6, -116.2, now() - interval '31 days 2 hours', now() - interval '31 days', 'public')
  returning id into e_old;
  insert into public.event_locations (event_id, latitude, longitude) values (e_old, 43.6, -116.2);
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (u3, 'LC recent', 43.6, -116.2, now() - interval '29 days 2 hours', now() - interval '29 days', 'public')
  returning id into e_recent;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (u3, 'LC reported', 43.6, -116.2, now() - interval '31 days 2 hours', now() - interval '31 days', 'public')
  returning id into e_reported;
  insert into public.event_reports (event_id, reporter_id, reason, status)
  values (e_reported, u1, 'spam', 'open');
  -- Ended 31 days ago with only a resolved report: deleted, report survives.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (u3, 'LC resolved', 43.6, -116.2, now() - interval '31 days 2 hours', now() - interval '31 days', 'public')
  returning id into e_resolved;
  insert into public.event_reports (event_id, reporter_id, reason, status)
  values (e_resolved, u2, 'spam', 'dismissed');

  -- Creation log: 8 days old and fresh.
  insert into public.event_creation_log (creator_id, created_at) values
    (u3, now() - interval '8 days'), (u3, now());

  -- Connections with an expired and a live undo window.
  v := public._connect_in_person(u1, u2, 'qr', null);
  c_past := (v ->> 'connection_id')::uuid;
  v := public._connect_in_person(u1, u3, 'qr', null);
  c_future := (v ->> 'connection_id')::uuid;
  perform set_config('bolas.trusted_write', 'on', true);
  update public.connections set undo_until = now() - interval '5 minutes' where id = c_past;
  perform set_config('bolas.trusted_write', 'off', true);

  -- Map spots: 8 days stale and 1 day old.
  update public.profiles set location_sharing = 'connections' where id in (u1, u3);
  insert into public.user_locations (user_id, lat, lng, updated_at) values
    (u1, 43.6, -116.2, now() - interval '8 days'),
    (u3, 43.6, -116.2, now() - interval '1 day');

  v := public._retention_sweep();

  -- R1: the stuck tap is no longer waiting and its coordinates are gone.
  select * into rec from public.bump_events where id = b_stale;
  ok := rec.status = 'no_match' and rec.lat is null and rec.lng is null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R1 stuck waiting tap: coordinates erased';
  if not ok then fails := fails + 1; end if;

  -- R2: taps older than 10 minutes are deleted; a fresh waiting tap is untouched.
  ok := not exists (select 1 from public.bump_events where id = b_old)
        and exists (select 1 from public.bump_events where id = b_fresh and status = 'waiting' and lat is not null);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R2 11-minute-old tap deleted, fresh tap untouched';
  if not ok then fails := fails + 1; end if;

  -- R3: QR codes older than an hour are deleted; fresh ones stay.
  select count(*) into n from public.connect_tokens where user_id = u1;
  ok := n = 1 and exists (select 1 from public.connect_tokens where token = 'lc_fresh_' || u1);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R3 old QR code deleted, fresh one kept';
  if not ok then fails := fails + 1; end if;

  -- R4: an event over for 31 days is deleted with its exact spot.
  ok := not exists (select 1 from public.events where id = e_old)
        and not exists (select 1 from public.event_locations where event_id = e_old);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R4 event ended 31 days ago deleted (with exact location)';
  if not ok then fails := fails + 1; end if;

  -- R5: an event over for 29 days, and an old one with an OPEN report, are
  -- kept. An old one whose report was resolved is deleted, and the report
  -- survives (event_id null).
  ok := exists (select 1 from public.events where id = e_recent)
        and exists (select 1 from public.events where id = e_reported)
        and exists (select 1 from public.event_reports where event_id = e_reported)
        and not exists (select 1 from public.events where id = e_resolved)
        and exists (select 1 from public.event_reports where reporter_id = u2 and event_id is null and status = 'dismissed');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R5 29-day-old + open-report events kept; resolved-report event deleted, report kept';
  if not ok then fails := fails + 1; end if;

  -- R6: creation log rows older than 7 days are deleted.
  select count(*) into n from public.event_creation_log where creator_id = u3;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R6 creation log pruned to 7 days (' || n || ' left)';
  if not ok then fails := fails + 1; end if;

  -- R7: expired undo info cleared; a live undo window untouched.
  ok := exists (select 1 from public.connections where id = c_past and undo_until is null and undo_snapshot is null)
        and exists (select 1 from public.connections where id = c_future and undo_until > now());
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R7 expired undo cleared, live undo kept';
  if not ok then fails := fails + 1; end if;

  -- R8: map spots not refreshed for 7 days are deleted.
  ok := not exists (select 1 from public.user_locations where user_id = u1)
        and exists (select 1 from public.user_locations where user_id = u3);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R8 8-day-old map spot deleted, 1-day-old kept';
  if not ok then fails := fails + 1; end if;

  -- R9: clients can't run the sweep.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  err := null;
  begin perform public._retention_sweep(); exception when others then err := sqlstate; end;
  reset role;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R9 authenticated refused by _retention_sweep';
  if not ok then fails := fails + 1; end if;

  -- R10: the job is scheduled every minute.
  ok := exists (
    select 1 from cron.job
    where jobname = 'bolas-retention-sweep' and schedule = '* * * * *' and active
  );
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R10 cron job bolas-retention-sweep scheduled every minute';
  if not ok then fails := fails + 1; end if;

  -- ---------- setup for B / C / E (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
  from unnest(array[bA, bB, bC, rR, rT, rOut, rU, adm]) as id;

  -- The server requires the current Terms to connect, message, RSVP and host
  -- (M5), so the test users have accepted them.
  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  select id, public._current_terms_version(), now(), now()
  from unnest(array[bA, bB, bC, rR, rT, rOut, rU, adm]) as id;

  update public.profiles
  set username = 'lc_' || left(replace(id::text, '-', ''), 12), bio = 'Original bio'
  where id in (bA, bB, bC, rR, rT, rOut, rU, adm);

  insert into public.app_admins (user_id) values (adm);

  -- =====================================================================
  -- B. Blocking
  -- =====================================================================

  perform public._connect_in_person(bA, bB, 'qr', null);
  insert into public.connections (requester_id, addressee_id, status) values
    (bC, bA, 'accepted'), (bC, bB, 'accepted');

  -- Each hosts an upcoming public event; the other is going.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (bA, 'LC bA event', 43.6, -116.2, now() + interval '1 day', 'public')
  returning id into eA;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (bB, 'LC bB event', 43.6, -116.2, now() + interval '1 day', 'public')
  returning id into eB;
  insert into public.event_attendees (event_id, user_id) values (eA, bB), (eB, bA);

  -- A chat between them.
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  conv := public.get_or_create_direct_conversation(bB);
  insert into public.messages (conversation_id, sender_id, body) values (conv, bB, 'hey');

  -- bA blocks bB.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  v := public.block_user(bB);
  reset role;
  ok := v ->> 'outcome' = 'blocked';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B1 block_user -> blocked';
  if not ok then fails := fails + 1; end if;

  -- B2: their connection is gone; RSVPs both ways removed and counts updated.
  ok := not exists (
          select 1 from public.connections
          where (requester_id = bA and addressee_id = bB) or (requester_id = bB and addressee_id = bA))
        and not exists (select 1 from public.event_attendees where event_id = eA and user_id = bB)
        and not exists (select 1 from public.event_attendees where event_id = eB and user_id = bA)
        and (select going_count from public.events where id = eA) = 1
        and (select going_count from public.events where id = eB) = 1
        and exists (select 1 from public.connections where requester_id = bC and addressee_id = bA);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B2 connection deleted, RSVPs removed both ways, other connections kept';
  if not ok then fails := fails + 1; end if;

  -- B3: neither can see the other's profile; a third person sees both.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id = bA;
  ok := n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id = bB;
  ok := ok and n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', bC, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id in (bA, bB);
  ok := ok and n = 2;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B3 profiles hidden both ways, visible to others';
  if not ok then fails := fails + 1; end if;

  -- B4: connection requests refused both ways.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  err := null;
  begin insert into public.connections (requester_id, addressee_id) values (bB, bA);
  exception when others then err := sqlstate; end;
  ok := err = '42501';
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  err := null;
  begin insert into public.connections (requester_id, addressee_id) values (bA, bB);
  exception when others then err := sqlstate; end;
  ok := ok and err = '42501';
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B4 connection requests refused both ways';
  if not ok then fails := fails + 1; end if;

  -- B5: the chat is hidden from both, and nobody can send into it or start a new one.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.conversations where id = conv;
  ok := n = 0;
  select count(*) into n from public.messages where conversation_id = conv;
  ok := ok and n = 0;
  err := null;
  begin insert into public.messages (conversation_id, sender_id, body) values (conv, bB, 'still there?');
  exception when others then err := sqlstate; end;
  ok := ok and err = '42501';
  err := null;
  begin perform public.get_or_create_direct_conversation(bA); exception when others then err := sqlerrm; end;
  ok := ok and err = 'not connected';
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  select count(*) into n from public.messages where conversation_id = conv;
  ok := ok and n = 0;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B5 chat hidden both ways; send and new chat refused';
  if not ok then fails := fails + 1; end if;

  -- B6: in person: direct, QR (code stays unused, no profile leaked), and tap.
  v := public._connect_in_person(bB, bA, 'qr', null);
  ok := v ->> 'outcome' = 'unavailable';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  -- Both phones send a location since 20260929020000 (item H2), so the
  -- block is what stops this, not a missing location.
  tok := public.create_connect_token(43.615, -116.202, 20) ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, null, 43.6151, -116.2021, 20);
  ok := ok and v = jsonb_build_object('outcome', 'unavailable');
  -- Taps far from any other test data.
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  v2 := public.submit_bump(10.0, 10.0, 10, null);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.0, 10.0, 10, null);
  reset role;
  ok := ok and v2 ->> 'status' = 'waiting' and v ->> 'status' = 'waiting'
        and exists (select 1 from public.connect_tokens where token = tok and used_at is null);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B6 in-person connect / QR / tap -> unavailable, nothing revealed (' || v::text || ')';
  if not ok then fails := fails + 1; end if;

  -- B7: events hidden both ways, and the blocked person can't RSVP again.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eA;
  ok := n = 0;
  err := null;
  begin insert into public.event_attendees (event_id, user_id) values (eA, bB);
  exception when others then err := sqlstate; end;
  ok := ok and err = '42501';
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id = eB;
  ok := ok and n = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', bC, 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_summaries where id in (eA, eB);
  ok := ok and n = 2;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B7 events hidden both ways, RSVP refused, others still see both';
  if not ok then fails := fails + 1; end if;

  -- B8: only the blocker sees the block.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_my_blocked_users() b where b.user_id = bB;
  ok := n = 1;
  select count(*) into n from public.user_blocks;
  ok := ok and n = 1;
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_my_blocked_users();
  ok := ok and n = 0;
  select count(*) into n from public.user_blocks;
  ok := ok and n = 0;
  -- ...and nobody can write blocks directly.
  err := null;
  begin insert into public.user_blocks (blocker_id, blocked_id) values (bB, bC);
  exception when others then err := sqlstate; end;
  ok := ok and err = '42501';
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B8 blocker sees the block, blocked person sees nothing, no direct writes';
  if not ok then fails := fails + 1; end if;

  -- B9: mutuals and connection counts don't leak across a block.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.get_mutuals(bA);
  ok := n = 0 and public.get_connection_count(bA) = 0;
  -- A third person still gets bA's real count (bC only; bB's connection is gone).
  perform set_config('request.jwt.claims', json_build_object('sub', bC, 'role', 'authenticated')::text, true);
  ok := ok and public.get_connection_count(bA) = 1;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B9 mutuals/count hidden from the blocked person, normal for others';
  if not ok then fails := fails + 1; end if;

  -- B10: unblock restores visibility, not the connection.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', bA, 'role', 'authenticated')::text, true);
  v := public.unblock_user(bB);
  perform set_config('request.jwt.claims', json_build_object('sub', bB, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id = bA;
  reset role;
  ok := v ->> 'outcome' = 'unblocked' and n = 1
        and not exists (
          select 1 from public.connections
          where (requester_id = bA and addressee_id = bB) or (requester_id = bB and addressee_id = bA));
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B10 unblock: visible again, connection not restored';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- C. Reports, admin, suspension
  -- =====================================================================

  insert into public.connections (requester_id, addressee_id, status) values (rR, rT, 'accepted');
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  conv := public.get_or_create_direct_conversation(rT);
  insert into public.messages (conversation_id, sender_id, body) values (conv, rT, 'send me $500')
  returning id into mT;
  insert into public.messages (conversation_id, sender_id, body) values (conv, rR, 'no thanks')
  returning id into mR;

  perform set_config('role', 'authenticated', true);

  -- C1: can't report yourself.
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  v := public.report_user(rR, 'profile', null, 'spam', null);
  ok := v ->> 'outcome' = 'self';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C1 report yourself -> self';
  if not ok then fails := fails + 1; end if;

  -- C2: can't report a message you're not part of, or pin someone else's message on them.
  perform set_config('request.jwt.claims', json_build_object('sub', rOut, 'role', 'authenticated')::text, true);
  v := public.report_user(rT, 'message', mT, 'scam_or_selling', null);
  ok := v ->> 'outcome' = 'not_found';
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  v := public.report_user(rT, 'message', mR, 'scam_or_selling', null);
  ok := ok and v ->> 'outcome' = 'not_found';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C2 message report by outsider / wrong sender -> not_found';
  if not ok then fails := fails + 1; end if;

  -- C3: a real message report stores a server-made snapshot, which doesn't
  -- change when the reported person edits their profile afterwards.
  v := public.report_user(rT, 'message', mT, 'scam_or_selling', 'asked for money');
  reset role;
  update public.profiles set bio = 'Edited after the report' where id = rT;
  select * into rec from public.user_reports where reporter_id = rR and context = 'message';
  ok := v ->> 'outcome' = 'reported'
        and rec.snapshot -> 'message' ->> 'body' = 'send me $500'
        and rec.snapshot ->> 'bio' = 'Original bio'
        and rec.snapshot ->> 'username' = (select username from public.profiles where id = rT)
        and rec.context_id = mT and rec.status = 'open';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C3 message report: server snapshot kept as it was at report time';
  if not ok then fails := fails + 1; end if;

  -- C4: the 11th report in a day -> rate_limited (1 already filed above).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  succ := 0;
  n := 0;
  for i in 1..10 loop
    v := public.report_user(rT, 'profile', null, 'spam', null);
    if v ->> 'outcome' = 'reported' then succ := succ + 1; end if;
    if v ->> 'outcome' = 'rate_limited' then n := n + 1; end if;
  end loop;
  reset role;
  ok := succ = 9 and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C4 11th report in 24h -> rate_limited (' || succ || ' more reported, ' || n || ' limited)';
  if not ok then fails := fails + 1; end if;

  -- C5: underage report; reports table unreadable directly.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rOut, 'role', 'authenticated')::text, true);
  v := public.report_user(rU, 'profile', null, 'underage', 'says they are 16');
  select count(*) into n from public.user_reports;
  reset role;
  ok := v ->> 'outcome' = 'reported' and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C5 underage report filed; user_reports unreadable by users';
  if not ok then fails := fails + 1; end if;

  -- C6: non-admins are refused by every admin RPC.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  n := 0;
  begin perform public.admin_list_user_reports(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.admin_resolve_user_report(gen_random_uuid(), 'dismissed', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.admin_set_account_status(rT, 'suspended', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C6 non-admin refused by all admin RPCs (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- C7: the admin list groups by person, underage first.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  select * into rec from public.admin_list_user_reports() l
  where l.reported_user_id in (rU, rT)
  order by l.has_underage desc, l.latest_report_at desc
  limit 1;
  ok := rec.reported_user_id = rU and rec.has_underage;
  select l.report_count into n from public.admin_list_user_reports() l where l.reported_user_id = rT;
  ok := ok and n = 10;
  -- The whole list's first row with our users is the underage one.
  select l.reported_user_id into x from public.admin_list_user_reports() l
  where l.reported_user_id in (rU, rT) limit 1;
  ok := ok and x = rU;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C7 admin list: grouped (rT has 10), underage first';
  if not ok then fails := fails + 1; end if;

  -- C8: resolving a report updates it and logs it.
  select id into rep from public.user_reports where reported_user_id = rU;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_resolve_user_report(rep, 'dismissed', 'looked fine');
  reset role;
  ok := v ->> 'outcome' = 'updated'
        and (select status from public.user_reports where id = rep) = 'dismissed'
        and exists (select 1 from public.moderation_log where user_id = rU and action = 'user_report_dismissed');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C8 admin_resolve_user_report -> dismissed + logged';
  if not ok then fails := fails + 1; end if;

  -- C9: suspending hides them, removes their upcoming event, actions their reports.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (rT, 'LC rT event', 43.6, -116.2, now() + interval '1 day', 'public')
  returning id into eT;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_account_status(rT, 'suspended', 'scam messages');
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id = rT;
  reset role;
  ok := v ->> 'outcome' = 'updated' and (v ->> 'events_removed')::int = 1 and n = 0
        and (select status from public.events where id = eT) = 'removed'
        and not exists (select 1 from public.user_reports where reported_user_id = rT and status = 'open');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C9 suspend: hidden, upcoming event removed, reports actioned';
  if not ok then fails := fails + 1; end if;

  -- C10: a suspended user can't write anything, but can read their own
  -- restriction and their own profile.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rT, 'role', 'authenticated')::text, true);
  n := 0;
  begin insert into public.connections (requester_id, addressee_id) values (rT, rOut);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.messages (conversation_id, sender_id, body) values (conv, rT, 'hello?');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.event_attendees (event_id, user_id) values (eA, rT);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  -- (Reporting while suspended is allowed since M5; see security.sql S.)
  if public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections') ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
  if (select count(*) from public.account_restrictions where user_id = rT) = 1 then n := n + 1; end if;
  if (select count(*) from public.profiles where id = rT) = 1 then n := n + 1; end if;
  reset role;
  ok := n = 6;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C10 suspended: request/message/RSVP/event refused; can read own restriction + profile (' || n || '/6)';
  if not ok then fails := fails + 1; end if;

  -- C11: lifting the suspension makes them visible again.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', adm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  v := public.admin_set_account_status(rT, null, null);
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  select count(*) into n from public.profiles where id = rT;
  reset role;
  ok := v ->> 'outcome' = 'updated' and n = 1
        and exists (select 1 from public.moderation_log where user_id = rT and action = 'account_restored');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C11 lift suspension: visible again, logged';
  if not ok then fails := fails + 1; end if;

  -- C12: signed-out callers are refused.
  perform set_config('role', 'anon', true);
  n := 0;
  begin perform public.report_user(rT, 'profile', null, 'spam', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.block_user(rT); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  ok := n = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C12 anon refused by report_user and block_user';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- E. Content filter
  -- =====================================================================

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rOut, 'role', 'authenticated')::text, true);

  -- E1: usernames, including glued / padded evasions.
  n := 0;
  begin update public.profiles set username = 'fo_rex99' where id = rOut;
  exception when others then if sqlstate = 'P0001' and sqlerrm = 'blocked_content' then n := n + 1; end if; end;
  begin update public.profiles set username = 'ForexKing' where id = rOut;
  exception when others then if sqlstate = 'P0001' and sqlerrm = 'blocked_content' then n := n + 1; end if; end;
  begin update public.profiles set username = 'cash_app_4u' where id = rOut;
  exception when others then if sqlstate = 'P0001' and sqlerrm = 'blocked_content' then n := n + 1; end if; end;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E1 usernames fo_rex99 / ForexKing / cash_app_4u rejected (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- E2: full name and bio (whole words).
  n := 0;
  begin update public.profiles set full_name = 'Forex Trader' where id = rOut;
  exception when others then if sqlstate = 'P0001' then n := n + 1; end if; end;
  begin update public.profiles set bio = 'DM me for passive income' where id = rOut;
  exception when others then if sqlstate = 'P0001' then n := n + 1; end if; end;
  ok := n = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E2 full name / bio with a blocked phrase rejected (' || n || '/2)';
  if not ok then fails := fails + 1; end if;

  -- E3: normal text passes (including 'dm meetup', which isn't 'dm me').
  update public.profiles
  set username = 'coffee_builder_1', full_name = 'Sam Rivera', bio = 'Building a coffee app. Join our dm meetup!'
  where id = rOut;
  get diagnostics n = row_count;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E3 normal username / name / bio accepted';
  if not ok then fails := fails + 1; end if;

  -- E4: events use the same shared list.
  v := public.create_event('Forex night', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections');
  ok := v ->> 'outcome' = 'blocked_content';
  -- E5: the list itself isn't readable by users.
  select count(*) into n from public.blocked_terms;
  ok := ok and n = 0;
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E4/E5 events filtered by the shared list; list unreadable by users';
  if not ok then fails := fails + 1; end if;

  -- E6: a term added later doesn't stop someone editing other fields.
  update public.profiles set bio = 'I love zzlctestterm' where id = rR;
  insert into public.blocked_terms (term) values ('zzlctestterm');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', rR, 'role', 'authenticated')::text, true);
  err := null;
  begin update public.profiles set city = 'Boise, ID', bio = 'I love zzlctestterm' where id = rR;
  exception when others then err := sqlstate; end;
  reset role;
  ok := err is null and (select city from public.profiles where id = rR) = 'Boise, ID';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  E6 unchanged old bio with a new term doesn''t block other edits';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- D. Deletion cascade
  -- =====================================================================

  insert into auth.users (id, email, aud, role, created_at, raw_user_meta_data)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days',
         jsonb_build_object('terms_version', v_current, 'age_confirmed', true)
  from unnest(array[dX, dY, dZ, dW]) as id;
  update public.profiles
  set username = 'lc_' || left(replace(id::text, '-', ''), 12), location_sharing = 'connections'
  where id in (dX, dY, dZ, dW);

  -- Connections: in person with dY, acquaintance dY-dZ (for dY's count),
  -- a pending request from dZ.
  perform public._connect_in_person(dX, dY, 'bump', 'Boise');
  insert into public.connections (requester_id, addressee_id, status) values
    (dY, dZ, 'accepted'), (dZ, dX, 'pending');
  -- Blocks both ways.
  insert into public.user_blocks (blocker_id, blocked_id) values (dX, dZ), (dW, dX);
  -- Events and RSVPs both ways; dX reports one of dY's events.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (dX, 'LC dX event', 43.6, -116.2, now() + interval '1 day', 'public') returning id into eX;
  insert into public.event_locations (event_id, latitude, longitude) values (eX, 43.6, -116.2);
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (dY, 'LC dY event', 43.6, -116.2, now() + interval '1 day', 'public') returning id into eY;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (dY, 'LC dY event 2', 43.6, -116.2, now() + interval '1 day', 'public') returning id into eY2;
  insert into public.event_attendees (event_id, user_id) values (eX, dY), (eY, dX);
  insert into public.event_creation_log (creator_id, event_id) values (dX, eX);
  insert into public.event_reports (event_id, reporter_id, reason) values (eY2, dX, 'spam');
  -- A chat.
  perform set_config('request.jwt.claims', json_build_object('sub', dX, 'role', 'authenticated')::text, true);
  conv := public.get_or_create_direct_conversation(dY);
  insert into public.messages (conversation_id, sender_id, body) values (conv, dX, 'hi'), (conv, dY, 'hey');
  -- Reports filed and received.
  insert into public.user_reports (reporter_id, reported_user_id, context, reason) values
    (dX, dY, 'profile', 'spam'), (dZ, dX, 'profile', 'harassment');
  -- Location, tap, QR code, hosting, suspension, admin, moderation log.
  insert into public.user_locations (user_id, lat, lng) values (dX, 43.6, -116.2);
  insert into public.bump_events (user_id, lat, lng, accuracy_m) values (dX, 43.6, -116.2, 10);
  insert into public.connect_tokens (token, user_id, expires_at) values ('lc_d_' || dX, dX, now() + interval '1 minute');
  insert into public.host_permissions (user_id, status, updated_by) values (dX, 'approved', dY);
  insert into public.account_restrictions (user_id, status, created_by) values (dW, 'suspended', dX);
  insert into public.app_admins (user_id) values (dX);
  insert into public.moderation_log (admin_id, action, user_id) values (dX, 'test', dY);

  delete from auth.users where id = dX;

  -- D1: nothing anywhere still points at dX.
  n := 0;
  for tbl in
    select format('select count(*) from %I.%I where %I = %L', c.table_schema, c.table_name, c.column_name, dX)
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.data_type = 'uuid'
      and c.table_name in (select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE')
  loop
    execute tbl into i;
    n := n + i;
  end loop;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D1 no uuid column in any public table still holds dX (' || n || ' found)';
  if not ok then fails := fails + 1; end if;

  -- D2: specific cascades.
  ok := not exists (select 1 from public.profiles where id = dX)
        and not exists (select 1 from public.user_consents where user_id = dX)
        and not exists (select 1 from public.events where id = eX)
        and not exists (select 1 from public.event_locations where event_id = eX)
        and not exists (select 1 from public.conversations where id = conv)
        and not exists (select 1 from public.messages where conversation_id = conv)
        and not exists (select 1 from public.connect_tokens where token = 'lc_d_' || dX);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D2 profile, consent, hosted event + exact spot, chat (both sides), QR code gone';
  if not ok then fails := fails + 1; end if;

  -- D3: reports kept, anonymized.
  ok := exists (select 1 from public.user_reports where reporter_id is null and reported_user_id = dY)
        and exists (select 1 from public.user_reports where reporter_id = dZ and reported_user_id is null)
        and exists (select 1 from public.event_reports where event_id = eY2 and reporter_id is null)
        and exists (select 1 from public.moderation_log where admin_id is null and user_id = dY)
        and not exists (select 1 from public.host_permissions where user_id = dX)
        and exists (select 1 from public.account_restrictions where user_id = dW and created_by is null);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D3 user/event reports and moderation log kept with dX set to null';
  if not ok then fails := fails + 1; end if;

  -- D4: the other people are fine: dY's count and dY's event going_count.
  perform set_config('request.jwt.claims', json_build_object('sub', dY, 'role', 'authenticated')::text, true);
  ok := public.get_connection_count(dY) = 1
        and (select going_count from public.events where id = eY) = 1
        and exists (select 1 from public.profiles where id = dY);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D4 other users intact: dY count 1, dY event going_count back to 1';
  if not ok then fails := fails + 1; end if;

  -- D5: an event report now survives its event being deleted, with a snapshot.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', dZ, 'role', 'authenticated')::text, true);
  v := public.report_event(eY, 'spam', null);
  reset role;
  delete from public.events where id = eY;
  select * into rec from public.event_reports where reporter_id = dZ and reason = 'spam' and snapshot ->> 'title' = 'LC dY event';
  ok := v ->> 'outcome' = 'reported' and rec.id is not null and rec.event_id is null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D5 event report kept (event_id null) with a title snapshot after the event is deleted';
  if not ok then fails := fails + 1; end if;

  -- D6: avatars: you can list only your own folder; signed-out, nothing.
  err := null;
  begin
    insert into storage.objects (bucket_id, name) values
      ('avatars', dY || '/lc-test.jpg'), ('avatars', dZ || '/lc-test.jpg');
  exception when others then err := sqlstate || ' ' || sqlerrm;
  end;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', dY, 'role', 'authenticated')::text, true);
  select count(*) into n from storage.objects where bucket_id = 'avatars';
  ok := err is null and n = 1;
  reset role;
  perform set_config('role', 'anon', true);
  select count(*) into n from storage.objects where bucket_id = 'avatars';
  reset role;
  ok := ok and n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D6 avatars bucket: users list only their own folder, anon lists nothing' || coalesce(' (setup failed: ' || err || ')', '');
  if not ok then fails := fails + 1; end if;

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
