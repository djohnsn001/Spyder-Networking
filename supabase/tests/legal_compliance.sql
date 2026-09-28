-- Legal compliance tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run against the live database: everything happens inside one DO
-- block that ALWAYS ends by raising an exception, which rolls back every test
-- user and row it created. The exception message is the test report — look
-- for "TEST RESULTS" and any FAIL lines.
--
--   npx supabase db query --linked -f supabase/tests/legal_compliance.sql
--
-- Sections: A = consent, L = map location defaults, R = retention sweep.
-- (Phases 3–4 add B = blocking, C = reports + admin, D = deletion cascade,
-- E = content filter.)

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
  c_past uuid;
  c_future uuid;
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
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
  values (e_reported, u1, 'spam', 'dismissed');

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

  -- R5: an event over for 29 days, and a reported old one, are both kept.
  ok := exists (select 1 from public.events where id = e_recent)
        and exists (select 1 from public.events where id = e_reported)
        and exists (select 1 from public.event_reports where event_id = e_reported);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  R5 29-day-old and reported events kept';
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

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
