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
-- Sections: S = suspended accounts can't write (item M5),
--           T = current Terms required to message / connect / RSVP / host (M5).

do $tests$
declare
  -- S: suspension
  sS uuid := gen_random_uuid();    -- suspended (Terms accepted)
  sN uuid := gen_random_uuid();    -- suspended, hasn't accepted the current Terms
  sAdm uuid := gen_random_uuid();  -- suspended admin
  sF uuid := gen_random_uuid();    -- sS's connection; hosts eF / eF2
  sP uuid := gen_random_uuid();    -- sent sS a pending request
  sI uuid := gen_random_uuid();    -- met sS in person just now (undo window open)
  sO uuid := gen_random_uuid();    -- someone else; hosts eO
  sB uuid := gen_random_uuid();    -- blocked by sS
  sR1 uuid := gen_random_uuid();   -- old accounts that already reported eO
  sR2 uuid := gen_random_uuid();
  -- T: Terms
  tN uuid := gen_random_uuid();    -- only accepted an old Terms version
  tF uuid := gen_random_uuid();    -- tN's connection; hosts eT
  tOth uuid := gen_random_uuid();    -- someone else, sent tN a pending request
  tX uuid := gen_random_uuid();    -- target for tN's connection request

  conv_s uuid;
  conv_t uuid;
  eF uuid;    -- sF's event; sS tries to RSVP
  eF2 uuid;   -- sF's event; sS already going
  eS uuid;    -- sS's own event
  eO uuid;    -- sO's public event with 2 counted reports
  eT uuid;    -- tF's event; tN tries to RSVP
  c_in_person uuid;
  tok_o text;
  tok_to text;
  v_current text := public._current_terms_version();

  report text := '';
  fails int := 0;
  ok boolean;
  err text;
  n int;
  v jsonb;
