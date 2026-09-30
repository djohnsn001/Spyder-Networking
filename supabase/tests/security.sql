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
-- Sections: V = Discover paging RPC (item M8).

do $tests$
declare
  report text := '';
  fails int := 0;
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

  raise exception '%', E'TEST RESULTS (everything rolled back)' || report
    || E'\n' || case when fails = 0 then 'ALL PASSED' else fails || ' FAILED' end;
end;
$tests$;
