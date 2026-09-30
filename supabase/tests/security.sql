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
-- Sections: Q = QR codes only work when both phones are together (item H2).

do $tests$
declare
  -- QR distance
  qA uuid := gen_random_uuid();   -- shows codes (Boise)
  qB uuid := gen_random_uuid();   -- scans next to qA
  qC uuid := gen_random_uuid();   -- scans from 5 km away (a shared screenshot)

  report text := '';
  fails int := 0;
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