begin
  -- ---------- setup (as admin) ----------
  insert into auth.users (id, email, aud, role, created_at)
  select id, id || '@test.bolas.invalid', 'authenticated', 'authenticated', now() - interval '30 days'
  from unnest(array[sS, sN, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tN, tF, tOth, tX]) as id;

  update public.profiles
  set username = 'm5_' || left(replace(id::text, '-', ''), 12), bio = 'Original bio'
  where id in (sS, sN, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tN, tF, tOth, tX);

  -- Everyone has accepted the current Terms except sN (never) and tN (an
  -- old version only).
  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  select id, v_current, now(), now()
  from unnest(array[sS, sAdm, sF, sP, sI, sO, sB, sR1, sR2, tF, tOth, tX]) as id;
  insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
  values (tN, '2000-01-01', now() - interval '1 year', now() - interval '1 year');

  insert into public.app_admins (user_id) values (sAdm);

  insert into public.connections (requester_id, addressee_id, status) values
    (sS, sF, 'accepted'), (sP, sS, 'pending'),
    (tN, tF, 'accepted'), (tOth, tN, 'pending');
  v := public._connect_in_person(sS, sI, 'bump', 'Boise');
  c_in_person := (v ->> 'connection_id')::uuid;
  insert into public.user_blocks (blocker_id, blocked_id) values (sS, sB);

  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (sF, 'M5 F', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eF;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (sF, 'M5 F2', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eF2;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (sS, 'M5 S', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eS;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (sO, 'M5 O', 43.6, -116.2, now() + interval '1 day', 'public') returning id into eO;
  insert into public.events (creator_id, title, approx_latitude, approx_longitude, starts_at, visibility)
  values (tF, 'M5 T', 43.6, -116.2, now() + interval '1 day', 'connections') returning id into eT;
  insert into public.event_attendees (event_id, user_id) values (eF2, sS);
  insert into public.event_reports (event_id, reporter_id, reason) values (eO, sR1, 'spam'), (eO, sR2, 'spam');

  insert into storage.objects (bucket_id, name, owner) values ('avatars', sS || '/avatar.jpg', sS);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
  conv_s := public.get_or_create_direct_conversation(sF);
  insert into public.messages (conversation_id, sender_id, body) values (conv_s, sS, 'before');
  perform set_config('request.jwt.claims', json_build_object('sub', sO, 'role', 'authenticated')::text, true);
  tok_o := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', tOth, 'role', 'authenticated')::text, true);
  tok_to := public.create_connect_token() ->> 'token';
  perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
  conv_t := public.get_or_create_direct_conversation(tF);
  reset role;

  -- Suspend (an admin's admin_set_account_status would also remove eS; a
  -- direct insert keeps eS around for S7).
  insert into public.account_restrictions (user_id, status, created_by)
  values (sS, 'suspended', sAdm), (sN, 'suspended', sAdm), (sAdm, 'suspended', sF);

  -- =====================================================================
  -- S. Suspended accounts can't write (M5)
  -- =====================================================================

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);

  -- S1 (attack): direct table inserts are refused with 42501:
  -- connection request, message, RSVP, profile row, avatar upload.
  n := 0;
  begin insert into public.connections (requester_id, addressee_id) values (sS, sO);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.messages (conversation_id, sender_id, body) values (conv_s, sS, 'hello?');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.event_attendees (event_id, user_id) values (eF, sS);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.profiles (id) values (sS);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into storage.objects (bucket_id, name, owner) values ('avatars', sS || '/new.jpg', sS);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  ok := n = 5;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S1 suspended: request/message/RSVP/profile/avatar inserts refused (' || n || '/5)';
  if not ok then fails := fails + 1; end if;

  -- S2 (attack): direct updates change nothing: accept a pending request,
  -- edit the profile, mark a chat read, rename the avatar file.
  begin
    update public.connections set status = 'accepted' where requester_id = sP and addressee_id = sS;
  exception when others then null;  -- refused either way
  end;
  begin
    update public.profiles set bio = 'Changed while suspended' where id = sS;
  exception when others then null;  -- refused either way
  end;
  begin
    update public.conversation_participants set last_read_at = now() + interval '1 day'
    where conversation_id = conv_s and user_id = sS;
  exception when others then null;  -- refused either way
  end;
  begin
    update storage.objects set name = sS || '/renamed.jpg' where bucket_id = 'avatars' and name = sS || '/avatar.jpg';
  exception when others then null;  -- refused either way
  end;
  reset role;
  ok := (select status from public.connections where requester_id = sP and addressee_id = sS) = 'pending'
        and (select bio from public.profiles where id = sS) = 'Original bio'
        and (select last_read_at from public.conversation_participants
             where conversation_id = conv_s and user_id = sS) <= now()
        and exists (select 1 from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S2 suspended: accept request / edit profile / mark read / rename avatar change nothing';
  if not ok then fails := fails + 1; end if;

  -- S3 (attack): direct deletes remove nothing: a connection, their RSVP,
  -- their own event, their avatar.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
  begin
    delete from public.connections where requester_id = sS and addressee_id = sF;
  exception when others then null;  -- refused either way
  end;
  begin
    delete from public.event_attendees where event_id = eF2 and user_id = sS;
  exception when others then null;  -- refused either way
  end;
  begin
    delete from public.events where id = eS;
  exception when others then null;  -- refused either way
  end;
  begin
    delete from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg';
  exception when others then null;  -- refused either way
  end;
  reset role;
  ok := exists (select 1 from public.connections where requester_id = sS and addressee_id = sF)
        and exists (select 1 from public.event_attendees where event_id = eF2 and user_id = sS)
        and exists (select 1 from public.events where id = eS)
        and exists (select 1 from storage.objects where bucket_id = 'avatars' and name = sS || '/avatar.jpg');
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S3 suspended: delete connection / RSVP / own event / avatar remove nothing';
  if not ok then fails := fails + 1; end if;

  -- S4 (attack): the RPCs that had no check: block, undo, map location, QR code.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
  n := 0;
  if public.block_user(sO) ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
  if public.undo_in_person_connection(c_in_person) ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
  begin perform public.update_my_location(43.6, -116.2);
  exception when others then if sqlerrm = 'account_suspended' then n := n + 1; end if; end;
  begin perform public.create_connect_token();
  exception when others then if sqlerrm = 'account_suspended' then n := n + 1; end if; end;
  reset role;
  ok := n = 4
        and not exists (select 1 from public.user_blocks where blocker_id = sS and blocked_id = sO)
        and (select level::text from public.connections where id = c_in_person) = 'in_person'
        and not exists (select 1 from public.user_locations where user_id = sS)
        and not exists (select 1 from public.connect_tokens where user_id = sS);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S4 suspended: block / undo / update_my_location / create_connect_token refused (' || n || '/4)';
  if not ok then fails := fails + 1; end if;

  -- S5 (attack): the RPCs that already checked still do: start a chat,
  -- bump, scan a QR code, create and edit an event.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
  n := 0;
  begin perform public.get_or_create_direct_conversation(sO);
  exception when others then n := n + 1; end;
  if public.submit_bump(43.6, -116.2, 10, null) ->> 'status' = 'no_match' then n := n + 1; end if;
  if public.redeem_connect_token(tok_o, null) ->> 'outcome' = 'unavailable' then n := n + 1; end if;
  if public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections')
     ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
  if public.update_event(eS, 'Changed', null, now() + interval '1 day', null, 'connections')
     ->> 'outcome' = 'not_allowed' then n := n + 1; end if;
  reset role;
  ok := n = 5
        and not exists (select 1 from public.bump_events where user_id = sS)
        and not exists (select 1 from public.connections
                        where (requester_id = sS and addressee_id = sO) or (requester_id = sO and addressee_id = sS))
        and (select title from public.events where id = eS) = 'M5 S';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S5 suspended: chat / bump / QR / create + edit event still refused (' || n || '/5)';
  if not ok then fails := fails + 1; end if;

  -- S6 (attack): a suspended admin has no admin power (RPCs or the
  -- admin delete policy).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', sAdm, 'role', 'authenticated', 'aal', 'aal2')::text, true);
  n := 0;
  begin perform public.admin_set_event_status(eO, 'removed', null);
  exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
  begin perform public.admin_set_account_status(sS, null, null);
  exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
  begin perform * from public.admin_list_user_reports('open');
  exception when others then if sqlerrm = 'admin_only' then n := n + 1; end if; end;
  begin
    delete from public.events where id = eO;
  exception when others then null;  -- refused either way
  end;
  reset role;
  ok := n = 3
        and (select status from public.events where id = eO) = 'active'
        and exists (select 1 from public.account_restrictions where user_id = sS);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S6 suspended admin: admin RPCs refused, can''t delete events (' || n || '/3)';
  if not ok then fails := fails + 1; end if;

  -- S7: allowed while suspended: read own profile, restriction, connections,
  -- messages; unblock; report a user; report an event.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sS, 'role', 'authenticated')::text, true);
  n := 0;
  if (select count(*) from public.profiles where id = sS) = 1 then n := n + 1; end if;
  if (select count(*) from public.account_restrictions where user_id = sS) = 1 then n := n + 1; end if;
  if (select count(*) from public.connections where requester_id = sS or addressee_id = sS) >= 2 then n := n + 1; end if;
  if (select count(*) from public.messages where sender_id = sS) = 1 then n := n + 1; end if;
  if public.unblock_user(sB) ->> 'outcome' = 'unblocked' then n := n + 1; end if;
  if public.report_user(sO, 'profile', null, 'spam', null) ->> 'outcome' = 'reported' then n := n + 1; end if;
  v := public.report_event(eO, 'spam', null);
  if v ->> 'outcome' = 'reported' then n := n + 1; end if;
  reset role;
  ok := n = 7
        and not exists (select 1 from public.user_blocks where blocker_id = sS and blocked_id = sB)
        and exists (select 1 from public.user_reports where reporter_id = sS and reported_user_id = sO)
        and exists (select 1 from public.event_reports where reporter_id = sS and event_id = eO);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S7 suspended can: read own data, unblock, report a user, report an event (' || n || '/7)';
  if not ok then fails := fails + 1; end if;

  -- S8 (attack): a suspended account's event report doesn't count toward
  -- auto-hide (eO had 2 counted reports; 3 hides it).
  ok := (v ->> 'hidden')::boolean = false and (select status from public.events where id = eO) = 'active';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S8 suspended reporter doesn''t count toward auto-hide (hidden=' || coalesce(v ->> 'hidden', 'null') || ')';
  if not ok then fails := fails + 1; end if;

  -- S9: a suspended account that hasn't accepted the current Terms can.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', sN, 'role', 'authenticated')::text, true);
  v := public.accept_terms(v_current, true);
  reset role;
  ok := v ->> 'outcome' = 'accepted'
        and exists (select 1 from public.user_consents where user_id = sN and terms_version = v_current);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S9 suspended can accept the Terms -> ' || coalesce(v ->> 'outcome', 'null');
  if not ok then fails := fails + 1; end if;

  -- S10: deleting the account still works (the delete-account Edge Function
  -- deletes the auth user with the service role; no user JWT).
  perform set_config('request.jwt.claims', '', true);
  err := null;
  begin
    delete from auth.users where id = sS;
  exception when others then err := sqlerrm;
  end;
  ok := err is null
        and not exists (select 1 from public.profiles where id = sS)
        and not exists (select 1 from public.connections where requester_id = sS or addressee_id = sS)
        and not exists (select 1 from public.messages where sender_id = sS);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  S10 suspended account can still be deleted' || coalesce(' (error ' || err || ')', '');
  if not ok then fails := fails + 1; end if;

  -- =====================================================================
  -- T. Current Terms required (M5)
  -- =====================================================================
  -- tN accepted an old version only, so they count as "not accepted".

  -- T1 (attack): message, request, accept, RSVP through the tables.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
  n := 0;
  begin insert into public.messages (conversation_id, sender_id, body) values (conv_t, tN, 'hi');
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.connections (requester_id, addressee_id) values (tN, tX);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin insert into public.event_attendees (event_id, user_id) values (eT, tN);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin
    update public.connections set status = 'accepted' where requester_id = tOth and addressee_id = tN;
  exception when others then null;  -- refused either way
  end;
  reset role;
  ok := n = 3
        and not exists (select 1 from public.messages where sender_id = tN)
        and not exists (select 1 from public.connections where requester_id = tN and addressee_id = tX)
        and not exists (select 1 from public.event_attendees where event_id = eT and user_id = tN)
        and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'pending';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T1 no current Terms: message/request/RSVP refused (' || n || '/3), accept changes nothing';
  if not ok then fails := fails + 1; end if;

  -- T2 (attack): create an event, make a QR code, bump, scan someone's code.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
  n := 0;
  v := public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections');
  if v ->> 'outcome' = 'not_allowed' and v ->> 'reason' = 'terms_not_accepted' then n := n + 1; end if;
  begin perform public.create_connect_token();
  exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
  begin perform public.submit_bump(43.6, -116.2, 10, null);
  exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
  begin perform public.redeem_connect_token(tok_to, null);
  exception when others then if sqlerrm = 'terms_not_accepted' then n := n + 1; end if; end;
  reset role;
  ok := n = 4
        and not exists (select 1 from public.events where creator_id = tN)
        and not exists (select 1 from public.connect_tokens where user_id = tN)
        and not exists (select 1 from public.bump_events where user_id = tN)
        and (select used_at from public.connect_tokens where token = tok_to) is null
        and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'pending';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T2 no current Terms: create event / QR code / bump / scan refused (' || n || '/4)';
  if not ok then fails := fails + 1; end if;

  -- T3: connecting in person with someone who hasn't accepted is
  -- 'unavailable' (their consent state isn't revealed).
  v := public._connect_in_person(tOth, tN, 'qr', null);
  ok := v ->> 'outcome' = 'unavailable'
        and (select level::text from public.connections where requester_id = tOth and addressee_id = tN) = 'acquaintance';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T3 other person without current Terms -> ' || coalesce(v ->> 'outcome', 'null');
  if not ok then fails := fails + 1; end if;

  -- T4 (attack): they can't fake consent by writing the table.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
  n := 0;
  begin
    insert into public.user_consents (user_id, terms_version, accepted_at, age_confirmed_at)
    values (tN, v_current, now(), now());
  exception when others then n := n + 1;
  end;
  begin
    update public.user_consents set terms_version = v_current where user_id = tN;
  exception when others then null;  -- refused either way
  end;
  reset role;
  ok := n = 1 and not public.has_accepted_current_terms(tN);
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T4 writing user_consents directly is refused';
  if not ok then fails := fails + 1; end if;

  -- T5: accept_terms works, then everything above goes through.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', tN, 'role', 'authenticated')::text, true);
  n := 0;
  if public.accept_terms(v_current, true) ->> 'outcome' = 'accepted' then n := n + 1; end if;
  begin
    insert into public.messages (conversation_id, sender_id, body) values (conv_t, tN, 'hi');
    n := n + 1;
  exception when others then null;
  end;
  begin
    insert into public.connections (requester_id, addressee_id) values (tN, tX);
    n := n + 1;
  exception when others then null;
  end;
  begin
    insert into public.event_attendees (event_id, user_id) values (eT, tN);
    n := n + 1;
  exception when others then null;
  end;
  update public.connections set status = 'accepted' where requester_id = tOth and addressee_id = tN;
  if public.create_event('x', null, null, 43.6, -116.2, now() + interval '1 day', null, 'connections')
     ->> 'outcome' = 'created' then n := n + 1; end if;
  if public.create_connect_token() ->> 'outcome' = 'ok' then n := n + 1; end if;
  if public.redeem_connect_token(tok_to, null) ->> 'outcome' = 'upgraded' then n := n + 1; end if;
  reset role;
  ok := n = 7
        and (select status from public.connections where requester_id = tOth and addressee_id = tN) = 'accepted'
        and (select level::text from public.connections where requester_id = tOth and addressee_id = tN) = 'in_person';
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T5 after accept_terms: message/request/RSVP/accept/event/QR all work (' || n || '/7)';
  if not ok then fails := fails + 1; end if;

  -- T6 (attack): anon can't call the helper.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  n := 0;
  begin perform public.has_accepted_current_terms(tN);
  exception when others then if sqlstate = '42501' then n := n + 1; end if; end;
  begin perform public._require_can_connect();
  exception when others then n := n + 1; end;
  reset role;
  ok := n = 2;
  report := report || E'\n' || case when ok then 'PASS' else 'FAIL' end
    || '  T6 anon can''t call has_accepted_current_terms / the trigger function (' || n || '/2)';
  if not ok then fails := fails + 1; end if;

  -- ---------- report ----------
  raise exception '%', E'TEST RESULTS: ' || fails || ' failed (rolled back, nothing saved)' || report;
end
$tests$;
