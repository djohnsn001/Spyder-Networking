-- In-person connection tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run against the live database: everything happens inside one DO
-- block that ALWAYS ends by raising an exception, which rolls back every test
-- user and row it created. The exception message is the test report — look
-- for "TEST RESULTS" and any FAIL lines.
--
--   npx supabase db query --linked -f supabase/tests/in_person_connections.sql
--
-- Sections: A = guard trigger, B = _connect_in_person + undo, C = QR tokens,
-- D = bumps.

do $tests$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  u3 uuid := gen_random_uuid();
  u4 uuid := gen_random_uuid();
  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  v jsonb;
  c public.connections%rowtype;
  cid uuid;
  n int;
  tok text;
  tok2 text;
  b1 uuid;
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role)
  values
    (u1, u1 || '@test.bolas.invalid', 'authenticated', 'authenticated'),
    (u2, u2 || '@test.bolas.invalid', 'authenticated', 'authenticated'),
    (u3, u3 || '@test.bolas.invalid', 'authenticated', 'authenticated'),
    (u4, u4 || '@test.bolas.invalid', 'authenticated', 'authenticated');

  -- =====================================================================
  -- A. Guard trigger
  -- =====================================================================

  -- A1: a client insert asking for in_person is forced down to acquaintance.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  insert into public.connections (requester_id, addressee_id, level, method, met_at, met_city)
  values (u1, u2, 'in_person', 'qr', now(), 'Boise')
  returning * into c;
  ok := c.level = 'acquaintance' and c.method = 'request' and c.met_at is null
        and c.met_city is null and c.status = 'pending';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A1 client insert of in_person is forced to acquaintance/request';
  if not ok then fails := fails + 1; end if;

  -- A2: the addressee can still accept a request.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  update public.connections set status = 'accepted' where id = c.id;
  select * into c from public.connections where id = c.id;
  ok := c.status = 'accepted' and c.level = 'acquaintance';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A2 addressee can accept a request (stays acquaintance)';
  if not ok then fails := fails + 1; end if;

  -- A3: the addressee can't upgrade the level directly.
  err := null;
  begin
    update public.connections set level = 'in_person', met_at = now() where id = c.id;
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A3 direct update of level is rejected (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- A4: nor any of the other protected columns.
  err := null;
  begin
    update public.connections set met_city = 'Boise' where id = c.id;
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A4 direct update of met_city is rejected (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  err := null;
  begin
    update public.connections set undo_until = now() + interval '1 hour' where id = c.id;
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A5 direct update of undo_until is rejected (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- A6: clients can't call the internal functions.
  err := null;
  begin
    perform public._connect_in_person(u2, u1, 'qr', 'Boise');
  exception when others then err := sqlstate;
  end;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A6 client cannot call _connect_in_person (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- A7: removing an accepted connection still works.
  delete from public.connections where id = c.id;
  get diagnostics n = row_count;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A7 either side can remove a connection';
  if not ok then fails := fails + 1; end if;

  -- A8: cancel (requester deletes own pending request).
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  insert into public.connections (requester_id, addressee_id) values (u1, u3) returning id into cid;
  delete from public.connections where id = cid;
  get diagnostics n = row_count;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A8 requester can cancel a pending request';
  if not ok then fails := fails + 1; end if;

  -- A9: decline (addressee deletes a pending request).
  insert into public.connections (requester_id, addressee_id) values (u1, u3) returning id into cid;
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  delete from public.connections where id = cid;
  get diagnostics n = row_count;
  ok := n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  A9 addressee can decline a pending request';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- B. _connect_in_person + undo
  -- (_connect_in_person is called as admin here; clients reach it through
  -- the QR/bump RPCs added in later phases.)
  -- =====================================================================

  -- Fixtures made through the normal client flow:
  --   u1-u2 accepted acquaintance, u1-u3 pending (u1 -> u3), u1-u4 nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  insert into public.connections (requester_id, addressee_id) values (u1, u2);
  insert into public.connections (requester_id, addressee_id) values (u1, u3);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  update public.connections set status = 'accepted' where requester_id = u1 and addressee_id = u2;
  reset role;

  -- B1: brand-new pair -> created.
  v := public._connect_in_person(u4, u1, 'qr', '  Boise  ');
  select * into c from public.connections where id = (v ->> 'connection_id')::uuid;
  ok := v ->> 'outcome' = 'created' and c.status = 'accepted' and c.level = 'in_person'
        and c.method = 'qr' and c.met_at is not null and c.met_city = 'Boise'
        and c.undo_snapshot is null and c.undo_until > now();
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B1 new pair -> created (accepted, in_person, city trimmed)';
  if not ok then fails := fails + 1; end if;

  -- B2: accepted acquaintance -> upgraded, snapshot saved.
  v := public._connect_in_person(u2, u1, 'bump', 'Meridian');
  select * into c from public.connections where id = (v ->> 'connection_id')::uuid;
  ok := v ->> 'outcome' = 'upgraded' and c.level = 'in_person' and c.method = 'bump'
        and c.undo_snapshot ->> 'status' = 'accepted' and c.undo_snapshot ->> 'level' = 'acquaintance';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B2 acquaintance -> upgraded with snapshot';
  if not ok then fails := fails + 1; end if;

  -- B3: pending request -> upgraded to accepted in_person.
  v := public._connect_in_person(u3, u1, 'qr', null);
  select * into c from public.connections where id = (v ->> 'connection_id')::uuid;
  ok := v ->> 'outcome' = 'upgraded' and c.status = 'accepted' and c.level = 'in_person'
        and c.met_city is null and c.undo_snapshot ->> 'status' = 'pending';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B3 pending -> upgraded (null city allowed)';
  if not ok then fails := fails + 1; end if;

  -- B4: already in_person -> already_connected, nothing changes.
  select * into c from public.connections where requester_id = u4 and addressee_id = u1;
  v := public._connect_in_person(u1, u4, 'bump', 'Nampa');
  ok := v ->> 'outcome' = 'already_connected'
        and (select met_city from public.connections where id = c.id) = 'Boise';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B4 already in_person -> already_connected, unchanged';
  if not ok then fails := fails + 1; end if;

  -- B5: self-connect is refused.
  err := null;
  begin
    perform public._connect_in_person(u1, u1, 'qr', null);
  exception when others then err := sqlerrm;
  end;
  ok := err = 'self_connect';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B5 self-connect refused';
  if not ok then fails := fails + 1; end if;

  -- B6: a third user can't undo someone else's connection.
  cid := (select id from public.connections where requester_id = u1 and addressee_id = u2);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  v := public.undo_in_person_connection(cid);
  ok := v ->> 'outcome' = 'not_found';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B6 undo by a third user -> not_found';
  if not ok then fails := fails + 1; end if;

  -- B7: undo an upgrade (u2 does it) -> restored to accepted acquaintance/legacy fields.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.undo_in_person_connection(cid);
  reset role;
  select * into c from public.connections where id = cid;
  ok := v ->> 'outcome' = 'undone' and c.status = 'accepted' and c.level = 'acquaintance'
        and c.method = 'request' and c.met_at is null and c.undo_until is null and c.undo_snapshot is null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B7 undo of acquaintance upgrade restores it';
  if not ok then fails := fails + 1; end if;

  -- B8: undo the pending upgrade -> back to pending.
  cid := (select id from public.connections where requester_id = u1 and addressee_id = u3);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.undo_in_person_connection(cid);
  reset role;
  select * into c from public.connections where id = cid;
  ok := v ->> 'outcome' = 'undone' and c.status = 'pending' and c.level = 'acquaintance';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B8 undo of pending upgrade restores pending';
  if not ok then fails := fails + 1; end if;

  -- B9: undo after the window -> too_late. (Push undo_until into the past as admin.)
  cid := (select id from public.connections where requester_id = u4 and addressee_id = u1);
  perform set_config('bolas.trusted_write', 'on', true);
  update public.connections set undo_until = now() - interval '1 second' where id = cid;
  perform set_config('bolas.trusted_write', 'off', true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  v := public.undo_in_person_connection(cid);
  ok := v ->> 'outcome' = 'too_late';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B9 undo after window -> too_late';
  if not ok then fails := fails + 1; end if;

  -- B10: an in_person row can't be pushed back to pending by a client
  -- (guard allows status edits, but the check constraint blocks this one).
  -- u1 is the addressee here (only the addressee may update, per RLS).
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  err := null;
  begin
    update public.connections set status = 'pending' where id = cid;
  exception when others then err := sqlstate;
  end;
  reset role;
  ok := err = '23514';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B10 client cannot set an in_person row to pending (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- B11: undo a brand-new connection -> row deleted.
  v := public._connect_in_person(u2, u3, 'bump', 'Boise');
  cid := (v ->> 'connection_id')::uuid;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.undo_in_person_connection(cid);
  reset role;
  ok := v ->> 'outcome' = 'undone' and not exists (select 1 from public.connections where id = cid);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B11 undo of new connection deletes it';
  if not ok then fails := fails + 1; end if;

  -- B12: counts stay right. u1 now has: u2 accepted, u4 accepted (in_person), u3 pending.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  n := public.get_connection_count(u1);
  reset role;
  ok := n = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B12 connection count counts both levels (got ' || n || ', want 2)';
  if not ok then fails := fails + 1; end if;

  -- B13: anon can't undo.
  perform set_config('role', 'anon', true);
  err := null;
  begin
    perform public.undo_in_person_connection(cid);
  exception when others then err := sqlstate;
  end;
  reset role;
  ok := err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  B13 anon cannot call undo (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- C. QR tokens
  -- State coming in: u1-u2 accepted acquaintance, u1-u3 pending,
  -- u4-u1 in_person.
  -- =====================================================================

  -- C1: create a token.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  v := public.create_connect_token();
  tok := v ->> 'token';
  ok := v ->> 'outcome' = 'ok' and tok ~ '^[0-9a-f]{32}$'
        and (v ->> 'expires_at')::timestamptz = now() + interval '60 seconds';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C1 token is 32 hex chars, expires in 60s';
  if not ok then fails := fails + 1; end if;

  -- C2: u2 scans it -> their acquaintance is upgraded to in_person via qr.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, 'Eagle');
  reset role;
  select * into c from public.connections where id = (v ->> 'connection_id')::uuid;
  ok := v ->> 'outcome' = 'upgraded' and (v ->> 'other_user_id')::uuid = u1
        and (v -> 'other_profile' ->> 'id')::uuid = u1
        and c.level = 'in_person' and c.method = 'qr' and c.met_city = 'Eagle';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C2 redeem works, returns owner profile, upgrades via qr';
  if not ok then fails := fails + 1; end if;

  -- C3: a second scan of the same code -> used.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, null);
  ok := v ->> 'outcome' = 'used';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C3 second redeem -> used';
  if not ok then fails := fails + 1; end if;

  -- C4: the owner sees used + who scanned.
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  v := public.get_connect_token_status(tok);
  ok := v ->> 'status' = 'used' and (v -> 'result' ->> 'other_user_id')::uuid = u2
        and (v -> 'other_profile' ->> 'id')::uuid = u2 and v -> 'result' ->> 'outcome' = 'upgraded';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C4 owner status shows used + scanner profile';
  if not ok then fails := fails + 1; end if;

  -- C5: nobody else can read a code's status.
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.get_connect_token_status(tok);
  ok := v ->> 'status' = 'not_found';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C5 non-owner status -> not_found';
  if not ok then fails := fails + 1; end if;

  -- C6: scanning your own code -> self.
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  tok2 := public.create_connect_token() ->> 'token';
  v := public.redeem_connect_token(tok2, null);
  ok := v ->> 'outcome' = 'self';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C6 own code -> self';
  if not ok then fails := fails + 1; end if;

  -- C7: an expired code -> expired. (Age it as admin.)
  reset role;
  update public.connect_tokens set expires_at = now() - interval '1 second' where token = tok2;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok2, null);
  ok := v ->> 'outcome' = 'expired';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C7 expired code -> expired';
  if not ok then fails := fails + 1; end if;

  -- C8: junk and unknown codes -> invalid.
  ok := public.redeem_connect_token('not a token', null) ->> 'outcome' = 'invalid'
        and public.redeem_connect_token(repeat('a', 32), null) ->> 'outcome' = 'invalid'
        and public.redeem_connect_token(null, null) ->> 'outcome' = 'invalid';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C8 junk / unknown code -> invalid';
  if not ok then fails := fails + 1; end if;

  -- C9: no city from the phone -> falls back to a profile city.
  -- u3 has no profile city, so it falls through to the owner's (u1 = Boise).
  reset role;
  update public.profiles set city = 'Boise' where id = u1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  tok := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, '   ');
  ok := v ->> 'outcome' = 'upgraded' and v ->> 'met_city' = 'Boise';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C9 pending -> upgraded, city falls back to owner profile';
  if not ok then fails := fails + 1; end if;

  -- C10: scanning someone you already met -> already_connected.
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  tok := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, 'Boise');
  ok := v ->> 'outcome' = 'already_connected' and (v -> 'other_profile' ->> 'id')::uuid = u1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C10 already met -> already_connected';
  if not ok then fails := fails + 1; end if;

  -- C11: more than 6 codes a minute -> rate_limited.
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  n := 0;
  for i in 1..6 loop
    if public.create_connect_token() ->> 'outcome' = 'ok' then n := n + 1; end if;
  end loop;
  v := public.create_connect_token();
  ok := n = 6 and v ->> 'outcome' = 'rate_limited';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C11 7th code in a minute -> rate_limited';
  if not ok then fails := fails + 1; end if;

  -- C12: clients can't read the table directly (RLS, no policies).
  select count(*) into n from public.connect_tokens;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C12 direct select on connect_tokens sees nothing (got ' || n || ')';
  if not ok then fails := fails + 1; end if;
  reset role;

  -- C13: anon can't call any of the QR functions.
  perform set_config('role', 'anon', true);
  n := 0;
  begin perform public.create_connect_token(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.redeem_connect_token(tok, null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.get_connect_token_status(tok); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C13 anon blocked from all 3 QR functions (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- D. Bumps
  -- All bumps happen in the middle of the Pacific (10, -140) so real users
  -- can't interfere. 0.00045 deg lat ~ 50 m.
  -- State coming in: u1 is in_person with u2, u3, u4; u2-u3, u2-u4, u3-u4
  -- have no connection.
  -- =====================================================================

  -- D1: two people 50 m apart, moments apart -> matched, connected once.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.0, -140.0, 20, 'Boise');
  b1 := (v ->> 'bump_id')::uuid;
  ok := v ->> 'status' = 'waiting';
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.00045, -140.0, 20, null);
  ok := ok and v ->> 'status' = 'matched' and v ->> 'outcome' = 'created'
        and (v -> 'other_profile' ->> 'id')::uuid = u2 and v ->> 'met_city' = 'Boise';
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.get_bump_result(b1);
  ok := ok and v ->> 'status' = 'matched' and (v ->> 'other_user_id')::uuid = u3;
  reset role;
  select count(*) into n from public.connections
  where least(requester_id, addressee_id) = least(u2, u3)
    and greatest(requester_id, addressee_id) = greatest(u2, u3)
    and level = 'in_person' and method = 'bump';
  ok := ok and n = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D1 50 m apart -> matched on both phones, one bump connection';
  if not ok then fails := fails + 1; end if;

  -- D2: matched rows keep no coordinates.
  select count(*) into n from public.bump_events
  where user_id in (u2, u3) and (lat is not null or lng is not null);
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D2 matched bumps have no coordinates';
  if not ok then fails := fails + 1; end if;

  -- D3: bumps 3+ seconds apart -> no match; the first becomes no_match.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  b1 := (public.submit_bump(10.0, -140.0, 20, null) ->> 'bump_id')::uuid;
  reset role;
  update public.bump_events set created_at = created_at - interval '4 seconds' where id = b1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.0, -140.0, 20, null);
  ok := v ->> 'status' = 'waiting';
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.get_bump_result(b1);
  reset role;
  ok := ok and v ->> 'status' = 'no_match'
        and (select lat from public.bump_events where id = b1) is null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D3 3+ s apart -> no_match (coords erased)';
  if not ok then fails := fails + 1; end if;
  update public.bump_events set status = 'no_match', lat = null, lng = null
  where user_id in (u1, u2, u3, u4) and status = 'waiting';

  -- D4: 2 km apart -> no match.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  perform public.submit_bump(10.0, -140.0, 20, null);
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.018, -140.0, 20, null);
  reset role;
  ok := v ->> 'status' = 'waiting';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D4 2 km apart -> no match';
  if not ok then fails := fails + 1; end if;
  update public.bump_events set status = 'no_match', lat = null, lng = null
  where user_id in (u1, u2, u3, u4) and status = 'waiting';

  -- D5: three people within the window -> ambiguous.
  -- u1 and u2 are 400 m apart (too far for each other at 10 m accuracy);
  -- u4 is between them with poor accuracy, so both are in range for u4.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  b1 := (public.submit_bump(10.0, -140.0, 10, null) ->> 'bump_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', u2, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.0036, -140.0, 10, null);
  ok := v ->> 'status' = 'waiting';
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  v := public.submit_bump(10.0018, -140.0, 200, null);
  ok := ok and v ->> 'status' = 'ambiguous';
  perform set_config('request.jwt.claims', json_build_object('sub', u1, 'role', 'authenticated')::text, true);
  v := public.get_bump_result(b1);
  ok := ok and v ->> 'status' = 'ambiguous';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D5 three people at once -> ambiguous for everyone';
  if not ok then fails := fails + 1; end if;

  -- D6: someone else can't read my bump.
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  v := public.get_bump_result(b1);
  ok := v ->> 'status' = 'not_found';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D6 non-owner get_bump_result -> not_found';
  if not ok then fails := fails + 1; end if;

  -- D7: GPS accuracy worse than 1 km -> poor_location.
  v := public.submit_bump(10.0, -140.0, 1500, null);
  ok := v ->> 'status' = 'poor_location';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D7 accuracy > 1 km -> poor_location';
  if not ok then fails := fails + 1; end if;

  -- D8: impossible coordinates are rejected.
  err := null;
  begin
    perform public.submit_bump(95.0, -140.0, 10, null);
  exception when others then err := sqlstate;
  end;
  ok := err = '22023';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D8 invalid coordinates rejected (got ' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- D9: rows older than 10 minutes are purged on the next bump.
  reset role;
  insert into public.bump_events (user_id, created_at, lat, lng, accuracy_m)
  values (u1, now() - interval '11 minutes', 10.0, -140.0, 10)
  returning id into b1;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u3, 'role', 'authenticated')::text, true);
  perform public.submit_bump(20.0, -140.0, 10, null);
  reset role;
  ok := not exists (select 1 from public.bump_events where id = b1);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D9 bumps older than 10 min are purged';
  if not ok then fails := fails + 1; end if;
  update public.bump_events set status = 'no_match', lat = null, lng = null
  where user_id in (u1, u2, u3, u4) and status = 'waiting';

  -- D10: more than 10 bumps a minute -> rate_limited.
  delete from public.bump_events where user_id = u4;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', u4, 'role', 'authenticated')::text, true);
  n := 0;
  for i in 1..10 loop
    if public.submit_bump(30.0, -140.0, 10, null) ->> 'status' = 'waiting' then n := n + 1; end if;
  end loop;
  v := public.submit_bump(30.0, -140.0, 10, null);
  ok := n = 10 and v ->> 'status' = 'rate_limited';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D10 11th bump in a minute -> rate_limited';
  if not ok then fails := fails + 1; end if;

  -- D11: clients can't read bump_events directly (RLS, no policies).
  select count(*) into n from public.bump_events;
  ok := n = 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D11 direct select on bump_events sees nothing (got ' || n || ')';
  if not ok then fails := fails + 1; end if;
  reset role;

  -- D12: anon can't call the bump functions.
  perform set_config('role', 'anon', true);
  n := 0;
  begin perform public.submit_bump(10.0, -140.0, 10, null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public.get_bump_result(b1); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  reset role;
  ok := n = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  D12 anon blocked from both bump functions (' || n || '/2)';
  if not ok then fails := fails + 1; end if;

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
