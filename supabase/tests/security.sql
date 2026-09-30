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
-- Sections: H = connect links preview before connecting (item H1).

do $tests$
declare
  -- Connect-link preview
  hA uuid := gen_random_uuid();   -- shows a code
  hB uuid := gen_random_uuid();   -- opens a link to it
  hC uuid := gen_random_uuid();   -- hammers the preview (rate limit)
  hX uuid := gen_random_uuid();   -- blocked hA

  report text := '';
  fails int := 0;
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

  update public.profiles
  set username = 'sec_' || left(replace(id::text, '-', ''), 12)
  where id in (hA, hB, hC, hX);

  -- =====================================================================
  -- H. Connect links preview before connecting (H1)
  -- =====================================================================

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', hA, 'role', 'authenticated')::text, true);
  tok := public.create_connect_token() ->> 'token';

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
  v := public.redeem_connect_token(tok, null);
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
  v := public.create_connect_token();
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
  tok := public.create_connect_token() ->> 'token';
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
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
