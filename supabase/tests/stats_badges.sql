-- Profile stats, event check-in and badges
-- (migration 20260930030000_profile_stats_and_badges.sql). Same style as
-- legal_compliance.sql: one DO block that ALWAYS ends by raising, which rolls
-- back everything it created; the message is the report ("TEST RESULTS",
-- FAIL lines). Run on the DEV project:
--
--   npx supabase db query --linked -f supabase/tests/stats_badges.sql
--
-- Real concurrency (many sessions completing profiles at the same moment)
-- can't happen inside one DO block; N1 checks the guarantees it relies on
-- (the locked counter and the unique constraints). A separate parallel-
-- session run is described in the PR / summary.
--
-- Sections: N = member numbers, P = supporter cap, B = badges permanent,
-- A = acquaintances, C = check-in, H = hosted (3+ rule), S = stats
-- visibility, F = featured badges.

do $tests$
declare
  host uuid := gen_random_uuid();
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  a3 uuid := gen_random_uuid();
  a4 uuid := gen_random_uuid();
  far uuid := gen_random_uuid();     -- checks in from 5 km away
  n1 uuid := gen_random_uuid();      -- numbering
  n2 uuid := gen_random_uuid();
  n3 uuid := gen_random_uuid();
  s1 uuid := gen_random_uuid();      -- supporters
  s2 uuid := gen_random_uuid();
  adm uuid := gen_random_uuid();
  acq uuid := gen_random_uuid();     -- has 10 acquaintances
  blk uuid := gen_random_uuid();     -- blocked by host
  ids uuid[];
  acq_friends uuid[] := array[]::uuid[];
  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  n int;
  v jsonb;
  v2 jsonb;
  rec record;
  ev uuid;
  ev_later uuid;
  tok text;
  cnt_before int;
  -- The event's real spot and a point ~50 m away (Boise).
  spot_lat float8 := 43.61500;
  spot_lng float8 := -116.20230;
  near_lat float8 := 43.61545;
  near_lng float8 := -116.20230;
  admin_claims text;
