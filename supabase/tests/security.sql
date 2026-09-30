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
-- Sections: L = profile field limits (item M2).

do $tests$
declare
  -- Profile limits
  lA uuid := gen_random_uuid();   -- edits their own profile
  lB uuid := gen_random_uuid();   -- another user
  all12 text := 'array[''SaaS'', ''AI / ML'', ''E-commerce'', ''Marketplace'', ''Fintech'', ''Consumer'', '
             || '''Hardware'', ''Health'', ''Education'', ''Social'', ''Sustainability'', ''Creator tools'']';

  report text := '';
  fails int := 0;
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
