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
-- Sections: P = profile photo URLs (item H5).

do $tests$
declare
  -- Profile photos
  pA uuid := gen_random_uuid();   -- attacker, editing their own profile
  pB uuid := gen_random_uuid();   -- another user
  -- Production base; public.avatar_url_allowed() accepts it in every database.
  avatars text := 'https://fhevoocpcnrjxyjvitai.supabase.co/storage/v1/object/public/avatars/';
  own_url text;

  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  n int;
  stored text;
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
