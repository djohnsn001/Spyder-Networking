-- Security fix tests (plain SQL; pgTAP isn't set up in this project).
--
-- Safe to run: everything happens inside one DO block that ALWAYS ends by
-- raising an exception, which rolls back every test user and row it created.
-- The exception message is the test report — look for "TEST RESULTS" and any
-- FAIL lines. Run it against the DEV project (see README), with the new
-- migration(s) prepended while they're unpushed:
--
--   npx supabase db query --linked -f supabase/tests/security.sql
--
-- Every section tests the attack, not just the happy path (AGENTS.md rule 5).
--
-- Sections (each runs in its own sub-block; one report at the end):
--   C = forged connections (items C1, C2).
--   H = connect links preview before connecting (item H1).
--   Q = QR codes only work when both phones are together (item H2).
--   M = admin power needs two-step verification (item H4).
--   P = profile photo URLs (item H5).
--   L = profile field limits (item M2).
--   R = rate limits on messages and connection requests (item M4).
--   S = suspended accounts can't write (item M5),
--   T = current Terms required to message / connect / RSVP / host (M5).
--   U = website waitlist (item M6).
--   V = Discover paging RPC (item M8).

do $tests$
declare
  report text := '';
  fails int := 0;
begin

  -- #####################################################################
  -- security/c1-c2: C = forged connections (items C1, C2).
  -- #####################################################################
  reset role;
  declare
    -- Connections
    cA uuid := gen_random_uuid();   -- attacker / requester
    cB uuid := gen_random_uuid();   -- addressee
    cC uuid := gen_random_uuid();   -- innocent third user
    cD uuid := gen_random_uuid();   -- for a brand-new in-person connect

    ok boolean;
    err text;
    n int;
    v jsonb;
    rec record;
    conn_ab uuid;
    conn_ac uuid;
    tok text;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[cA, cB, cC, cD]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[cA, cB, cC, cD]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (cA, cB, cC, cD);

    -- =====================================================================
    -- C. Forged connections (C1, C2)
    -- =====================================================================

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cA, 'role', 'authenticated')::text, true);

    -- C1 (attack): A inserts a row to B that claims to be accepted, in person,
    -- and backdated. It must be stored as a plain pending request (or refused).
    err := null;
    begin
      insert into public.connections
        (requester_id, addressee_id, status, level, method, met_at, created_at)
      values
        (cA, cB, 'accepted', 'in_person', 'qr', now(), now() - interval '1 year');
    exception when others then err := sqlstate;
    end;
    reset role;
    select * into rec from public.connections where requester_id = cA and addressee_id = cB;
    conn_ab := rec.id;
    ok := err is not null
          or (rec.status = 'pending' and rec.level = 'acquaintance' and rec.method = 'request'
              and rec.met_at is null and rec.created_at = now());
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C1 insert with status accepted -> stored as ' || coalesce(rec.status, 'nothing')
      || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- C2 (attack): B, the addressee, repoints the request at C and accepts it.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cB, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.connections set requester_id = cC, status = 'accepted' where id = conn_ab;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err = '42501'
          and exists (select 1 from public.connections where id = conn_ab and requester_id = cA and status = 'pending')
          and not exists (
            select 1 from public.connections
            where (requester_id = cC and addressee_id = cB) or (requester_id = cB and addressee_id = cC));
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C2 addressee changes requester_id to a third user -> refused (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- C3 (attack): B changes addressee_id.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cB, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.connections set addressee_id = cC where id = conn_ab;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err = '42501' and exists (select 1 from public.connections where id = conn_ab and addressee_id = cB);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C3 addressee changes addressee_id -> refused (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- C4 (attack): A, the requester, accepts their own request. The update
    -- policy only matches the addressee, so nothing changes.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cA, 'role', 'authenticated')::text, true);
    err := null;
    n := -1;
    begin
      update public.connections set status = 'accepted' where id = conn_ab;
      get diagnostics n = row_count;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := (n = 0 or err is not null)
          and exists (select 1 from public.connections where id = conn_ab and status = 'pending');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C4 requester accepts own request -> no rows changed (' || n || ' rows' || coalesce(', ' || err, '') || ')';
    if not ok then fails := fails + 1; end if;

    -- C5 (normal flow): B accepts A's request, the way the app does it.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cB, 'role', 'authenticated')::text, true);
    err := null;
    n := -1;
    begin
      update public.connections set status = 'accepted' where id = conn_ab;
      get diagnostics n = row_count;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err is null and n = 1
          and exists (
            select 1 from public.connections
            where id = conn_ab and status = 'accepted' and level = 'acquaintance' and method = 'request');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C5 normal flow: A requests, B accepts -> accepted' || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- C6 (attack): B sets the accepted row back to pending.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cB, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.connections set status = 'pending' where id = conn_ab;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err = '42501' and exists (select 1 from public.connections where id = conn_ab and status = 'accepted');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C6 accepted -> pending by a client -> refused (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- C7 (attack): B promotes the connection to in-person directly.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cB, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.connections set level = 'in_person', met_at = now() where id = conn_ab;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err = '42501' and exists (select 1 from public.connections where id = conn_ab and level = 'acquaintance');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C7 client sets level = in_person -> refused (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- C8 (trusted path): a pending request is upgraded by a real QR connect,
    -- and Undo restores it to pending (a status change only trusted code may make).
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', cA, 'role', 'authenticated')::text, true);
    insert into public.connections (requester_id, addressee_id) values (cA, cC);
    tok := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', cC, 'role', 'authenticated')::text, true);
    v := public.redeem_connect_token(tok, 'Boise', 43.6151, -116.2021, 15);
    select id into conn_ac from public.connections where requester_id = cA and addressee_id = cC;
    ok := v ->> 'outcome' = 'upgraded'
          and exists (
            select 1 from public.connections
            where id = conn_ac and status = 'accepted' and level = 'in_person' and method = 'qr'
              and met_city = 'Boise');
    v := public.undo_in_person_connection(conn_ac);
    reset role;
    ok := ok and v ->> 'outcome' = 'undone'
          and exists (
            select 1 from public.connections
            where id = conn_ac and status = 'pending' and level = 'acquaintance');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C8 QR connect upgrades pending -> in_person; Undo restores pending (trusted path)';
    if not ok then fails := fails + 1; end if;

    -- C9 (trusted path): a brand-new in-person connect creates level in_person.
    v := public._connect_in_person(cB, cD, 'bump', 'Meridian');
    ok := v ->> 'outcome' = 'created'
          and exists (
            select 1 from public.connections
            where least(requester_id, addressee_id) = least(cB, cD)
              and greatest(requester_id, addressee_id) = greatest(cB, cD)
              and status = 'accepted' and level = 'in_person' and method = 'bump');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C9 _connect_in_person creates an accepted in_person connection';
    if not ok then fails := fails + 1; end if;

    -- C10 (not a client): the service key (seed scripts) can still insert an
    -- accepted row directly.
    perform set_config('role', 'service_role', true);
    insert into public.connections (requester_id, addressee_id, status) values (cC, cD, 'accepted');
    reset role;
    ok := exists (select 1 from public.connections where requester_id = cC and addressee_id = cD and status = 'accepted');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C10 service_role (seed scripts) insert keeps status accepted';
    if not ok then fails := fails + 1; end if;

    -- C11 (attack): signed-out callers can't insert or update connections.
    perform set_config('role', 'anon', true);
    n := 0;
    begin insert into public.connections (requester_id, addressee_id) values (cD, cA);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin update public.connections set status = 'accepted' where id = conn_ac;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    ok := n = 2;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  C11 anon refused on insert and update (' || n || '/2)';
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/h1: H = connect links preview before connecting (item H1).
  -- #####################################################################
  reset role;
  declare
    -- Connect-link preview
    hA uuid := gen_random_uuid();   -- shows a code
    hB uuid := gen_random_uuid();   -- opens a link to it
    hC uuid := gen_random_uuid();   -- hammers the preview (rate limit)
    hX uuid := gen_random_uuid();   -- blocked hA

    ok boolean;
    err text;
    n int;
    i int;
    v jsonb;
    tok text;
    tok_expired text := encode(extensions.gen_random_bytes(16), 'hex');
    cid uuid;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[hA, hB, hC, hX]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[hA, hB, hC, hX]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (hA, hB, hC, hX);

    -- =====================================================================
    -- H. Connect links preview before connecting (H1)
    -- =====================================================================

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hA, 'role', 'authenticated')::text, true);
    tok := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';

    -- H1: previewing a valid code shows the owner's card...
    perform set_config('request.jwt.claims', json_build_object('sub', hB, 'role', 'authenticated')::text, true);
    v := public.preview_connect_token(tok);
    reset role;
    ok := v ->> 'outcome' = 'ok'
          and (v -> 'other_profile' ->> 'id')::uuid = hA
          and v -> 'other_profile' ->> 'username' = (select username from public.profiles where id = hA)
          and v ? 'expires_at';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H1 preview of a valid code -> ok with the owner''s card';
    if not ok then fails := fails + 1; end if;

    -- H2 (the attack): ...but doesn't use it up or connect anyone. Previewing
    -- again still works, no connection exists, and the code still redeems.
    ok := exists (select 1 from public.connect_tokens where token = tok and used_at is null)
          and not exists (
            select 1 from public.connections
            where least(requester_id, addressee_id) = least(hA, hB)
              and greatest(requester_id, addressee_id) = greatest(hA, hB));
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hB, 'role', 'authenticated')::text, true);
    v := public.preview_connect_token(tok);
    ok := ok and v ->> 'outcome' = 'ok';
    v := public.redeem_connect_token(tok, null, 43.6151, -116.2021, 15);
    reset role;
    ok := ok and v ->> 'outcome' = 'created';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H2 preview doesn''t consume the code or connect; redeem still works after';
    if not ok then fails := fails + 1; end if;

    -- H3: used / expired / junk / unknown / own code.
    insert into public.connect_tokens (token, user_id, created_at, expires_at)
    values (tok_expired, hA, now() - interval '5 minutes', now() - interval '4 minutes');
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hB, 'role', 'authenticated')::text, true);
    n := 0;
    if public.preview_connect_token(tok) ->> 'outcome' = 'used' then n := n + 1; end if;
    if public.preview_connect_token(tok_expired) ->> 'outcome' = 'expired' then n := n + 1; end if;
    if public.preview_connect_token('not-a-code') ->> 'outcome' = 'invalid' then n := n + 1; end if;
    if public.preview_connect_token(encode(extensions.gen_random_bytes(16), 'hex')) ->> 'outcome' = 'invalid' then n := n + 1; end if;
    if public.preview_connect_token(null) ->> 'outcome' = 'invalid' then n := n + 1; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', hA, 'role', 'authenticated')::text, true);
    v := public.create_connect_token(43.61504, -116.20207, 15);
    if public.preview_connect_token(v ->> 'token') ->> 'outcome' = 'self' then n := n + 1; end if;
    reset role;
    ok := n = 6;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H3 used / expired / junk / unknown / null / own code -> right outcome (' || n || '/6)';
    if not ok then fails := fails + 1; end if;

    -- H4 (attack): signed-out callers can't preview.
    perform set_config('role', 'anon', true);
    err := null;
    begin perform public.preview_connect_token(tok); exception when others then err := sqlstate; end;
    reset role;
    ok := err = '42501';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H4 anon refused by preview_connect_token (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- H5 (attack): the 21st preview in a minute is rate limited (failed
    -- lookups count, so it can't be used to probe for codes).
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hC, 'role', 'authenticated')::text, true);
    n := 0;
    for i in 1..20 loop
      if public.preview_connect_token(encode(extensions.gen_random_bytes(16), 'hex')) ->> 'outcome' = 'invalid' then
        n := n + 1;
      end if;
    end loop;
    v := public.preview_connect_token(tok_expired);
    reset role;
    ok := n = 20 and v ->> 'outcome' = 'rate_limited';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H5 21st preview in a minute -> rate_limited (' || n || ' answered first)';
    if not ok then fails := fails + 1; end if;

    -- H6 (attack): a code from someone you're blocked with shows nothing.
    insert into public.user_blocks (blocker_id, blocked_id) values (hX, hA);
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hA, 'role', 'authenticated')::text, true);
    tok := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', hX, 'role', 'authenticated')::text, true);
    v := public.preview_connect_token(tok);
    reset role;
    ok := v = jsonb_build_object('outcome', 'invalid');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H6 code from a blocked user -> generic invalid, no profile (' || v::text || ')';
    if not ok then fails := fails + 1; end if;

    -- H7 (attack): the rate-limit log isn't readable or writable by clients.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hC, 'role', 'authenticated')::text, true);
    n := 0;
    begin perform count(*) from public.connect_token_preview_log;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin delete from public.connect_token_preview_log where user_id = hC;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    ok := n = 2;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H7 clients can''t read or clear the preview log (' || n || '/2)';
    if not ok then fails := fails + 1; end if;

    -- H8: an in-person connection can be removed by either person at any
    -- time, long after the 30-second undo (both sides checked).
    select id into cid from public.connections
    where least(requester_id, addressee_id) = least(hA, hB)
      and greatest(requester_id, addressee_id) = greatest(hA, hB);
    perform set_config('bolas.trusted_write', 'on', true);
    update public.connections set undo_until = now() - interval '1 day', met_at = now() - interval '1 day'
    where id = cid;
    perform set_config('bolas.trusted_write', 'off', true);
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hB, 'role', 'authenticated')::text, true);
    delete from public.connections where id = cid;
    get diagnostics n = row_count;
    reset role;
    ok := n = 1;
    v := public._connect_in_person(hA, hC, 'bump', null);
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', hA, 'role', 'authenticated')::text, true);
    delete from public.connections where id = (v ->> 'connection_id')::uuid;
    get diagnostics n = row_count;
    reset role;
    ok := ok and n = 1;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  H8 either person can remove an in-person connection after the undo window';
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/h2: Q = QR codes only work when both phones are together (item H2).
  -- #####################################################################
  reset role;
  declare
    -- QR distance
    qA uuid := gen_random_uuid();   -- shows codes (Boise)
    qB uuid := gen_random_uuid();   -- scans next to qA
    qC uuid := gen_random_uuid();   -- scans from 5 km away (a shared screenshot)

    ok boolean;
    err text;
    n int;
    v jsonb;
    tok text;
    rec record;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[qA, qB, qC]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[qA, qB, qC]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (qA, qB, qC);

    -- =====================================================================
    -- Q. QR codes only work when both phones are together (H2)
    -- =====================================================================

    -- Q1: a code is made with the owner's location, rounded to 3 decimals,
    -- and lives 30 s.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qA, 'role', 'authenticated')::text, true);
    v := public.create_connect_token(43.61504, -116.20207, 15);
    tok := v ->> 'token';
    reset role;
    select * into rec from public.connect_tokens where token = tok;
    ok := v ->> 'outcome' = 'ok'
          and (v ->> 'expires_at')::timestamptz = now() + interval '30 seconds'
          and rec.lat = 43.615 and rec.lng = -116.202 and rec.accuracy_m = 15;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q1 code stores the owner''s location to 3 decimals and expires in 30 s';
    if not ok then fails := fails + 1; end if;

    -- Q2 (the attack): someone 5 km away scans a shared screenshot -> too_far,
    -- and the code stays unused.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qC, 'role', 'authenticated')::text, true);
    v := public.redeem_connect_token(tok, null, 43.660, -116.202, 15);
    reset role;
    ok := v = jsonb_build_object('outcome', 'too_far')
          and exists (select 1 from public.connect_tokens where token = tok and used_at is null)
          and not exists (
            select 1 from public.connections
            where least(requester_id, addressee_id) = least(qA, qC)
              and greatest(requester_id, addressee_id) = greatest(qA, qC));
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q2 scan from 5 km away -> too_far, code unused, no connection';
    if not ok then fails := fails + 1; end if;

    -- Q3: 400 m apart with good GPS is still too far (limit is
    -- max(300 m, accuracy + accuracy) = 300 m here).
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qB, 'role', 'authenticated')::text, true);
    v := public.redeem_connect_token(tok, null, 43.6186, -116.202, 15);
    ok := v ->> 'outcome' = 'too_far';

    -- Q4: standing together -> connects, and the code's location is erased.
    v := public.redeem_connect_token(tok, 'Boise', 43.6151, -116.2021, 15);
    reset role;
    select * into rec from public.connect_tokens where token = tok;
    ok := ok and v ->> 'outcome' = 'created'
          and rec.used_at is not null and rec.lat is null and rec.lng is null and rec.accuracy_m is null
          and exists (
            select 1 from public.connections
            where least(requester_id, addressee_id) = least(qA, qB)
              and greatest(requester_id, addressee_id) = greatest(qA, qB)
              and level = 'in_person' and method = 'qr');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q3/Q4 400 m -> too_far; same spot -> connected, code''s location erased';
    if not ok then fails := fails + 1; end if;

    -- Q5: nothing else stores the location: no coordinates in either side's
    -- result JSON.
    ok := not (rec.result ?| array['lat', 'lng', 'latitude', 'longitude', 'accuracy_m'])
          and not (v ?| array['lat', 'lng', 'latitude', 'longitude', 'accuracy_m']);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q5 no coordinates in the redeem result or the owner''s copy';
    if not ok then fails := fails + 1; end if;

    -- Q6: missing location blocks (Zane's choice): the owner can't make a
    -- code without one, and a scan without one leaves the code unused.
    -- Old-style calls (no location arguments) resolve but get the same answer.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qA, 'role', 'authenticated')::text, true);
    n := 0;
    if public.create_connect_token() ->> 'outcome' = 'location_required' then n := n + 1; end if;
    if public.create_connect_token(43.615, null, 15) ->> 'outcome' = 'location_required' then n := n + 1; end if;
    tok := public.create_connect_token(43.615, -116.202, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', qC, 'role', 'authenticated')::text, true);
    if public.redeem_connect_token(tok, null) ->> 'outcome' = 'location_required' then n := n + 1; end if;
    if public.redeem_connect_token(tok, null, 43.615, -116.202, null) ->> 'outcome' = 'location_required' then n := n + 1; end if;
    reset role;
    ok := n = 4 and exists (select 1 from public.connect_tokens where token = tok and used_at is null);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q6 no location (owner or scanner, incl. old-style calls) -> location_required, code unused (' || n || '/4)';
    if not ok then fails := fails + 1; end if;

    -- Q7 (attack): claiming terrible accuracy can't stretch the allowed
    -- distance. Accuracy worse than 1 km -> poor_location on both sides.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qA, 'role', 'authenticated')::text, true);
    n := 0;
    if public.create_connect_token(43.615, -116.202, 5000) ->> 'outcome' = 'poor_location' then n := n + 1; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', qC, 'role', 'authenticated')::text, true);
    if public.redeem_connect_token(tok, null, 43.660, -116.202, 5000) ->> 'outcome' = 'poor_location' then n := n + 1; end if;
    reset role;
    ok := n = 2 and exists (select 1 from public.connect_tokens where token = tok and used_at is null);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q7 accuracy > 1 km -> poor_location, can''t widen the radius (' || n || '/2)';
    if not ok then fails := fails + 1; end if;

    -- Q8: 31 s later the code has expired (made 31 s ago, so its 30 s ran
    -- out a second ago; Q1 checks the 30 s lifetime itself).
    update public.connect_tokens
    set created_at = now() - interval '31 seconds', expires_at = now() - interval '1 second'
    where token = tok;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qB, 'role', 'authenticated')::text, true);
    v := public.redeem_connect_token(tok, null, 43.6151, -116.2021, 15);
    reset role;
    ok := v ->> 'outcome' = 'expired';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q8 code 31 s old -> expired';
    if not ok then fails := fails + 1; end if;

    -- Q9 (attack): bad coordinates are rejected, and signed-out callers can't
    -- use either function.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', qA, 'role', 'authenticated')::text, true);
    n := 0;
    begin perform public.create_connect_token(123, -116.202, 15);
    exception when others then if sqlstate = '22023' then n := n + 1; end if; end;
    reset role;
    perform set_config('role', 'anon', true);
    begin perform public.create_connect_token(43.615, -116.202, 15);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.redeem_connect_token(tok, null, 43.615, -116.202, 15);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    ok := n = 3;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q9 invalid coordinates rejected; anon refused by both functions (' || n || '/3)';
    if not ok then fails := fails + 1; end if;

    -- Q10: the old signatures are gone (nothing can call a version without
    -- the distance check).
    ok := not exists (
            select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname = 'redeem_connect_token' and p.pronargs = 2)
          and not exists (
            select 1 from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
            where ns.nspname = 'public' and p.proname = 'create_connect_token' and p.pronargs = 0);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  Q10 old create()/redeem(text, text) overloads dropped';
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/h4: M = admin power needs two-step verification (item H4).
  -- #####################################################################
  reset role;
  declare
    -- Admin MFA
    mA uuid := gen_random_uuid();   -- on the admin list
    mU uuid := gen_random_uuid();   -- normal user
    mS uuid := gen_random_uuid();   -- suspended user (only admins can see them)
    eH uuid;                        -- a hidden event hosted by mU

    ok boolean;
    n int;
    v jsonb;
    a1 text;   -- claims: admin, password only (aal1)
    a2 text;   -- claims: admin, after a second factor (aal2)
    u2 text;   -- claims: normal user at aal2
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '1 day'
    from unnest(array[mA, mU, mS]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[mA, mU, mS]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (mA, mU, mS);

    insert into public.app_admins (user_id) values (mA);
    insert into public.account_restrictions (user_id, status) values (mS, 'suspended');
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility, status)
    values (mU, 'Sec hidden event', 43.6, -116.2, now() + interval '1 day', 'public', 'hidden')
    returning id into eH;

    a1 := json_build_object('sub', mA, 'role', 'authenticated', 'aal', 'aal1')::text;
    a2 := json_build_object('sub', mA, 'role', 'authenticated', 'aal', 'aal2')::text;
    u2 := json_build_object('sub', mU, 'role', 'authenticated', 'aal', 'aal2')::text;

    -- =====================================================================
    -- M. Admin power needs two-step verification (H4)
    -- =====================================================================

    -- M1 (the attack): an admin's password alone (aal1) opens no admin RPC.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', a1, true);
    n := 0;
    begin perform public.admin_list_user_reports(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_list_flagged_events(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_find_user('sec'); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_set_account_status(mU, 'suspended', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_set_host_status(mU, 'suspended', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_set_event_status(eH, 'active', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_resolve_user_report(gen_random_uuid(), 'dismissed', null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    ok := n = 7 and not public.is_admin();
    reset role;
    ok := ok and not exists (select 1 from public.account_restrictions where user_id = mU)
          and (select status from public.events where id = eH) = 'hidden';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M1 admin at aal1: all 7 admin RPCs refused, is_admin() false (' || n || '/7)';
    if not ok then fails := fails + 1; end if;

    -- M2: the same admin at aal2 can use them.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', a2, true);
    n := 0;
    begin perform public.admin_list_user_reports(); n := n + 1; exception when others then null; end;
    begin perform public.admin_list_flagged_events(); n := n + 1; exception when others then null; end;
    begin perform public.admin_find_user('sec'); n := n + 1; exception when others then null; end;
    begin
      if public.admin_set_event_status(eH, 'active', null) ->> 'outcome' = 'updated' then n := n + 1; end if;
    exception when others then null; end;
    ok := n = 4 and public.is_admin();
    reset role;
    ok := ok and (select status from public.events where id = eH) = 'active';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M2 admin at aal2: admin RPCs work (' || n || '/4)';
    if not ok then fails := fails + 1; end if;

    -- M3 (attack): aal2 alone doesn't make a normal user an admin.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', u2, true);
    n := 0;
    begin perform public.admin_list_user_reports(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public.admin_set_account_status(mS, null, null); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    ok := n = 2 and not public.is_admin();
    reset role;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M3 non-admin at aal2: admin RPCs refused (' || n || '/2)';
    if not ok then fails := fails + 1; end if;

    -- M4: at aal1 the admin sees what a normal user sees (policies that call
    -- is_admin): no hidden events of others, no suspended profiles. At aal2,
    -- both are visible.
    update public.events set status = 'hidden' where id = eH;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', a1, true);
    select count(*) into n from public.events where id = eH;
    ok := n = 0;
    select count(*) into n from public.profiles where id = mS;
    ok := ok and n = 0;
    perform set_config('request.jwt.claims', a2, true);
    select count(*) into n from public.events where id = eH;
    ok := ok and n = 1;
    select count(*) into n from public.profiles where id = mS;
    ok := ok and n = 1;
    reset role;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M4 policies: aal1 admin sees like a normal user; aal2 admin sees hidden/suspended';
    if not ok then fails := fails + 1; end if;

    -- M5: hosting perks (public events, no limits) only at aal2. mA's account
    -- is 1 day old with no in-person connections, so without admin it can't
    -- host public events.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', a1, true);
    v := public.get_my_hosting_status();
    ok := not (v ->> 'is_admin')::boolean and not (v ->> 'can_host_public')::boolean
          and public.create_event('Sec public', null, null, 43.6, -116.2, now() + interval '1 day', null, 'public')
              ->> 'outcome' = 'public_locked';
    perform set_config('request.jwt.claims', a2, true);
    v := public.get_my_hosting_status();
    ok := ok and (v ->> 'is_admin')::boolean and (v ->> 'can_host_public')::boolean;
    reset role;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M5 hosting perks: aal1 admin is public_locked; aal2 admin can host public';
    if not ok then fails := fails + 1; end if;

    -- M6: get_my_admin_status drives the Settings row.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', a1, true);
    ok := public.get_my_admin_status() = jsonb_build_object('is_admin', false, 'needs_mfa', true);
    perform set_config('request.jwt.claims', a2, true);
    ok := ok and public.get_my_admin_status() = jsonb_build_object('is_admin', true, 'needs_mfa', false);
    perform set_config('request.jwt.claims', u2, true);
    ok := ok and public.get_my_admin_status() = jsonb_build_object('is_admin', false, 'needs_mfa', false);
    reset role;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M6 get_my_admin_status: aal1 admin needs_mfa; aal2 admin is_admin; others neither';
    if not ok then fails := fails + 1; end if;

    -- M7 (attack): a token with no aal claim at all counts as aal1, and
    -- signed-out callers can't ask.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', mA, 'role', 'authenticated')::text, true);
    ok := not public.is_admin();
    reset role;
    perform set_config('role', 'anon', true);
    n := 0;
    begin perform public.get_my_admin_status(); exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    ok := ok and n = 1;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  M7 no aal claim -> not admin; anon refused by get_my_admin_status';
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/h5: P = profile photo URLs (item H5).
  -- #####################################################################
  reset role;
  declare
    -- Profile photos
    pA uuid := gen_random_uuid();   -- attacker, editing their own profile
    pB uuid := gen_random_uuid();   -- another user
    -- Production base; public.avatar_url_allowed() accepts it in every database.
    avatars text := 'https://fhevoocpcnrjxyjvitai.supabase.co/storage/v1/object/public/avatars/';
    own_url text;

    ok boolean;
    err text;
    n int;
    stored text;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[pA, pB]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[pA, pB]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (pA, pB);

    own_url := avatars || pA || '/1727650000000.jpg';

    -- =====================================================================
    -- P. Profile photo URLs (H5)
    -- =====================================================================

    -- P1 (attack): A points their photo at their own server to log viewers' IPs.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', pA, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.profiles set avatar_url = 'https://evil.example/pixel.jpg' where id = pA;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pA;
    ok := err = '23514' and stored is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P1 external URL -> rejected (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- P2 (attack): A uses a real photo URL from B's folder.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', pA, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.profiles set avatar_url = avatars || pB || '/1727650000000.jpg' where id = pA;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pA;
    ok := err = '23514' and stored is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P2 someone else''s folder -> rejected (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- P3 (attack): a look-alike host that starts with our project's name.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', pA, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.profiles
      set avatar_url = 'https://fhevoocpcnrjxyjvitai.supabase.co.evil.example/storage/v1/object/public/avatars/'
                       || pA || '/x.jpg'
      where id = pA;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pA;
    ok := err = '23514' and stored is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P3 look-alike host -> rejected (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- P4 (attack): the service key isn't an exception (the rule is on the table).
    perform set_config('role', 'service_role', true);
    err := null;
    begin
      update public.profiles set avatar_url = 'https://evil.example/pixel.jpg' where id = pB;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pB;
    ok := err = '23514' and stored is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P4 service_role external URL -> rejected (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- P5 (allowed): A's own folder, the shape the app's getPublicUrl returns.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', pA, 'role', 'authenticated')::text, true);
    err := null;
    n := -1;
    begin
      update public.profiles set avatar_url = own_url where id = pA;
      get diagnostics n = row_count;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pA;
    ok := err is null and n = 1 and stored = own_url;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P5 own folder -> allowed (' || n || ' rows' || coalesce(', ' || err, '') || ')';
    if not ok then fails := fails + 1; end if;

    -- P6 (allowed): removing the photo.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', pA, 'role', 'authenticated')::text, true);
    err := null;
    n := -1;
    begin
      update public.profiles set avatar_url = null where id = pA;
      get diagnostics n = row_count;
    exception when others then err := sqlstate;
    end;
    reset role;
    select avatar_url into stored from public.profiles where id = pA;
    ok := err is null and n = 1 and stored is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  P6 null -> allowed (' || n || ' rows' || coalesce(', ' || err, '') || ')';
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/m2: L = profile field limits (item M2).
  -- #####################################################################
  reset role;
  declare
    -- Profile limits
    lA uuid := gen_random_uuid();   -- edits their own profile
    lB uuid := gen_random_uuid();   -- another user
    all12 text := 'array[''SaaS'', ''AI / ML'', ''E-commerce'', ''Marketplace'', ''Fintech'', ''Consumer'', '
               || '''Hardware'', ''Health'', ''Education'', ''Social'', ''Sustainability'', ''Creator tools'']';

    ok boolean;
    err text;
    n int;
    rec record;
    stored text;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[lA, lB]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[lA, lB]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (lA, lB);

    -- =====================================================================
    -- L. Profile field limits (M2)
    -- =====================================================================
    -- Each case runs one update as a signed-in user ($1 = their id).
    -- expect: 'ok' (exactly one row saved) or the SQLSTATE of the rejection
    -- (23514 = broke a check constraint, 23505 = duplicate).
    for rec in
      select * from (values
        -- username format
        ('L1',  lA, 'ok',    'update public.profiles set username = ''Zane_Builds'' where id = $1',
                'capitals allowed in, saved lower-case (checked below)'),
        ('L2',  lB, '23514', 'update public.profiles set username = ''z'' || chr(1072) || ''ne_builds'' where id = $1',
                'Cyrillic lookalike "zаne_builds" (U+0430) rejected'),
        ('L3',  lB, '23514', 'update public.profiles set username = chr(1040) || ''DMIN_real'' where id = $1',
                'Cyrillic capital "АDMIN_real" (lower-cased is still Cyrillic) rejected'),
        ('L4',  lB, '23514', 'update public.profiles set username = ''bolas.team'' where id = $1',
                'dot in username rejected'),
        ('L5',  lB, '23514', 'update public.profiles set username = ''zane builds'' where id = $1',
                'space in username rejected'),
        ('L6',  lB, '23514', 'update public.profiles set username = ''ab'' where id = $1',
                '2 characters rejected'),
        ('L7',  lB, '23514', 'update public.profiles set username = repeat(''a'', 21) where id = $1',
                '21 characters rejected'),
        ('L8',  lB, 'ok',    'update public.profiles set username = repeat(''a'', 20) where id = $1',
                '20 characters allowed'),
        -- case-insensitive uniqueness
        ('L9',  lB, '23505', 'update public.profiles set username = ''ZANE_BUILDS'' where id = $1',
                '"ZANE_BUILDS" when "zane_builds" exists rejected as taken'),
        -- reserved names
        ('L10', lB, '23514', 'update public.profiles set username = ''admin'' where id = $1',
                'reserved "admin" rejected'),
        ('L11', lB, '23514', 'update public.profiles set username = ''Support'' where id = $1',
                'reserved "Support" (any case) rejected'),
        ('L12', lB, '23514', 'update public.profiles set username = ''bolas'' where id = $1',
                'reserved "bolas" rejected'),
        ('L13', lB, '23514', 'update public.profiles set username = ''bolas_support'' where id = $1',
                '"bolas_support" (bolas_ prefix) rejected'),
        ('L14', lB, '23514', 'update public.profiles set username = ''BOLAS_official'' where id = $1',
                '"BOLAS_official" (prefix, any case) rejected'),
        ('L15', lB, 'ok',    'update public.profiles set username = ''helpful_hank'' where id = $1',
                '"helpful_hank" allowed (reserved names are exact, not substrings)'),
        -- full_name
        ('L16', lA, '23514', 'update public.profiles set full_name = repeat(''x'', 10000) where id = $1',
                '10,000-character full_name rejected'),
        ('L17', lA, '23514', 'update public.profiles set full_name = repeat(''x'', 51) where id = $1',
                '51-character full_name rejected'),
        ('L18', lA, 'ok',    'update public.profiles set full_name = repeat(chr(233), 50) where id = $1',
                '50-character full_name allowed (counts characters, not bytes)'),
        -- city
        ('L19', lA, '23514', 'update public.profiles set city = repeat(''x'', 81) where id = $1',
                '81-character city rejected'),
        ('L20', lA, 'ok',    'update public.profiles set city = repeat(''x'', 80) where id = $1',
                '80-character city allowed'),
        -- interests
        ('L21', lA, 'ok',    'update public.profiles set interests = array[''SaaS'', ''Fintech''] where id = $1',
                'interests from the list allowed'),
        ('L22', lA, 'ok',    'update public.profiles set interests = ' || all12 || ' where id = $1',
                'all 12 interests allowed'),
        ('L23', lA, '23514', 'update public.profiles set interests = ' || all12 || ' || array[''SaaS''] where id = $1',
                '13 items rejected'),
        ('L24', lA, '23514', 'update public.profiles set interests = array[''SaaS'', ''Crypto''] where id = $1',
                'interest not on the list rejected'),
        ('L25', lA, '23514', 'update public.profiles set interests = array[''saas''] where id = $1',
                'interest in the wrong case rejected'),
        ('L26', lA, '23514', 'update public.profiles set interests = array[''SaaS'', ''SaaS''] where id = $1',
                'repeated interest rejected'),
        ('L27', lA, '23514', 'update public.profiles set interests = array[''SaaS'', null] where id = $1',
                'null interest rejected'),
        ('L28', lA, '23514', 'update public.profiles set interests = array[repeat(''x'', 10000)] where id = $1',
                'huge interest string rejected'),
        ('L29', lA, 'ok',    'update public.profiles set interests = ''{}'' where id = $1',
                'no interests allowed')
      ) as t(label, uid, expect, stmt, what)
    loop
      perform set_config('role', 'authenticated', true);
      perform set_config('request.jwt.claims', json_build_object('sub', rec.uid, 'role', 'authenticated')::text, true);
      err := null;
      n := -1;
      begin
        execute rec.stmt using rec.uid;
        get diagnostics n = row_count;
        err := 'ok';
      exception when others then err := sqlstate;
      end;
      reset role;
      ok := err = rec.expect and (rec.expect <> 'ok' or n = 1);
      report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
        || '  ' || rec.label || ' ' || rec.what
        || ' (' || case when err = 'ok' then n || ' rows' else err end || ')';
      if not ok then fails := fails + 1; end if;
    end loop;

    -- L30: L1 was stored lower-case.
    select username into stored from public.profiles where id = lA;
    ok := stored = 'zane_builds';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  L30 "Zane_Builds" stored as ' || coalesce(stored, 'null');
    if not ok then fails := fails + 1; end if;

    -- L31 (attack): the service key isn't an exception; the rules are on the table.
    perform set_config('role', 'service_role', true);
    err := null;
    begin
      update public.profiles set full_name = repeat('x', 10000), username = 'staff' where id = lB;
    exception when others then err := sqlstate;
    end;
    reset role;
    ok := err = '23514';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  L31 service_role 10,000-char name + reserved username rejected (' || coalesce(err, 'no error') || ')';
    if not ok then fails := fails + 1; end if;

    -- L32: an OLD row with capitals (from before this migration) can still be
    -- saved; the trigger lower-cases it on any update. Fake the old row by
    -- briefly lifting the rule (as admin; rolled back with everything else).
    alter table public.profiles drop constraint profiles_username_format;
    alter table public.profiles disable trigger profiles_lowercase_username;
    update public.profiles set username = 'OldStyle_Name' where id = lB;
    alter table public.profiles enable trigger profiles_lowercase_username;
    alter table public.profiles
      add constraint profiles_username_format
      check (username is null or username ~ '^[a-z0-9_]{3,20}$') not valid;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', lB, 'role', 'authenticated')::text, true);
    err := null;
    begin
      update public.profiles set bio = 'Still here' where id = lB;
    exception when others then err := sqlstate;
    end;
    reset role;
    select username into stored from public.profiles where id = lB;
    ok := err is null and stored = 'oldstyle_name';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  L32 old "OldStyle_Name" row saves fine, becomes ' || coalesce(stored, 'null')
      || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- Always roll back: nothing from this run is kept.
  end;

  -- #####################################################################
  -- security/m4: R = rate limits on messages and connection requests (item M4).
  -- #####################################################################
  reset role;
  declare
    -- Rate limits
    rS uuid := gen_random_uuid();   -- established sender (30 days old)
    rN uuid := gen_random_uuid();   -- new account (1 day old)
    rD uuid := gen_random_uuid();   -- established, for the daily message cap
    rT uuid := gen_random_uuid();   -- receives everyone's messages
    rA uuid := gen_random_uuid();   -- established, sends connection requests
    rB uuid := gen_random_uuid();   -- new account, sends connection requests
    rM uuid := gen_random_uuid();   -- met rA in person
    rM2 uuid := gen_random_uuid();  -- met rA in person (other direction)
    targets uuid[];                 -- 30 people to send requests to
    conv_s uuid;
    conv_n uuid;
    conv_d uuid;
    lim jsonb := public._rate_limits();

    ok boolean;
    err text;
    det text;
    n int;
    n2 int;
    i int;
    v jsonb;
    rec record;
    tok text;
  begin
    -- ---------- setup (as admin) ----------
    select array_agg(gen_random_uuid()) into targets from generate_series(1, 30);

    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[rS, rD, rT, rA, rM, rM2] || targets) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[rS, rD, rT, rA, rM, rM2] || targets) as id;

    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '1 day'
    from unnest(array[rN, rB]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(array[rN, rB]) as id;

    update public.profiles
    set username = 'sec_' || left(replace(id::text, '-', ''), 12)
    where id in (select unnest(array[rS, rN, rD, rT, rA, rB, rM, rM2] || targets));

    -- Senders are connected to rT, so they're allowed to message.
    insert into public.connections (requester_id, addressee_id, status)
    values (rS, rT, 'accepted'), (rN, rT, 'accepted'), (rD, rT, 'accepted');

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rS, 'role', 'authenticated')::text, true);
    conv_s := public.get_or_create_direct_conversation(rT);
    perform set_config('request.jwt.claims', json_build_object('sub', rN, 'role', 'authenticated')::text, true);
    conv_n := public.get_or_create_direct_conversation(rT);
    perform set_config('request.jwt.claims', json_build_object('sub', rD, 'role', 'authenticated')::text, true);
    conv_d := public.get_or_create_direct_conversation(rT);
    reset role;

    -- =====================================================================
    -- R. Rate limits (M4)
    -- =====================================================================

    -- R1 (attack): an established account sends 31 messages in a minute. The
    -- first 30 go through; the 31st is refused with message_rate_limited.
    -- The first one is sent backdated a day, to check created_at is forced.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rS, 'role', 'authenticated')::text, true);
    n := 0;
    err := null;
    det := null;
    for i in 1..31 loop
      begin
        insert into public.messages (conversation_id, sender_id, body, created_at)
        values (conv_s, rS, 'hi ' || i, case when i = 1 then now() - interval '1 day' else now() end);
        n := n + 1;
      exception when others then
        err := coalesce(err, sqlerrm);
        get stacked diagnostics det = pg_exception_detail;
      end;
    end loop;
    reset role;
    ok := n = 30 and err = 'message_rate_limited' and det = 'minute'
          and (select count(*) from public.messages where sender_id = rS) = 30;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R1 31st message in a minute -> ' || coalesce(err || ' (' || det || ')', 'no error')
      || ', ' || n || ' sent';
    if not ok then fails := fails + 1; end if;

    -- R2: the backdated message was stamped with the real time.
    ok := not exists (select 1 from public.messages where sender_id = rS and created_at <> now());
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R2 client-supplied created_at is replaced with now()';
    if not ok then fails := fails + 1; end if;

    -- R3 (attack): a 1-day-old account gets the lower limit: 10, then refused.
    -- Backdating the 11th doesn't slip it under the per-minute count.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rN, 'role', 'authenticated')::text, true);
    n := 0;
    for i in 1..10 loop
      begin
        insert into public.messages (conversation_id, sender_id, body) values (conv_n, rN, 'new ' || i);
        n := n + 1;
      exception when others then null;
      end;
    end loop;
    err := null;
    begin
      insert into public.messages (conversation_id, sender_id, body, created_at)
      values (conv_n, rN, 'sneaky', now() - interval '10 minutes');
    exception when others then err := sqlerrm;
    end;
    reset role;
    ok := n = (lim ->> 'new_account_messages_per_minute')::int and err = 'message_rate_limited';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R3 new account: ' || n || ' sent, next (backdated) -> ' || coalesce(err, 'no error');
    if not ok then fails := fails + 1; end if;

    -- R4 (attack): the daily cap. rD already sent 499 messages today (and 600
    -- yesterday, which don't count). One more is fine; the next is refused.
    -- Fixtures are inserted as admin, which isn't limited.
    insert into public.messages (conversation_id, sender_id, body, created_at)
    select conv_d, rD, 'old ' || g, now() - interval '25 hours' from generate_series(1, 600) g;
    insert into public.messages (conversation_id, sender_id, body, created_at)
    select conv_d, rD, 'today ' || g, now() - interval '2 hours' from generate_series(1, 499) g;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rD, 'role', 'authenticated')::text, true);
    n := 0;
    err := null;
    det := null;
    for i in 500..501 loop
      begin
        insert into public.messages (conversation_id, sender_id, body) values (conv_d, rD, 'number ' || i);
        n := n + 1;
      exception when others then
        err := coalesce(err, sqlerrm);
        get stacked diagnostics det = pg_exception_detail;
      end;
    end loop;
    reset role;
    ok := n = 1 and err = 'message_rate_limited' and det = 'day';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R4 501st message in 24h -> ' || coalesce(err || ' (' || det || ')', 'no error')
      || '; messages older than 24h not counted';
    if not ok then fails := fails + 1; end if;

    -- R5 (attack): an established account sends 21 connection requests in a
    -- day. 20 go through; the 21st is refused with connection_rate_limited.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rA, 'role', 'authenticated')::text, true);
    n := 0;
    err := null;
    det := null;
    for i in 1..21 loop
      begin
        insert into public.connections (requester_id, addressee_id) values (rA, targets[i]);
        n := n + 1;
      exception when others then
        err := coalesce(err, sqlerrm);
        get stacked diagnostics det = pg_exception_detail;
      end;
    end loop;
    reset role;
    ok := n = (lim ->> 'connection_requests_per_day')::int
          and err = 'connection_rate_limited' and det = 'day'
          and (select count(*) from public.connection_request_log where user_id = rA) = n;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R5 21st connection request in a day -> ' || coalesce(err || ' (' || det || ')', 'no error')
      || ', ' || n || ' sent';
    if not ok then fails := fails + 1; end if;

    -- R6 (attack): cancel all 20 and try again. Still refused: the cap counts
    -- the log, not the (now deleted) requests.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rA, 'role', 'authenticated')::text, true);
    delete from public.connections where requester_id = rA;
    get diagnostics n = row_count;
    err := null;
    begin
      insert into public.connections (requester_id, addressee_id) values (rA, targets[25]);
    exception when others then err := sqlerrm;
    end;
    reset role;
    ok := n = 20 and err = 'connection_rate_limited';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R6 cancel ' || n || ' requests and resend -> ' || coalesce(err, 'no error');
    if not ok then fails := fails + 1; end if;

    -- R7: a 1-day-old account gets 5 requests. A failed insert (a duplicate)
    -- doesn't use one up.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rB, 'role', 'authenticated')::text, true);
    n := 0;
    n2 := 0;
    for i in 1..5 loop
      begin
        insert into public.connections (requester_id, addressee_id) values (rB, targets[i]);
        n := n + 1;
      exception when others then null;
      end;
      if i = 1 then
        begin
          insert into public.connections (requester_id, addressee_id) values (rB, targets[1]);
        exception when others then n2 := n2 + 1;
        end;
      end if;
    end loop;
    err := null;
    begin
      insert into public.connections (requester_id, addressee_id) values (rB, targets[6]);
    exception when others then err := sqlerrm;
    end;
    reset role;
    ok := n = (lim ->> 'new_account_connection_requests_per_day')::int and n2 = 1
          and err = 'connection_rate_limited';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R7 new account: ' || n || ' requests (duplicate not counted), 6th -> ' || coalesce(err, 'no error');
    if not ok then fails := fails + 1; end if;

    -- R8: rA is at the cap, but connecting in person (QR) still works in both
    -- directions, and isn't logged as a request.
    select count(*) into n2 from public.connection_request_log where user_id = rA;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rM, 'role', 'authenticated')::text, true);
    tok := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', rA, 'role', 'authenticated')::text, true);
    err := null;
    begin
      v := public.redeem_connect_token(tok, null, 43.6151, -116.2021, 15);
    exception when others then err := sqlerrm;
    end;
    ok := err is null and v ->> 'outcome' = 'created';
    tok := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', rM2, 'role', 'authenticated')::text, true);
    begin
      v := public.redeem_connect_token(tok, null, 43.6151, -116.2021, 15);
    exception when others then err := sqlerrm;
    end;
    reset role;
    ok := ok and err is null and v ->> 'outcome' = 'created'
          and (select count(*) from public.connections
               where rA in (requester_id, addressee_id) and (rM in (requester_id, addressee_id) or rM2 in (requester_id, addressee_id))
                 and status = 'accepted' and level = 'in_person') = 2
          and (select count(*) from public.connection_request_log where user_id = rA) = n2;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R8 in-person connect (both directions) not limited by the request cap'
      || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- R9: seed scripts (service role) and admin inserts aren't limited.
    perform set_config('role', 'service_role', true);
    err := null;
    begin
      insert into public.connections (requester_id, addressee_id) values (rA, targets[26]);
    exception when others then err := sqlerrm;
    end;
    reset role;
    begin
      insert into public.connections (requester_id, addressee_id) values (rA, targets[27]);
    exception when others then err := coalesce(err, sqlerrm);
    end;
    ok := err is null;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R9 service role / admin inserts not limited' || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- R10 (attack): clients can't read or reset the log, or call the helpers.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', rA, 'role', 'authenticated')::text, true);
    n := 0;
    begin
      delete from public.connection_request_log where user_id = rA;
    exception when others then n := n + 1;
    end;
    begin
      perform count(*) from public.connection_request_log;
    exception when others then n := n + 1;
    end;
    begin
      perform public._rate_limits();
    exception when others then n := n + 1;
    end;
    begin
      perform public._is_new_account(rA);
    exception when others then n := n + 1;
    end;
    reset role;
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    begin
      perform count(*) from public.connection_request_log;
    exception when others then n := n + 1;
    end;
    reset role;
    ok := n = 5 and (select count(*) from public.connection_request_log where user_id = rA) > 0;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  R10 log and helpers refused to clients (' || n || '/5)';
    if not ok then fails := fails + 1; end if;
  end;

  -- #####################################################################
  -- security/m5: S = suspended accounts can't write (item M5),
  -- #####################################################################
  reset role;
  declare
    -- S: suspension
    sS uuid := gen_random_uuid();    -- suspended (Terms accepted)
    sN uuid := gen_random_uuid();    -- suspended, hasn't accepted the current Terms
    sAdm uuid := gen_random_uuid();  -- suspended admin
    sF uuid := gen_random_uuid();    -- sS's connection; hosts eF / eF2
    sP uuid := gen_random_uuid();    -- sent sS a pending request
    sI uuid := gen_random_uuid();    -- met sS in person just now (undo window open)
    sO uuid := gen_random_uuid();    -- someone else; hosts eO
    sB uuid := gen_random_uuid();    -- blocked by sS
    sR1 uuid := gen_random_uuid();   -- old accounts that already reported eO
    sR2 uuid := gen_random_uuid();
    -- T: Terms
    tN uuid := gen_random_uuid();    -- only accepted an old Terms version
    tF uuid := gen_random_uuid();    -- tN's connection; hosts eT
    tOth uuid := gen_random_uuid();    -- someone else, sent tN a pending request
    tX uuid := gen_random_uuid();    -- target for tN's connection request

    conv_s uuid;
    conv_t uuid;
    eF uuid;    -- sF's event; sS tries to RSVP
    eF2 uuid;   -- sF's event; sS already going
    eS uuid;    -- sS's own event
    eO uuid;    -- sO's public event with 2 counted reports
    eT uuid;    -- tF's event; tN tries to RSVP
    c_in_person uuid;
    tok_o text;
    tok_to text;
    v_current text := public._current_terms_version();

    ok boolean;
    err text;
    n int;
    v jsonb;
  begin
    -- ---------- setup (as admin) ----------
    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(array[sS, sN, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tN, tF, tOth, tX]) as id;

    update public.profiles
    set username = 'm5_' || left(replace(id::text, '-', ''), 12), bio = 'Original bio'
    where id in (sS, sN, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tN, tF, tOth, tX);

    -- Everyone has accepted the current Terms except sN (never) and tN (an
    -- old version only).
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, v_current, now(), now()
    from unnest(array[sS, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tF, tOth, tX]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    values (tN, '2000-01-01', now() - interval '1 year', now() - interval '1 year');

    insert into public.app_admins (user_id) values (sAdm);

    insert into public.connections (requester_id, addressee_id, status) values
      (sS, sF, 'accepted'), (sP, sS, 'pending'),
      (tN, tF, 'accepted'), (tOth, tN, 'pending');
    v := public._connect_in_person(sS, sI, 'bump', 'Boise');
    c_in_person := (v ->> 'connection_id')::uuid;
    insert into public.user_blocks (blocker_id, blocked_id) values (sS, sB);

    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (sF, 'M5 F', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eF;
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (sF, 'M5 F2', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eF2;
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (sS, 'M5 S', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eS;
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (sO, 'M5 O', 43.6, -116.2, now() + interval '1 day', 'public') returning id into eO;
    insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
    values (tF, 'M5 T', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eT;
    insert into public.event_attendees (event_id, user_id) values (eF2, sS);
    insert into public.event_reports (event_id, reporter_id, reason) values (eO, sR1, 'spam'), (eO, sR2, 'spam');

    insert into storage.objects (bucket_id, name, owner) values ('avatars', sS || '/avatar.jpg', sS);

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
    conv_s := public.get_or_create_direct_conversation(sF);
    insert into public.messages (conversation_id, sender_id, body) values (conv_s, sS, 'before');
    perform set_config('request.jwt.claims', json_build_object('sub', sO, 'role', 'authenticated')::text, true);
    tok_o := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', tOth, 'role', 'authenticated')::text, true);
    tok_to := public.create_connect_token(43.61504, -116.20207, 15) ->> 'token';
    perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
    conv_t := public.get_or_create_direct_conversation(tF);
    reset role;

    -- Suspend (an admin's admin_set_account_status would also remove eS; a
    -- direct insert keeps eS around for S7).
    insert into public.account_restrictions (user_id, status, created_by)
    values (sS, 'suspended', sAdm), (sN, 'suspended', sAdm), (sAdm, 'suspended', sF);

    -- =====================================================================
    -- S. Suspended accounts can't write (M5)
    -- =====================================================================

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);

    -- S1 (attack): direct table inserts are refused with 42501:
    -- connection request, message, RSVP, profile row, avatar upload.
    n := 0;
    begin insert into public.connections (requester_id, addressee_id) values (sS, sO);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.messages (conversation_id, sender_id, body) values (conv_s, sS, 'hello?');
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.event_attendees (event_id, user_id) values (eF, sS);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.profiles (id) values (sS);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into storage.objects (bucket_id, name, owner) values ('avatars', sS || '/new.jpg', sS);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    ok := n = 5;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S1 suspended: request/message/RSVP/profile/avatar inserts refused (' || n || '/5)';
    if not ok then fails := fails + 1; end if;

    -- S2 (attack): direct updates change nothing: accept a pending request,
    -- edit the profile, mark a chat read, rename the avatar file.
    begin
      update public.connections set status = 'accepted' where requester_id = sP and addressee_id = sS;
    exception when others then null;  -- refused either way
    end;
    begin
      update public.profiles set bio = 'Changed while suspended' where id = sS;
    exception when others then null;  -- refused either way
    end;
    begin
      update public.conversation_participants set last_read_at = now() + interval '1 day'
      where conversation_id = conv_s and user_id = sS;
    exception when others then null;  -- refused either way
    end;
    begin
      update storage.objects set name = sS || '/renamed.jpg' where bucket_id = 'avatars' and name = sS || '/avatar.jpg';
    exception when others then null;  -- refused either way
    end;
    reset role;
    ok := (select status from public.connections where requester_id = sP and addressee_id = sS) = 'pending'
          and (select bio from public.profiles where id = sS) = 'Original bio'
          and (select last_read_at from public.conversation_participants
               where conversation_id = conv_s and user_id = sS) <= now()
          and exists (select 1 from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S2 suspended: accept request / edit profile / mark read / rename avatar change nothing';
    if not ok then fails := fails + 1; end if;

    -- S3 (attack): direct deletes remove nothing: a connection, their RSVP,
    -- their own event, their avatar.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
    begin
      delete from public.connections where requester_id = sS and addressee_id = sF;
    exception when others then null;  -- refused either way
    end;
    begin
      delete from public.event_attendees where event_id = eF2 and user_id = sS;
    exception when others then null;  -- refused either way
    end;
    begin
      delete from public.events where id = eS;
    exception when others then null;  -- refused either way
    end;
    begin
      delete from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg';
    exception when others then null;  -- refused either way
    end;
    reset role;
    ok := exists (select 1 from public.connections where requester_id = sS and addressee_id = sF)
          and exists (select 1 from public.event_attendees where event_id = eF2 and user_id = sS)
          and exists (select 1 from public.events where id = eS)
          and exists (select 1 from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S3 suspended: delete connection / RSVP / own event / avatar remove nothing';
    if not ok then fails := fails + 1; end if;

    -- S4 (attack): the RPCs that had no check: block, undo, map location, QR code.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
    n := 0;
    if public.block_user(sO) ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
    if public.undo_in_person_connection(c_in_person) ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
    begin perform public.update_my_location(43.6, -116.2);
    exception when others then if sqlerrm = 'account_suspended' then n := n + 1; end if; end;
    begin perform public.create_connect_token(43.61504, -116.20207, 15);
    exception when others then if sqlerrm = 'account_suspended' then n := n + 1; end if; end;
    reset role;
    ok := n = 4
          and not exists (select 1 from public.user_blocks where blocker_id = sS and blocked_id = sO)
          and (select level::text from public.connections where id = c_in_person) = 'in_person'
          and not exists (select 1 from public.user_locations where user_id = sS)
          and not exists (select 1 from public.connect_tokens where user_id = sS);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S4 suspended: block / undo / update_my_location / create_connect_token refused (' || n || '/4)';
    if not ok then fails := fails + 1; end if;

    -- S5 (attack): the RPCs that already checked still do: start a chat,
    -- bump, scan a QR code, create and edit an event.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
    n := 0;
    begin perform public.get_or_create_direct_conversation(sO);
    exception when others then n := n + 1; end;
    if public.submit_bump(43.6, -116.2, 10, null) ->> 'status' = 'no_match' then n := n + 1; end if;
    if public.redeem_connect_token(tok_o, null, 43.6151, -116.2021, 15) ->> 'outcome' = 'unavailable' then n := n + 1; end if;
    if public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections')
       ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
    if public.update_event(eS, 'Changed', null, now() + interval '1 day', null, 'connections')
       ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
    reset role;
    ok := n = 5
          and not exists (select 1 from public.bump_events where user_id = sS)
          and not exists (select 1 from public.connections
                          where (requester_id = sS and addressee_id = sO) or (requester_id = sO and addressee_id = sS))
          and (select title from public.events where id = eS) = 'M5 S';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S5 suspended: chat / bump / QR / create + edit event still refused (' || n || '/5)';
    if not ok then fails := fails + 1; end if;

    -- S6 (attack): a suspended admin has no admin power (RPCs or the
    -- admin delete policy).
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', sAdm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
    n := 0;
    begin perform public.admin_set_event_status(eO, 'removed', null);
    exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
    begin perform public.admin_set_account_status(sS, null, null);
    exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
    begin perform * from public.admin_list_user_reports('open');
    exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
    begin
      delete from public.events where id = eO;
    exception when others then null;  -- refused either way
    end;
    reset role;
    ok := n = 3
          and (select status from public.events where id = eO) = 'active'
          and exists (select 1 from public.account_restrictions where user_id = sS);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S6 suspended admin: admin RPCs refused, can''t delete events (' || n || '/3)';
    if not ok then fails := fails + 1; end if;

    -- S7: allowed while suspended: read own profile, restriction, connections,
    -- messages; unblock; report a user; report an event.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
    n := 0;
    if (select count(*) from public.profiles where id = sS) = 1 then n := n + 1; end if;
    if (select count(*) from public.account_restrictions where user_id = sS) = 1 then n := n + 1; end if;
    if (select count(*) from public.connections where requester_id = sS or addressee_id = sS) >= 2 then n := n + 1; end if;
    if (select count(*) from public.messages where sender_id = sS) = 1 then n := n + 1; end if;
    if public.unblock_user(sB) ->> 'outcome' = 'unblocked' then n := n + 1; end if;
    if public.report_user(sO, 'profile', null, 'spam', null) ->> 'outcome' = 'reported' then n := n + 1; end if;
    v := public.report_event(eO, 'spam', null);
    if v ->> 'outcome' = 'reported' then n := n + 1; end if;
    reset role;
    ok := n = 7
          and not exists (select 1 from public.user_blocks where blocker_id = sS and blocked_id = sB)
          and exists (select 1 from public.user_reports where reporter_id = sS and reported_user_id = sO)
          and exists (select 1 from public.event_reports where reporter_id = sS and event_id = eO);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S7 suspended can: read own data, unblock, report a user, report an event (' || n || '/7)';
    if not ok then fails := fails + 1; end if;

    -- S8 (attack): a suspended account's event report doesn't count toward
    -- auto-hide (eO had 2 counted reports; 3 hides it).
    ok := (v ->> 'hidden')::boolean = false and (select status from public.events where id = eO) = 'active';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S8 suspended reporter doesn''t count toward auto-hide (hidden=' || coalesce(v ->> 'hidden', 'null') || ')';
    if not ok then fails := fails + 1; end if;

    -- S9: a suspended account that hasn't accepted the current Terms can.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', sN, 'role', 'authenticated')::text, true);
    v := public.accept_terms(v_current, true);
    reset role;
    ok := v ->> 'outcome' = 'accepted'
          and exists (select 1 from public.user_consents where user_id = sN and terms_version = v_current);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S9 suspended can accept the Terms -> ' || coalesce(v ->> 'outcome', 'null');
    if not ok then fails := fails + 1; end if;

    -- S10: deleting the account still works (the delete-account Edge Function
    -- deletes the auth user with the service role; no user JWT).
    perform set_config('request.jwt.claims', '', true);
    err := null;
    begin
      delete from auth.users where id = sS;
    exception when others then err := sqlerrm;
    end;
    ok := err is null
          and not exists (select 1 from public.profiles where id = sS)
          and not exists (select 1 from public.connections where requester_id = sS or addressee_id = sS)
          and not exists (select 1 from public.messages where sender_id = sS);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  S10 suspended account can still be deleted' || coalesce(' (error ' || err || ')', '');
    if not ok then fails := fails + 1; end if;

    -- =====================================================================
    -- T. Current Terms required (M5)
    -- =====================================================================
    -- tN accepted an old version only, so they count as "not accepted".

    -- T1 (attack): message, request, accept, RSVP through the tables.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
    n := 0;
    begin insert into public.messages (conversation_id, sender_id, body) values (conv_t, tN, 'hi');
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.connections (requester_id, addressee_id) values (tN, tX);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.event_attendees (event_id, user_id) values (eT, tN);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin
      update public.connections set status = 'accepted' where requester_id = tOth and addressee_id = tN;
    exception when others then null;  -- refused either way
    end;
    reset role;
    ok := n = 3
          and not exists (select 1 from public.messages where sender_id = tN)
          and not exists (select 1 from public.connections where requester_id = tN and addressee_id = tX)
          and not exists (select 1 from public.event_attendees where event_id = eT and user_id = tN)
          and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'pending';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T1 no current Terms: message/request/RSVP refused (' || n || '/3), accept changes nothing';
    if not ok then fails := fails + 1; end if;

    -- T2 (attack): create an event, make a QR code, bump, scan someone's code.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
    n := 0;
    v := public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections');
    if v ->> 'outcome' = 'not_allowed' and v ->> 'reason' = 'terms_not_accepted' then n := n + 1; end if;
    begin perform public.create_connect_token(43.61504, -116.20207, 15);
    exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
    begin perform public.submit_bump(43.6, -116.2, 10, null);
    exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
    begin perform public.redeem_connect_token(tok_to, null, 43.6151, -116.2021, 15);
    exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
    reset role;
    ok := n = 4
          and not exists (select 1 from public.events where creator_id = tN)
          and not exists (select 1 from public.connect_tokens where user_id = tN)
          and not exists (select 1 from public.bump_events where user_id = tN)
          and (select used_at from public.connect_tokens where token = tok_to) is null
          and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'pending';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T2 no current Terms: create event / QR code / bump / scan refused (' || n || '/4)';
    if not ok then fails := fails + 1; end if;

    -- T3: connecting in person with someone who hasn't accepted is
    -- 'unavailable' (their consent state isn't revealed).
    v := public._connect_in_person(tOth, tN, 'qr', null);
    ok := v ->> 'outcome' = 'unavailable'
          and (select level::text from public.connections where requester_id = tOth and addressee_id = tN) = 'acquaintance';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T3 other person without current Terms -> ' || coalesce(v ->> 'outcome', 'null');
    if not ok then fails := fails + 1; end if;

    -- T4 (attack): they can't fake consent by writing the table.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
    n := 0;
    begin
      insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
      values (tN, v_current, now(), now());
    exception when others then n := n + 1;
    end;
    begin
      update public.user_consents set terms_version = v_current where user_id = tN;
    exception when others then null;  -- refused either way
    end;
    reset role;
    ok := n = 1 and not public.has_accepted_current_terms(tN);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T4 writing user_consents directly is refused';
    if not ok then fails := fails + 1; end if;

    -- T5: accept_terms works, then everything above goes through.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
    n := 0;
    if public.accept_terms(v_current, true) ->> 'outcome' = 'accepted' then n := n + 1; end if;
    begin
      insert into public.messages (conversation_id, sender_id, body) values (conv_t, tN, 'hi');
      n := n + 1;
    exception when others then null;
    end;
    begin
      insert into public.connections (requester_id, addressee_id) values (tN, tX);
      n := n + 1;
    exception when others then null;
    end;
    begin
      insert into public.event_attendees (event_id, user_id) values (eT, tN);
      n := n + 1;
    exception when others then null;
    end;
    update public.connections set status = 'accepted' where requester_id = tOth and addressee_id = tN;
    if public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections')
       ->> 'outcome' = 'created' then n := n + 1; end if;
    if public.create_connect_token(43.61504, -116.20207, 15) ->> 'outcome' = 'ok' then n := n + 1; end if;
    if public.redeem_connect_token(tok_to, null, 43.6151, -116.2021, 15) ->> 'outcome' = 'upgraded' then n := n + 1; end if;
    reset role;
    ok := n = 7
          and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'accepted'
          and (select level::text from public.connections where requester_id = tOth and addressee_id = tN) = 'in_person';
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T5 after accept_terms: message/request/RSVP/accept/event/QR all work (' || n || '/7)';
    if not ok then fails := fails + 1; end if;

    -- T6 (attack): anon can't call the helper.
    perform set_config('role', 'anon', true);
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    n := 0;
    begin perform public.has_accepted_current_terms(tN);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin perform public._require_can_connect();
    exception when others then n := n + 1; end;
    reset role;
    ok := n = 2;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  T6 anon can''t call has_accepted_current_terms / the trigger function (' || n || '/2)';
    if not ok then fails := fails + 1; end if;
  end;

  -- #####################################################################
  -- security/m6: U = website waitlist (item M6).
  -- #####################################################################
  reset role;
  declare
    ok boolean;
    err text;
    n int;
    v jsonb;
    bad text;
  begin
    -- ---------- U: waitlist (M6) ----------
    -- All U tests run as the website does: the anon role, no user.
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);

    -- U1 (attack): a direct insert of junk is rejected by the email check.
    perform set_config('role', 'anon', true);
    n := 0;
    foreach bad in array array[
      'not-an-email', 'a@b', '@example.com', 'a@@example.com', 'a b@example.com',
      'a@example.com' || chr(10) || 'x', '', repeat('a', 250) || '@example.com'
    ] loop
      begin
        insert into public.waitlist (email) values (bad);
      exception when others then
        if sqlstate = '23514' then n := n + 1; end if;
      end;
    end loop;
    reset role;
    ok := n = 8 and not exists (select 1 from public.waitlist where email like '%example.com%');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U1 direct insert of 8 bad emails rejected by the check (' || n || '/8)';
    if not ok then fails := fails + 1; end if;

    -- U2 (attack): the RPC rejects the same junk (and null) with invalid_email.
    perform set_config('role', 'anon', true);
    n := 0;
    foreach bad in array array[
      'not-an-email', 'a@b', '@example.com', 'a@@example.com', 'a b@example.com',
      'a@example.com' || chr(10) || 'x', '', repeat('a', 250) || '@example.com'
    ] loop
      begin
        perform public.join_waitlist(bad);
      exception when others then
        if sqlstate = '22023' and sqlerrm = 'invalid_email' then n := n + 1; end if;
      end;
    end loop;
    begin
      perform public.join_waitlist(null);
    exception when others then
      if sqlerrm = 'invalid_email' then n := n + 1; end if;
    end;
    reset role;
    ok := n = 9 and not exists (select 1 from public.waitlist where email like '%example.com%');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U2 join_waitlist rejects 8 bad emails + null with invalid_email (' || n || '/9)';
    if not ok then fails := fails + 1; end if;

    -- U3: a good email joins, stored trimmed and lower-cased.
    perform set_config('role', 'anon', true);
    v := public.join_waitlist('  New.Person@Example.COM ');
    reset role;
    ok := v = '{"ok": true}'::jsonb
          and (select count(*) from public.waitlist where email = 'new.person@example.com') = 1;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U3 join_waitlist adds a good email, lower-cased and trimmed';
    if not ok then fails := fails + 1; end if;

    -- U4 (attack): joining again (any case) answers exactly the same, no
    -- error, and doesn't add a row, so it can't tell you who's on the list.
    perform set_config('role', 'anon', true);
    err := null;
    begin
      v := public.join_waitlist('new.person@example.com');
      v := v || public.join_waitlist('NEW.PERSON@example.com');
    exception when others then err := sqlstate || ' ' || sqlerrm;
    end;
    reset role;
    ok := err is null and v = '{"ok": true}'::jsonb
          and (select count(*) from public.waitlist where lower(email) = 'new.person@example.com') = 1;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U4 duplicate join (same / different case) returns ok, no error, still 1 row'
      || coalesce(' [' || err || ']', '');
    if not ok then fails := fails + 1; end if;

    -- U5: a direct insert with capitals is lower-cased by the trigger too.
    perform set_config('role', 'anon', true);
    insert into public.waitlist (email) values (' Direct@Example.com');
    reset role;
    ok := exists (select 1 from public.waitlist where email = 'direct@example.com');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U5 direct insert is stored lower-cased (trigger)';
    if not ok then fails := fails + 1; end if;

    -- U6 (attack): anon and signed-in users can't read, change, or delete the list.
    n := 0;
    perform set_config('role', 'anon', true);
    begin perform count(*) from public.waitlist;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin update public.waitlist set email = 'x@example.com';
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin delete from public.waitlist;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
    begin perform count(*) from public.waitlist;
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.waitlist (email) values ('signed.in@example.com');
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    ok := n = 5 and (select count(*) from public.waitlist where email like '%example.com') = 2;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U6 anon can''t select/update/delete; authenticated can''t select/insert (' || n || '/5)';
    if not ok then fails := fails + 1; end if;

    -- U7 (attack): internal trigger function isn't callable; join_waitlist
    -- is granted to anon only (not public / authenticated).
    ok := not has_function_privilege('anon', 'public._waitlist_normalize_email()', 'execute')
          and not has_function_privilege('authenticated', 'public._waitlist_normalize_email()', 'execute')
          and has_function_privilege('anon', 'public.join_waitlist(text)', 'execute')
          and not has_function_privilege('authenticated', 'public.join_waitlist(text)', 'execute');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U7 function grants: helper none, join_waitlist anon only';
    if not ok then fails := fails + 1; end if;

    -- U8: rehearse step 2 (pending migration) inside this rolled-back test:
    -- after it, a direct anon insert is refused but join_waitlist still works.
    drop policy if exists "Anyone can join the waitlist" on public.waitlist;
    revoke insert on public.waitlist from anon, authenticated;
    perform set_config('role', 'anon', true);
    n := 0;
    begin insert into public.waitlist (email) values ('after.step2@example.com');
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    begin insert into public.waitlist (email) values ('new.person@example.com');
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    v := public.join_waitlist('Step2.Rpc@example.com');
    reset role;
    ok := n = 2 and v = '{"ok": true}'::jsonb
          and exists (select 1 from public.waitlist where email = 'step2.rpc@example.com')
          and not exists (select 1 from public.waitlist where email = 'after.step2@example.com');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  U8 after step 2: direct insert refused (no 23505 leak), RPC still works (' || n || '/2)';
    if not ok then fails := fails + 1; end if;
  end;

  -- #####################################################################
  -- security/m8: V = Discover paging RPC (item M8).
  -- #####################################################################
  reset role;
  declare
    ok boolean;
    err text;
    n int;
    n2 int;
    cur text;
    page_ids uuid[];
    seen uuid[] := '{}';
    prev_cursor text;
    me uuid := gen_random_uuid();
    i_blocked uuid := gen_random_uuid();
    blocked_me uuid := gen_random_uuid();
    suspended uuid := gen_random_uuid();
    no_username uuid := gen_random_uuid();
    late uuid := gen_random_uuid();
    others uuid[] := '{}';
    visible uuid[];
    cols text[];
  begin
    -- ---------- V: Discover paging (M8) ----------
    -- 35 ordinary users plus the special cases. Their created_at is pushed a
    -- day into the future so they're the first pages even on a project that
    -- already has real profiles; ordering is newest first.
    for n in 1..35 loop
      others := others || gen_random_uuid();
    end loop;

    insert into auth.users (id, email, aud, role, created_at)
    select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
    from unnest(others || array[me, i_blocked, blocked_me, suspended, no_username]) as id;
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    select id, public._current_terms_version(), now(), now()
    from unnest(others || array[me, i_blocked, blocked_me, suspended, no_username]) as id;

    update public.profiles p
    set username = 'm8_' || left(replace(p.id::text, '-', ''), 12),
        created_at = now() + interval '1 day' + (o.ord || ' seconds')::interval
    from unnest(others || array[me, i_blocked, blocked_me, suspended, no_username])
      with ordinality as o(id, ord)
    where p.id = o.id;
    update public.profiles set username = null where id = no_username;
    update public.profiles set interests = array['Fintech'], full_name = 'Zebra 100% Farms'
    where id = others[7];
    update public.profiles set interests = array['SaaS'] where id = others[8];

    insert into public.user_blocks (blocker_id, blocked_id) values
      (me, i_blocked),
      (blocked_me, me);
    insert into public.account_restrictions (user_id, status, reason)
      values (suspended, 'suspended', 'M8 test');

    -- The test users `me` should see: the 35 ordinary ones.
    visible := others;

    perform set_config('request.jwt.claims', json_build_object('sub', me, 'role', 'authenticated')::text, true);

    -- V1 (attack): asking for 1000 rows still returns 30.
    perform set_config('role', 'authenticated', true);
    select count(*) into n from public.discover_profiles(null, 1000);
    reset role;
    ok := n = 30;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V1 p_limit 1000 returns 30 rows (' || n || ')';
    if not ok then fails := fails + 1; end if;

    -- V2: p_limit null / 0 / negative is clamped to 30 / 1 / 1, not an error
    -- and never "unlimited".
    perform set_config('role', 'authenticated', true);
    select count(*) into n from public.discover_profiles(null, null);
    select count(*) into n2 from public.discover_profiles(null, 0);
    ok := n = 30 and n2 = 1;
    select count(*) into n2 from public.discover_profiles(null, -5);
    reset role;
    ok := ok and n2 = 1;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V2 p_limit null -> 30, 0 and -5 -> 1';
    if not ok then fails := fails + 1; end if;

    -- V3 (attack): walking every page never shows someone I blocked, someone
    -- who blocked me, a suspended account, a profile with no username, or me.
    -- Also: every visible test user shows up exactly once (keyset paging).
    perform set_config('role', 'authenticated', true);
    cur := null;
    n := 0;
    loop
      select array_agg(d.id order by d.ord), (array_agg(d.cursor order by d.ord desc))[1]
        into page_ids, prev_cursor
      from public.discover_profiles(cur, 30) with ordinality as d(id, username, full_name,
        avatar_url, bio, interests, business_stage, city, cursor, ord);
      exit when page_ids is null;
      seen := seen || page_ids;
      cur := prev_cursor;
      n := n + 1;
      exit when n > 1000; -- safety net on a big project
    end loop;
    reset role;
    ok := not (seen && array[me, i_blocked, blocked_me, suspended, no_username]);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V3 blocked (both ways), suspended, no-username and self never returned';
    if not ok then fails := fails + 1; end if;

    ok := (select count(*) from unnest(seen) s where s = any (visible)) = 35
          and (select count(distinct s) from unnest(seen) s) = cardinality(seen);
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V4 all pages together: each of the 35 visible test users exactly once, no repeats ('
      || cardinality(seen) || ' rows, ' || n || ' pages)';
    if not ok then fails := fails + 1; end if;

    -- V5: someone signing up between pages doesn't shift page 2 (the
    -- weakness of offset paging): page 2 continues right after page 1.
    perform set_config('role', 'authenticated', true);
    select array_agg(d.id order by d.ord), (array_agg(d.cursor order by d.ord desc))[1]
      into page_ids, cur
    from public.discover_profiles(null, 10) with ordinality as d(id, username, full_name,
      avatar_url, bio, interests, business_stage, city, cursor, ord);
    reset role;
    insert into auth.users (id, email, aud, role) values
      (late, late || '@test.bolas.invalid', 'authenticated', 'authenticated');
    update public.profiles
    set username = 'm8_late', created_at = now() + interval '2 days'
    where id = late;
    perform set_config('role', 'authenticated', true);
    select array_agg(d.id order by d.ord) into seen
    from public.discover_profiles(cur, 10) with ordinality as d(id, username, full_name,
      avatar_url, bio, interests, business_stage, city, cursor, ord);
    reset role;
    ok := page_ids = array(select others[k] from generate_series(35, 26, -1) k)
          and seen = array(select others[k] from generate_series(25, 16, -1) k)
          and not (late = any (seen));
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V5 keyset: page 2 follows page 1 exactly, a new signup in between doesn''t shift it';
    if not ok then fails := fails + 1; end if;

    -- V6 (attack): a forged or garbage cursor is refused with invalid_cursor.
    n := 0;
    perform set_config('role', 'authenticated', true);
    foreach cur in array array['garbage', '2026-01-01T00:00:00Z', '|' || me, 'x|y',
                               '2026-01-01T00:00:00Z|not-a-uuid'] loop
      begin
        perform * from public.discover_profiles(cur, 30);
      exception when others then
        if sqlstate = '22023' and sqlerrm = 'invalid_cursor' then n := n + 1; end if;
      end;
    end loop;
    reset role;
    ok := n = 5;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V6 5 malformed cursors rejected with invalid_cursor (' || n || '/5)';
    if not ok then fails := fails + 1; end if;

    -- V7: search matches an interest and a name, case-insensitive; "%" and
    -- "_" are plain text, not wildcards (so "%" alone doesn't match everyone).
    perform set_config('role', 'authenticated', true);
    select array_agg(d.id order by d.id) into seen from public.discover_profiles(null, 1000, 'fin')
      d where d.id = any (visible);
    ok := seen = array[others[7]];
    select array_agg(d.id) into seen from public.discover_profiles(null, 1000, 'ZEBRA 100%') d;
    ok := ok and seen = array[others[7]];
    select count(*) into n from public.discover_profiles(null, 1000, '%') d where d.id = any (visible);
    select count(*) into n2 from public.discover_profiles(null, 1000, 'm8_') d;
    reset role;
    ok := ok and n = 1 and n2 = 30;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V7 search: interest + name match, "%" is literal (' || n || ' hit), username match capped at 30';
    if not ok then fails := fails + 1; end if;

    -- V8 (attack): search can't be used to reach blocked / suspended people.
    -- (Usernames looked up first, as the owner: RLS already hides them from me.)
    select array_agg(username order by array_position(array[i_blocked, blocked_me, suspended], id))
      into cols from public.profiles where id in (i_blocked, blocked_me, suspended);
    perform set_config('role', 'authenticated', true);
    select count(*) into n from public.discover_profiles(null, 30, cols[1]);
    select count(*) into n2 from public.discover_profiles(null, 30, cols[2]);
    ok := n = 0 and n2 = 0;
    select count(*) into n from public.discover_profiles(null, 30, cols[3]);
    reset role;
    ok := ok and n = 0 and cardinality(cols) = 3;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V8 searching the exact username of a blocked (both ways) / suspended user finds nothing';
    if not ok then fails := fails + 1; end if;

    -- V9 (attack): a suspended caller gets no rows.
    perform set_config('request.jwt.claims', json_build_object('sub', suspended, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    select count(*) into n from public.discover_profiles(null, 30);
    reset role;
    ok := n = 0;
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V9 suspended caller gets 0 rows (' || n || ')';
    if not ok then fails := fails + 1; end if;

    -- V10 (attack): anon can't call it; a signed-in role with no user id is
    -- refused; only the Discover columns come back (no location_sharing,
    -- notifications_enabled, updated_at...).
    n := 0;
    perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
    perform set_config('role', 'anon', true);
    begin perform * from public.discover_profiles(null, 30);
    exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
    reset role;
    perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
    begin perform * from public.discover_profiles(null, 30);
    exception when others then if sqlstate = '42501' and sqlerrm = 'not_authenticated' then n := n + 1; end if; end;
    reset role;
    select array_agg(a.attname::text order by a.attnum) into cols
    from pg_proc pr, unnest(pr.proargnames, pr.proargmodes) with ordinality as a(attname, mode, attnum)
    where pr.oid = 'public.discover_profiles(text, integer, text)'::regprocedure and a.mode = 't';
    ok := n = 2
          and cols = array['id', 'username', 'full_name', 'avatar_url', 'bio', 'interests',
                           'business_stage', 'city', 'cursor']
          and not has_function_privilege('anon', 'public.discover_profiles(text, integer, text)', 'execute')
          and has_function_privilege('authenticated', 'public.discover_profiles(text, integer, text)', 'execute');
    report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
      || '  V10 anon + no-user refused (' || n || '/2); returns only the 9 Discover columns';
    if not ok then fails := fails + 1; end if;
  end;

  reset role;
  -- Always roll back: nothing from this run is kept.
  raise exception '%', E'TEST RESULTS: ' || fails || ' failed (rolled back, nothing saved)' || report
    || E'\n' || case when fails = 0 then 'ALL PASSED' else fails || ' FAILED' end;
end;
$tests$;
