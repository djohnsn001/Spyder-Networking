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
-- Sections: U = website waitlist (item M6).

do $tests$
declare
  report text := '';
  fails int := 0;
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

  -- ---------- report ----------
  raise exception '%', E'TEST RESULTS: ' || fails || ' failed (rolled back, nothing saved)' || report;
end
$tests$;
