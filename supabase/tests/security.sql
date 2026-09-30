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
-- Sections: R = rate limits on messages and connection requests (item M4).

do $tests$
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

  report text := '';
  fails int := 0;
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

  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '1 day'
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
  tok := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', rA, 'role', 'authenticated')::text, true);
  err := null;
  begin
    v := public.redeem_connect_token(tok, null);
  exception when others then err := sqlerrm;
  end;
  ok := err is null and v ->> 'outcome' = 'created';
  tok := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', rM2, 'role', 'authenticated')::text, true);
  begin
    v := public.redeem_connect_token(tok, null);
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

  -- ---------- report ----------
  raise exception '%', E'TEST RESULTS: ' || fails || ' failed (rolled back, nothing saved)' || report;
end
$tests$;