begin
  for n in 1..10 loop
    acq_friends := acq_friends || gen_random_uuid();
  end loop;
  ids := array[host, a1, a2, a3, a4, far, n1, n2, n3, s1, s2, adm, acq, blk] || acq_friends;

  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
  from unnest(ids) as id;

  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  select id, public._current_terms_version(), now(), now()
  from unnest(ids) as id;

  -- Usernames only: NOT complete yet (no full name / city / stage), so no
  -- member numbers are handed out during setup.
  update public.profiles
  set username = 'sb_' || left(replace(id::text, '-', ''), 12)
  where id = any (ids);

  insert into public.app_admins (user_id) values (adm);
  admin_claims := json_build_object('sub', adm, 'role', 'authenticated', 'aal', 'aal2')::text;

  -- =====================================================================
  -- N. Member numbers
  -- =====================================================================

  -- N1: completing a profile hands out the next number; the #200/#201
  -- boundary splits Founder from Early Member; the badge shows the number.
  update public.badge_counters set last_number = 199 where key = 'member';
  update public.profiles set full_name = 'N One', city = 'Boise', business_stage = 'idea' where id = n1;
  update public.profiles set full_name = 'N Two', city = 'Boise', business_stage = 'idea' where id = n2;
  update public.profiles set full_name = 'N Three', city = 'Boise', business_stage = 'idea' where id = n3;
  ok := (select member_number from public.profiles where id = n1) = 200
        and (select member_number from public.profiles where id = n2) = 201
        and (select member_number from public.profiles where id = n3) = 202
        and exists (select 1 from public.user_badges where user_id = n1 and badge_key = 'founder' and number = 200)
        and not exists (select 1 from public.user_badges where user_id = n1 and badge_key = 'early_member')
        and exists (select 1 from public.user_badges where user_id = n2 and badge_key = 'early_member' and number = 201)
        and not exists (select 1 from public.user_badges where user_id = n2 and badge_key = 'founder')
        and (select profile_completed_at from public.profiles where id = n1) = now();
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  N1 #200 = Founder, #201/#202 = Early Member, numbers follow completion order';
  if not ok then fails := fails + 1; end if;

  -- N2: the guarantees concurrency relies on: a number can't be used twice
  -- (on profiles or on a badge), and the counter moved exactly once each.
  n := 0;
  begin
    update public.profiles set member_number = 200 where id = n3;
  exception when unique_violation then n := n + 1;
  end;
  begin
    insert into public.user_badges (user_id, badge_key, number) values (n3, 'founder', 200);
  exception when unique_violation then n := n + 1;
  end;
  ok := n = 2 and (select last_number from public.badge_counters where key = 'member') = 202;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  N2 duplicate member number refused on profiles and badges (' || n || '/2); counter at 202';
  if not ok then fails := fails + 1; end if;

  -- N3: incomplete profiles get no number; completion sticks even if a
  -- required field is cleared later.
  ok := (select member_number from public.profiles where id = a1) is null;
  update public.profiles set city = null where id = n1;
  ok := ok and (select member_number from public.profiles where id = n1) = 200
           and (select profile_completed_at from public.profiles where id = n1) is not null;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  N3 incomplete -> no number; clearing a field later keeps the number';
  if not ok then fails := fails + 1; end if;

  -- N4: ATTACK: a client sets its own member number / completion / lifetime.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  n := 0;
  begin
    update public.profiles set member_number = 1 where id = a1;
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    update public.profiles set profile_completed_at = now() - interval '1 year' where id = a1;
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    update public.profiles set lifetime_premium = true where id = a1;
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    perform public.admin_set_lifetime_premium(a1, true);
  exception when insufficient_privilege then n := n + 1;
  end;
  reset role;
  ok := n = 4 and (select member_number from public.profiles where id = a1) is null
        and not (select lifetime_premium from public.profiles where id = a1);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  N4 ATTACK client can''t set member_number / completed_at / lifetime, or call the admin toggle (' || n || '/4)';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- P. Supporter cap
  -- =====================================================================

  -- P1: one spot left: the first grant takes it, the second is sold out.
  update public.badge_counters set last_number = public._supporter_cap() - 1 where key = 'supporter';
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', admin_claims, true);
  v := public.admin_set_lifetime_premium(s1, true);
  v2 := public.admin_set_lifetime_premium(s2, true);
  n := public.supporter_spots_remaining();
  reset role;
  ok := v ->> 'outcome' = 'granted' and (v ->> 'number')::int = public._supporter_cap()
        and v2 ->> 'outcome' = 'sold_out' and n = 0
        and (select lifetime_premium and is_premium from public.profiles where id = s1)
        and not (select lifetime_premium from public.profiles where id = s2)
        and not exists (select 1 from public.user_badges where user_id = s2 and badge_key = 'supporter')
        and exists (select 1 from public.user_badges where user_id = s1 and badge_key = 'supporter'
                    and number = public._supporter_cap());
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  P1 cap: last spot granted (' || v::text || '), next sold out (' || v2::text || '), spots left ' || n;
  if not ok then fails := fails + 1; end if;

  -- P2: removing lifetime keeps the badge; re-granting reuses the number
  -- even though the cap is reached.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', admin_claims, true);
  v := public.admin_set_lifetime_premium(s1, false);
  v2 := public.admin_set_lifetime_premium(s1, true);
  reset role;
  ok := v ->> 'outcome' = 'removed' and v2 ->> 'outcome' = 'granted'
        and (v2 ->> 'number')::int = public._supporter_cap()
        and (select count(*) from public.user_badges where user_id = s1 and badge_key = 'supporter') = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  P2 lifetime off keeps Supporter; back on reuses the same number (' || v2::text || ')';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- B. Badges are permanent
  -- =====================================================================

  -- B1: first in-person connection -> First Handshake; removing it drops the
  -- count but not the badge.
  perform public._connect_in_person(a1, a2, 'qr', null);
  ok := exists (select 1 from public.user_badges where user_id = a1 and badge_key = 'first_handshake')
        and (select in_person_connections from public.profile_stats where user_id = a1) = 1;
  perform set_config('bolas.trusted_write', 'on', true);
  delete from public.connections where (requester_id = a1 and addressee_id = a2) or (requester_id = a2 and addressee_id = a1);
  perform set_config('bolas.trusted_write', 'off', true);
  ok := ok and (select in_person_connections from public.profile_stats where user_id = a1) = 0
           and exists (select 1 from public.user_badges where user_id = a1 and badge_key = 'first_handshake');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  B1 First Handshake stays after the connection is removed (count 1 -> 0)';
  if not ok then fails := fails + 1; end if;

  -- B2: ATTACK: nobody can delete or edit a badge, not a client and not a
  -- server write; only seen_at / featured_rank change (via functions).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  n := 0;
  begin
    delete from public.user_badges where user_id = a1;
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    insert into public.user_badges (user_id, badge_key) values (a1, 'web_weaver');
  exception when insufficient_privilege then n := n + 1;
  end;
  reset role;
  begin
    delete from public.user_badges where user_id = a1 and badge_key = 'first_handshake';
  exception when insufficient_privilege then n := n + 1;
  end;
  begin
    update public.user_badges set awarded_at = now() - interval '1 year' where user_id = n1 and badge_key = 'founder';
  exception when insufficient_privilege then n := n + 1;
  end;
  ok := n = 4 and exists (select 1 from public.user_badges where user_id = a1 and badge_key = 'first_handshake')
        and not exists (select 1 from public.user_badges where user_id = a1 and badge_key = 'web_weaver');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  B2 ATTACK badge delete/insert/edit refused for clients and server writes (' || n || '/4)';
  if not ok then fails := fails + 1; end if;

  -- B3: deleting the whole account still works (badges go with it).
  err := null;
  begin
    delete from auth.users where id = n3;
  exception when others then err := sqlstate || ' ' || sqlerrm;
  end;
  ok := err is null and not exists (select 1 from public.user_badges where user_id = n3);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  B3 account deletion removes its badges' || coalesce(' (' || err || ')', '');
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- A. Acquaintances never earn badges
  -- =====================================================================

  perform set_config('bolas.trusted_write', 'on', true);
  insert into public.connections (requester_id, addressee_id, status, level, method)
  select acq, f, 'accepted', 'acquaintance', 'request' from unnest(acq_friends) as f;
  perform set_config('bolas.trusted_write', 'off', true);
  select * into rec from public.profile_stats where user_id = acq;
  ok := rec.acquaintances = 10 and rec.in_person_connections = 0
        and not exists (select 1 from public.user_badges where user_id = acq
                        and badge_key in ('first_handshake', 'connector'));
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  A1 10 acquaintances -> counted (10), but no First Handshake / Connector';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- C. Check-in
  -- =====================================================================

  -- An event that started 10 minutes ago, and one that starts in 2 hours.
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (host, 'SB Meetup', spot_lat + 0.002, spot_lng, now() - interval '10 minutes', now() + interval '2 hours', 'public')
  returning id into ev;
  insert into public.event_locations (event_id, latitude, longitude) values (ev, spot_lat, spot_lng);
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, ends_at, visibility)
  values (host, 'SB Later', spot_lat, spot_lng, now() + interval '2 hours', now() + interval '4 hours', 'public')
  returning id into ev_later;
  insert into public.event_locations (event_id, latitude, longitude) values (ev_later, spot_lat, spot_lng);
  insert into public.user_blocks (blocker_id, blocked_id) values (host, blk);

  -- C1: the host gets a code only for their own event, only once the window
  -- is open.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', host, 'role', 'authenticated')::text, true);
  v := public.create_event_checkin_token(ev);
  v2 := public.create_event_checkin_token(ev_later);
  tok := v ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  ok := v ->> 'outcome' = 'ok' and tok ~ '^[0-9a-f]{32}$' and v2 ->> 'outcome' = 'not_open'
        and public.create_event_checkin_token(ev) ->> 'outcome' = 'not_found';
  reset role;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  C1 host code: ok now, not_open 2 h early, not_found for someone else';
  if not ok then fails := fails + 1; end if;

  -- C2: one check-in per person per event; attended counts once.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  v := public.redeem_event_checkin(tok, near_lat, near_lng, 20);
  v2 := public.redeem_event_checkin(tok, near_lat, near_lng, 20);
  reset role;
  ok := v ->> 'outcome' = 'checked_in' and v2 ->> 'outcome' = 'already_checked_in'
        and (select count(*) from public.event_checkins where event_id = ev and user_id = a1) = 1
        and (select events_attended from public.profile_stats where user_id = a1) = 1
        and exists (select 1 from public.user_badges where user_id = a1 and badge_key = 'showed_up');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  C2 second check-in -> already_checked_in; attended = 1; Showed Up earned';
  if not ok then fails := fails + 1; end if;

  -- C3: refusals: too far, no location, the host themselves, a blocked
  -- person, an expired code, a made-up code.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', far, 'role', 'authenticated')::text, true);
  ok := public.redeem_event_checkin(tok, spot_lat + 0.05, spot_lng, 20) ->> 'outcome' = 'too_far'
        and public.redeem_event_checkin(tok, null, null, null) ->> 'outcome' = 'location_required'
        and public.redeem_event_checkin(tok, near_lat, near_lng, 5000) ->> 'outcome' = 'poor_location'
        and public.redeem_event_checkin(repeat('0', 32), near_lat, near_lng, 20) ->> 'outcome' = 'invalid';
  perform set_config('request.jwt.claims', json_build_object('sub', host, 'role', 'authenticated')::text, true);
  ok := ok and public.redeem_event_checkin(tok, near_lat, near_lng, 20) ->> 'outcome' = 'host';
  perform set_config('request.jwt.claims', json_build_object('sub', blk, 'role', 'authenticated')::text, true);
  ok := ok and public.redeem_event_checkin(tok, near_lat, near_lng, 20) ->> 'outcome' = 'invalid';
  reset role;
  update public.event_checkin_tokens set expires_at = now() - interval '1 second' where token = tok;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', far, 'role', 'authenticated')::text, true);
  ok := ok and public.redeem_event_checkin(tok, near_lat, near_lng, 20) ->> 'outcome' = 'expired';
  reset role;
  ok := ok and not exists (select 1 from public.event_checkins where event_id = ev and user_id in (far, host, blk));
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  C3 too far / no location / poor GPS / fake code / host / blocked / expired all refused';
  if not ok then fails := fails + 1; end if;

  -- C4: ATTACK: writing a check-in directly skips every rule, so it's refused.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', far, 'role', 'authenticated')::text, true);
  err := null;
  begin
    insert into public.event_checkins (event_id, user_id) values (ev, far);
  exception when insufficient_privilege then err := 'denied';
  end;
  reset role;
  ok := err = 'denied';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end || '  C4 ATTACK direct insert into event_checkins refused';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- H. Hosted: counts at 3 check-ins (host excluded), once
  -- =====================================================================

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', host, 'role', 'authenticated')::text, true);
  tok := public.create_event_checkin_token(ev) ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', a2, 'role', 'authenticated')::text, true);
  perform public.redeem_event_checkin(tok, near_lat, near_lng, 20);
  reset role;
  -- a1 + a2 = 2 check-ins: not yet.
  ok := coalesce((select events_hosted from public.profile_stats where user_id = host), 0) = 0
        and (select checkin_qualified_at from public.events where id = ev) is null;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a3, 'role', 'authenticated')::text, true);
  perform public.redeem_event_checkin(tok, near_lat, near_lng, 20);
  reset role;
  ok := ok and (select events_hosted from public.profile_stats where user_id = host) = 1
           and exists (select 1 from public.user_badges where user_id = host and badge_key = 'host');
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a4, 'role', 'authenticated')::text, true);
  perform public.redeem_event_checkin(tok, near_lat, near_lng, 20);
  reset role;
  ok := ok and (select events_hosted from public.profile_stats where user_id = host) = 1
           and (select count(*) from public.event_checkins where event_id = ev) = 4;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  H1 2 check-ins -> 0 hosted; 3rd -> 1 + Host badge; 4th -> still 1';
  if not ok then fails := fails + 1; end if;

  -- H2: the event being deleted later (30-day retention) doesn't lower the
  -- lifetime counters.
  delete from public.events where id = ev;
  ok := (select events_hosted from public.profile_stats where user_id = host) = 1
        and (select events_attended from public.profile_stats where user_id = a1) = 1;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  H2 deleting the event keeps hosted / attended counts';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- S. Stats visibility
  -- =====================================================================

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', acq, 'role', 'authenticated')::text, true);
  select * into rec from public.get_profile_stats(acq);
  ok := rec.acquaintances = 10;
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  select * into rec from public.get_profile_stats(acq);
  ok := ok and rec.acquaintances is null and rec.in_person_connections = 0;
  perform set_config('request.jwt.claims', json_build_object('sub', blk, 'role', 'authenticated')::text, true);
  ok := ok and not exists (select 1 from public.get_profile_stats(host))
           and not exists (select 1 from public.get_profile_badges(host));
  reset role;
  perform set_config('role', 'anon', true);
  err := null;
  begin
    perform * from public.get_profile_stats(acq);
  exception when others then err := sqlstate;
  end;
  reset role;
  ok := ok and err = '42501';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S1 acquaintances: owner sees 10, others see null; blocked sees nothing; anon denied';
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- F. Featured badges + toasts
  -- =====================================================================

  -- a1 has first_handshake and showed_up.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', a1, 'role', 'authenticated')::text, true);
  ok := public.set_featured_badges(array['first_handshake', 'showed_up', 'founder', 'host']) ->> 'outcome' = 'too_many'
        and public.set_featured_badges(array['founder']) ->> 'outcome' = 'not_owned'
        and public.set_featured_badges(array['showed_up', 'showed_up']) ->> 'outcome' = 'duplicate'
        and public.set_featured_badges(array['showed_up', 'first_handshake']) ->> 'outcome' = 'ok';
  select count(*) into n from public.get_unseen_badges();
  perform public.mark_badges_seen(array['showed_up', 'first_handshake']);
  ok := ok and n = 2 and not exists (select 1 from public.get_unseen_badges());
  reset role;
  ok := ok and (select featured_rank from public.user_badges where user_id = a1 and badge_key = 'showed_up') = 1
           and (select featured_rank from public.user_badges where user_id = a1 and badge_key = 'first_handshake') = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  F1 featured: max 3, own badges only, no repeats, order kept; unseen -> seen';
  if not ok then fails := fails + 1; end if;

  -- Always roll back: nothing from this run is kept.
  raise exception 'TEST RESULTS: % failed (rolled back, nothing saved)%', fails, report;
end;
$tests$;
