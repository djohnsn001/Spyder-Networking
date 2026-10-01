-- Looking For tags, suggested matches, and the premium tag filter
-- (migration 20260930020000_looking_for_tags.sql). Plain SQL, same style as
-- legal_compliance.sql.
--
-- Everything happens inside one DO block that ALWAYS ends by raising an
-- exception, which rolls back every test user and row it created. The
-- exception message is the test report: look for "TEST RESULTS" and any
-- FAIL lines. Run it on the DEV project:
--
--   npx supabase db query --linked -f supabase/tests/looking_for.sql
--
-- Sections: T = 3-tag limit and timestamps, P = premium flag attacks,
-- R = direct-read attacks, S = suggested matches (pairing, exclusions,
-- ranking, stale), F = premium tag filter, V = reading and confirming tags.

do $tests$
declare
  a uuid := gen_random_uuid();        -- the viewer: hiring + looking_for_partners, Boise
  b_same uuid := gen_random_uuid();   -- open_to_work, same city (" boise")
  g_mutual uuid := gen_random_uuid(); -- open_to_work, Nampa, 1 mutual with a
  f_stale uuid := gen_random_uuid();  -- open_to_work, Boise, 1 mutual, tags 100 days old
  p_partner uuid := gen_random_uuid();-- looking_for_partners (symmetric pair)
  e_nomatch uuid := gen_random_uuid();-- hiring (doesn't pair with hiring)
  blk uuid := gen_random_uuid();      -- open_to_work, blocked by a
  blk_by uuid := gen_random_uuid();   -- open_to_work, blocked a
  ip uuid := gen_random_uuid();       -- open_to_work, already met a in person
  acq uuid := gen_random_uuid();      -- open_to_work, acquaintance of a (still suggested)
  sus uuid := gen_random_uuid();      -- open_to_work, suspended
  m uuid := gen_random_uuid();        -- no tags; the mutual friend
  test_ids uuid[];
  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  n int;
  ids uuid[];
  rec record;
  ts timestamptz;
begin
  test_ids := array[a, b_same, g_mutual, f_stale, p_partner, e_nomatch, blk, blk_by, ip, acq, sus, m];

  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
  from unnest(test_ids) as id;

  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  select id, public._current_terms_version(), now(), now()
  from unnest(test_ids) as id;

  update public.profiles
  set username = 'lf_' || left(replace(id::text, '-', ''), 12)
  where id = any (test_ids);

  update public.profiles set city = 'Boise' where id in (a, f_stale);
  update public.profiles set city = ' boise' where id = b_same;
  update public.profiles set city = 'Nampa' where id = g_mutual;
  update public.profiles set city = 'Meridian' where id = p_partner;

  -- Server-side writes: the guard stamps now() when no time is given.
  update public.profiles set looking_for = array['hiring', 'looking_for_partners'] where id = a;
  update public.profiles set looking_for = array['open_to_work']
    where id in (b_same, g_mutual, blk, blk_by, ip, acq, sus);
  update public.profiles set looking_for = array['looking_for_partners'] where id = p_partner;
  update public.profiles set looking_for = array['hiring'] where id = e_nomatch;
  update public.profiles
    set looking_for = array['open_to_work'], tags_updated_at = now() - interval '100 days'
    where id = f_stale;

  insert into public.user_blocks (blocker_id, blocked_id) values (a, blk), (blk_by, a);
  insert into public.account_restrictions (user_id, status) values (sus, 'suspended');

  perform public._connect_in_person(a, ip, 'qr', null);
  perform public._connect_in_person(a, m, 'qr', null);
  perform public._connect_in_person(m, g_mutual, 'qr', null);
  perform public._connect_in_person(m, f_stale, 'qr', null);
  perform set_config('bolas.trusted_write', 'on', true);
  insert into public.connections (requester_id, addressee_id, status, level, method)
    values (a, acq, 'accepted', 'acquaintance', 'request');
  perform set_config('bolas.trusted_write', 'off', true);

  -- =====================================================================
  -- T. 3-tag limit and timestamps (client writes)
  -- =====================================================================

  -- T1: 4 tags, an unknown tag, or a repeat are all rejected by the database.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  n := 0;
  begin
    update public.profiles
      set looking_for = array['hiring', 'open_to_work', 'need_cofounder', 'looking_for_clients']
      where id = a;
  exception when check_violation then n := n + 1;
  end;
  begin
    update public.profiles set looking_for = array['ceo'] where id = a;
  exception when check_violation then n := n + 1;
  end;
  begin
    update public.profiles set looking_for = array['hiring', 'hiring'] where id = a;
  exception when check_violation then n := n + 1;
  end;
  -- Exactly 3 is fine.
  err := null;
  begin
    update public.profiles
      set looking_for = array['hiring', 'need_cofounder', 'looking_for_partners']
      where id = a;
  exception when others then err := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  ok := n = 3 and err is null
        and (select cardinality(looking_for) from public.profiles where id = a) = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T1 4 tags / unknown tag / repeat rejected (' || n || '/3); exactly 3 saved' || coalesce(' (3-tag save failed: ' || err || ')', '');
  if not ok then fails := fails + 1; end if;
  update public.profiles set looking_for = array['hiring', 'looking_for_partners'] where id = a;

  -- T2: a client can't backdate (or future-date) tags_updated_at: any change
  -- becomes now(). Saving other fields leaves it alone.
  update public.profiles set tags_updated_at = now() - interval '10 days' where id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  update public.profiles set full_name = 'LF Viewer' where id = a;
  reset role;
  select tags_updated_at into ts from public.profiles where id = a;
  ok := ts = now() - interval '10 days';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  update public.profiles set tags_updated_at = '2000-01-01' where id = a;
  reset role;
  select tags_updated_at into ts from public.profiles where id = a;
  ok := ok and ts = now();
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  update public.profiles set tags_updated_at = '2999-01-01' where id = a;
  reset role;
  select tags_updated_at into ts from public.profiles where id = a;
  ok := ok and ts = now();
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T2 client-set tags_updated_at (past or future) becomes now(); other edits leave it alone';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- P. Premium flag: server-managed
  -- =====================================================================

  -- P1: ATTACK: a free user sets is_premium = true on their own row.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  err := null;
  begin
    update public.profiles set is_premium = true where id = a;
  exception when others then err := sqlstate || ' ' || sqlerrm;
  end;
  reset role;
  ok := err like '42501 premium_is_server_managed%'
        and not (select is_premium from public.profiles where id = a);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  P1 ATTACK self-upgrade to premium is rejected (' || coalesce(err, 'no error') || ')';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- R. Direct table reads: tags and premium aren't readable columns
  -- =====================================================================

  -- R1: ATTACK: filter profiles by tag straight through the API (skipping
  -- the premium check), or read someone's is_premium.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  n := 0;
  begin
    perform count(*) from public.profiles where looking_for && array['open_to_work'];
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    perform is_premium from public.profiles where id = b_same;
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    perform tags_updated_at from public.profiles where id = b_same;
  exception when insufficient_privilege then n := n + 1;
  end;
  reset role;
  ok := n = 3;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  R1 ATTACK direct select/filter on looking_for, is_premium, tags_updated_at denied (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- S. Suggested for you
  -- =====================================================================

  -- S1: pairing + exclusions for a (hiring, looking_for_partners).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select array_agg(s.id) into ids from public.suggested_matches(50) s where s.id = any (test_ids);
  select * into rec from public.suggested_matches(50) s where s.id = b_same;
  reset role;
  ok := ids @> array[b_same, g_mutual, f_stale, p_partner, acq]
        and not ids && array[a, e_nomatch, blk, blk_by, ip, sus, m]
        and rec.my_tag = 'hiring' and rec.their_tag = 'open_to_work';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S1 hiring finds open_to_work (acquaintances too); skips self, hiring, blocked both ways, in-person, suspended';
  if not ok then fails := fails + 1; end if;

  -- S2: the symmetric tag pairs with itself, from both sides.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select * into rec from public.suggested_matches(50) s where s.id = p_partner;
  ok := rec.my_tag = 'looking_for_partners' and rec.their_tag = 'looking_for_partners';
  perform set_config('request.jwt.claims', json_build_object('sub', p_partner, 'role', 'authenticated')::text, true);
  select * into rec from public.suggested_matches(50) s where s.id = a;
  ok := ok and rec.my_tag = 'looking_for_partners' and rec.their_tag = 'looking_for_partners';
  -- And the reverse of S1: open_to_work finds hiring.
  perform set_config('request.jwt.claims', json_build_object('sub', b_same, 'role', 'authenticated')::text, true);
  select * into rec from public.suggested_matches(50) s where s.id = a;
  ok := ok and rec.my_tag = 'open_to_work' and rec.their_tag = 'hiring';
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S2 looking_for_partners pairs with itself both ways; open_to_work finds hiring';
  if not ok then fails := fails + 1; end if;

  -- S3: ranking: mutuals first, then same city, and stale always last
  -- (f_stale has a mutual AND the same city, but its tags are 100 days old).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select array_agg(s.id) into ids from public.suggested_matches(50) s where s.id = any (test_ids);
  select * into rec from public.suggested_matches(50) s where s.id = f_stale;
  reset role;
  ok := array_position(ids, g_mutual) < array_position(ids, b_same)
        and array_position(ids, b_same) < array_position(ids, acq)
        and array_position(ids, f_stale) = cardinality(ids)
        and rec.is_stale and rec.mutual_count = 1 and rec.same_city;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S3 order: mutual > same city > rest, stale last (' || coalesce(ids::text, 'none') || ')';
  if not ok then fails := fails + 1; end if;

  -- S4: no tags -> no suggestions; suspended caller -> none; signed out -> error.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  select count(*) into n from public.suggested_matches(50);
  perform set_config('request.jwt.claims', json_build_object('sub', sus, 'role', 'authenticated')::text, true);
  ok := n = 0 and not exists (select 1 from public.suggested_matches(50));
  reset role;
  perform set_config('role', 'anon', true);
  err := null;
  begin
    perform * from public.suggested_matches(50);
  exception when others then err := sqlstate;
  end;
  reset role;
  ok := ok and err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S4 no tags / suspended -> no suggestions; anon -> denied';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- F. Premium tag filter in discover_profiles
  -- =====================================================================

  -- F1: ATTACK: a free user calls the API with p_looking_for directly.
  -- Browsing without it (or with an empty list) still works.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  err := null;
  begin
    perform * from public.discover_profiles(p_looking_for => array['open_to_work']);
  exception when others then err := sqlstate || ' ' || sqlerrm;
  end;
  select count(*) into n from public.discover_profiles(p_search => 'lf_', p_looking_for => array[]::text[]);
  reset role;
  ok := err = '42501 premium_required' and n > 0;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  F1 ATTACK free user filtering by tag -> premium_required (' || coalesce(err, 'no error')
    || '); plain browsing still returns ' || n;
  if not ok then fails := fails + 1; end if;

  -- F2: premium (set by the server) can filter; stale tags don't match.
  update public.profiles set is_premium = true where id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select array_agg(d.id) into ids
  from public.discover_profiles(p_search => 'lf_', p_looking_for => array['open_to_work']) d
  where d.id = any (test_ids);
  reset role;
  ok := (select is_premium from public.profiles where id = a)
        and ids @> array[b_same, g_mutual, acq]
        and not ids && array[f_stale, e_nomatch, p_partner, blk, blk_by, sus];
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  F2 premium filter returns fresh open_to_work only (stale, other tags, blocked, suspended left out)';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- V. Reading and confirming tags
  -- =====================================================================

  -- V1: get_looking_for follows profile visibility.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  select * into rec from public.get_looking_for(b_same);
  ok := rec.looking_for = array['open_to_work'] and rec.tags_updated_at is not null;
  ok := ok and not exists (select 1 from public.get_looking_for(blk))
           and not exists (select 1 from public.get_looking_for(blk_by))
           and not exists (select 1 from public.get_looking_for(sus));
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  V1 get_looking_for: visible profile yes; blocked either way or suspended -> nothing';
  if not ok then fails := fails + 1; end if;

  -- V2: confirm resets a stale clock to now(); with no tags it's a no-op.
  update public.profiles set tags_updated_at = now() - interval '100 days' where id = a;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  ts := public.confirm_looking_for();
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  ok := ts = now() and public.confirm_looking_for() is null;
  reset role;
  ok := ok and (select tags_updated_at from public.profiles where id = a) = now()
           and (select tags_updated_at from public.profiles where id = m) is null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  V2 confirm_looking_for resets the 90-day clock; no tags -> null';
  if not ok then fails := fails + 1; end if;

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
