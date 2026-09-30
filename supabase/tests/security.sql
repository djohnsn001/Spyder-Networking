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
-- Sections: C = forged connections (items C1, C2).

do $tests$
declare
  -- Connections
  cA uuid := gen_random_uuid();   -- attacker / requester
  cB uuid := gen_random_uuid();   -- addressee
  cC uuid := gen_random_uuid();   -- innocent third user
  cD uuid := gen_random_uuid();   -- for a brand-new in-person connect

  report text := '';
  fails int := 0;
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
  tok := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', cC, 'role', 'authenticated')::text, true);
  v := public.redeem_connect_token(tok, 'Boise');
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
