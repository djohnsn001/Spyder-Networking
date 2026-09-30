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
-- Sections: M = admin power needs two-step verification (item H4).

do $tests$
declare
  -- Admin MFA
  mA uuid := gen_random_uuid();   -- on the admin list
  mU uuid := gen_random_uuid();   -- normal user
  mS uuid := gen_random_uuid();   -- suspended user (only admins can see them)
  eH uuid;                        -- a hidden event hosted by mU

  report text := '';
  fails int := 0;
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
