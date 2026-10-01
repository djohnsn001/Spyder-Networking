-- Profile stats, event QR check-in, and badges.
--
-- 1. profile_stats: cached counters, never counted live on a profile load.
--      in_person_connections, acquaintances: recounted by a trigger on every
--        connections change (request, accept, remove, in-person connect,
--        upgrade, undo, block). These can go down.
--      events_attended, events_hosted: lifetime counters that only go up.
--        Events (and their check-ins) are deleted 30 days after they end
--        (20260928000000 retention), so these can't be recounted later.
-- 2. Event check-in: from 15 minutes before an event starts until it ends,
--    the host shows a rotating QR code (create_event_checkin_token). An
--    attendee scans it (redeem_event_checkin) and must be near the event's
--    real spot, same idea as the connect QR codes (security item H2). One
--    check-in per person per event. "Events attended" counts only these.
--    An event counts toward the host's "Events hosted" once 3+ people (not
--    counting the host) have checked in.
-- 3. Badges: badge_definitions is the config (key, name, description,
--    placeholder icon, criteria incl. thresholds, number ranges and the
--    supporter cap). user_badges holds what people earned. Everything is
--    awarded here in the database; clients can only mark badges seen and
--    pick up to 3 to feature. Badges are never removed (a trigger refuses),
--    except when the whole account is deleted.
--    No badge can be based on acquaintances (badge_definitions check).
-- 4. Member numbers: handed out when a profile is COMPLETED
--    (_profile_is_complete). #1-200 get Founder, #201-1000 Early Member.
--    Numbers come from a locked counter row, so they're unique and gapless
--    even when many profiles complete at the same moment.
-- 5. Supporter: lifetime premium buyers, capped (250) by the supporter badge
--    criteria. Stacks with Founder / Early Member. No purchase flow exists
--    yet, so admin_set_lifetime_premium (admins only) grants it for testing;
--    the future purchase webhook should call _grant_lifetime_premium.
--
-- Phone verification later: set "require_phone" to true in _badge_rules()
-- (new migration re-creating it). _profile_is_complete then also needs
-- auth.users.phone_confirmed_at, and the trigger on auth.users below
-- completes the profile the moment the phone is confirmed. Nothing else to
-- change.
--
-- Backfill for existing accounts: supabase/queries/backfill_stats_and_badges.sql.

-- ---------------------------------------------------------------------------
-- Rules (the non-badge numbers). Internal.
-- ---------------------------------------------------------------------------
create or replace function public._badge_rules()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    -- Profile completion needs a confirmed phone (auth.users.phone_confirmed_at).
    'require_phone', false,
    -- Check-in opens this long before the event starts.
    'checkin_opens_minutes_before', 15,
    -- A check-in QR code works this long (the app rotates it sooner).
    'checkin_token_seconds', 30,
    -- How close to the event's real spot a check-in must be, same numbers as
    -- the connect QR codes: at least 300 m, at most 1 km, GPS accuracy worse
    -- than 1 km is refused.
    'checkin_min_distance_m', 300,
    'checkin_max_distance_m', 1000,
    'checkin_max_accuracy_m', 1000,
    -- Checked-in attendees (not counting the host) for an event to count
    -- toward the host's "Events hosted".
    'hosted_min_checkins', 3
  );
$$;

revoke execute on function public._badge_rules() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profile_stats (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  in_person_connections integer not null default 0 check (in_person_connections >= 0),
  acquaintances integer not null default 0 check (acquaintances >= 0),
  events_attended integer not null default 0 check (events_attended >= 0),
  events_hosted integer not null default 0 check (events_hosted >= 0),
  updated_at timestamptz not null default now()
);

-- The badge config. Readable by everyone signed in (names, descriptions);
-- only changed by migrations.
create table public.badge_definitions (
  key text primary key check (key ~ '^[a-z_]{2,40}$'),
  name text not null check (char_length(name) between 1 and 40),
  description text not null check (char_length(description) between 1 and 200),
  -- Placeholder icon (an emoji) until real artwork exists.
  icon text not null,
  -- How it's drawn: founder is the most prestigious; supporter is styled as
  -- supporting the app, not as a rank.
  style text not null check (style in ('founder', 'early_member', 'supporter', 'milestone')),
  -- What earns it. Acquaintances are deliberately not a possible type.
  criteria jsonb not null check (
    criteria ->> 'type' in ('member_number', 'supporter', 'in_person_connections', 'events_attended', 'events_hosted')
  ),
  numbered boolean not null default false,
  sort_order integer not null
);

insert into public.badge_definitions (key, name, description, icon, style, criteria, numbered, sort_order) values
  ('founder', 'Founder', 'One of the first 200 people to complete a profile on Bolas.', '🏛️', 'founder',
    '{"type": "member_number", "min": 1, "max": 200}', true, 10),
  ('early_member', 'Early Member', 'One of the first 1,000 people to complete a profile on Bolas.', '🌱', 'early_member',
    '{"type": "member_number", "min": 201, "max": 1000}', true, 20),
  ('supporter', 'Supporter', 'Backed Bolas early with lifetime Premium.', '💛', 'supporter',
    '{"type": "supporter", "cap": 250}', true, 30),
  ('first_handshake', 'First Handshake', 'Made your first in-person connection.', '🤝', 'milestone',
    '{"type": "in_person_connections", "threshold": 1}', false, 100),
  ('connector', 'Connector', 'Met 10 people in person.', '🔗', 'milestone',
    '{"type": "in_person_connections", "threshold": 10}', false, 110),
  ('super_connector', 'Super Connector', 'Met 50 people in person.', '⚡', 'milestone',
    '{"type": "in_person_connections", "threshold": 50}', false, 120),
  ('web_weaver', 'Web Weaver', 'Met 100 people in person.', '🕸️', 'milestone',
    '{"type": "in_person_connections", "threshold": 100}', false, 130),
  ('showed_up', 'Showed Up', 'Checked in to your first event.', '📍', 'milestone',
    '{"type": "events_attended", "threshold": 1}', false, 200),
  ('regular', 'Regular', 'Checked in to 10 events.', '🎟️', 'milestone',
    '{"type": "events_attended", "threshold": 10}', false, 210),
  ('host', 'Host', 'Hosted an event where 3+ people checked in.', '🎤', 'milestone',
    '{"type": "events_hosted", "threshold": 1}', false, 300),
  ('community_builder', 'Community Builder', 'Hosted 10 events where 3+ people checked in.', '🏗️', 'milestone',
    '{"type": "events_hosted", "threshold": 10}', false, 310);

create table public.user_badges (
  user_id uuid not null references public.profiles (id) on delete cascade,
  badge_key text not null references public.badge_definitions (key),
  number integer check (number > 0),
  awarded_at timestamptz not null default now(),
  -- When the "you earned a badge" toast was shown.
  seen_at timestamptz,
  -- 1-3 = shown at the top of the profile, in that order.
  featured_rank smallint check (featured_rank between 1 and 3),
  primary key (user_id, badge_key),
  unique (badge_key, number),
  unique (user_id, featured_rank)
);

-- Number dispensers. Taking a number = update ... returning, which locks the
-- row until the transaction ends: a second caller waits, then gets the next
-- number. A rolled-back transaction gives its number back (no gaps).
create table public.badge_counters (
  key text primary key check (key in ('member', 'supporter')),
  last_number integer not null default 0 check (last_number >= 0)
);

insert into public.badge_counters (key) values ('member'), ('supporter');

create table public.event_checkins (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  -- One check-in per person per event.
  primary key (event_id, user_id)
);

create index event_checkins_user_idx on public.event_checkins (user_id);

-- Rotating check-in QR codes. Many attendees can scan the same code; each
-- lives 30 s and only works near the event.
create table public.event_checkin_tokens (
  token text primary key check (token ~ '^[0-9a-f]{32}$'),
  event_id uuid not null references public.events (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index event_checkin_tokens_event_idx on public.event_checkin_tokens (event_id, created_at desc);

-- When the event first reached 3 check-ins (counted toward the host once).
alter table public.events add column checkin_qualified_at timestamptz;

-- Profile completion, member number, lifetime premium. Server-managed
-- (guard below) and not in the public column grant: your own via
-- get_my_profile(); others see your number only through your badges.
alter table public.profiles
  add column profile_completed_at timestamptz,
  add column member_number integer unique check (member_number > 0),
  add column lifetime_premium boolean not null default false;

-- RLS on everything. Only badge definitions are readable directly; the rest
-- goes through the functions below.
alter table public.profile_stats enable row level security;
alter table public.badge_definitions enable row level security;
alter table public.user_badges enable row level security;
alter table public.badge_counters enable row level security;
alter table public.event_checkins enable row level security;
alter table public.event_checkin_tokens enable row level security;

create policy "Badge definitions are readable by signed-in users"
  on public.badge_definitions for select to authenticated using (true);

-- Same two-step rule as every other client-readable table (20260930000000).
create policy "Two-step code required" on public.badge_definitions
  as restrictive for all to authenticated
  using ((select public._mfa_ok())) with check ((select public._mfa_ok()));

revoke all on public.profile_stats, public.user_badges, public.badge_counters,
  public.event_checkins, public.event_checkin_tokens from anon, authenticated;
revoke all on public.badge_definitions from anon, authenticated;
grant select on public.badge_definitions to authenticated;

-- ---------------------------------------------------------------------------
-- Badges are permanent
-- ---------------------------------------------------------------------------

-- No deletes, and only seen_at / featured_rank may change. The one exception
-- is an account deletion: by the time the cascade reaches user_badges, the
-- profile row is already gone.
create or replace function public.user_badges_permanent()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if exists (select 1 from public.profiles p where p.id = old.user_id) then
      raise exception 'badges_are_permanent' using errcode = '42501';
    end if;
    return old;
  end if;

  if new.user_id is distinct from old.user_id
     or new.badge_key is distinct from old.badge_key
     or new.number is distinct from old.number
     or new.awarded_at is distinct from old.awarded_at then
    raise exception 'badges_are_permanent' using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.user_badges_permanent() from public, anon, authenticated;

create trigger user_badges_permanent
  before update or delete on public.user_badges
  for each row execute function public.user_badges_permanent();

-- ---------------------------------------------------------------------------
-- Awarding
-- ---------------------------------------------------------------------------

-- Milestone badges for one person from their current stats. Safe to call any
-- time: already-earned badges are skipped, nothing is ever taken away.
create or replace function public._award_milestone_badges(p_uid uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.user_badges (user_id, badge_key)
  select s.user_id, d.key
  from public.profile_stats s
  join public.badge_definitions d
    on d.criteria ->> 'type' in ('in_person_connections', 'events_attended', 'events_hosted')
  where s.user_id = p_uid
    and exists (select 1 from public.profiles p where p.id = p_uid)
    and case d.criteria ->> 'type'
          when 'in_person_connections' then s.in_person_connections
          when 'events_attended' then s.events_attended
          when 'events_hosted' then s.events_hosted
        end >= (d.criteria ->> 'threshold')::integer
  on conflict (user_id, badge_key) do nothing;
$$;

revoke execute on function public._award_milestone_badges(uuid) from public, anon, authenticated;

-- Founder or Early Member for a member number (whichever range it's in; none
-- past the last range).
create or replace function public._award_member_badge(p_uid uuid, p_number integer)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.user_badges (user_id, badge_key, number)
  select p_uid, d.key, p_number
  from public.badge_definitions d
  where d.criteria ->> 'type' = 'member_number'
    and p_number between (d.criteria ->> 'min')::integer and (d.criteria ->> 'max')::integer
  on conflict (user_id, badge_key) do nothing;
$$;

revoke execute on function public._award_member_badge(uuid, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Connection counters
-- ---------------------------------------------------------------------------

-- Recounts one person's accepted connections (pending requests don't count)
-- and awards any milestone they've now reached. A per-person lock makes two
-- simultaneous changes count one after the other, so neither is missed.
-- Skips people whose profile is being deleted.
create or replace function public._refresh_connection_stats(p_uid uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_uid is null or not exists (select 1 from public.profiles p where p.id = p_uid) then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('bolas.profile_stats:' || p_uid::text, 0));

  insert into public.profile_stats (user_id, in_person_connections, acquaintances, updated_at)
  select
    p_uid,
    count(*) filter (where c.level = 'in_person'),
    count(*) filter (where c.level = 'acquaintance'),
    now()
  from public.connections c
  where c.status = 'accepted'
    and (c.requester_id = p_uid or c.addressee_id = p_uid)
  on conflict (user_id) do update set
    in_person_connections = excluded.in_person_connections,
    acquaintances = excluded.acquaintances,
    updated_at = excluded.updated_at;

  perform public._award_milestone_badges(p_uid);
end;
$$;

revoke execute on function public._refresh_connection_stats(uuid) from public, anon, authenticated;

-- Every connections write (from the app or any function) refreshes both
-- people. Sorted, so two transactions always lock people in the same order.
create or replace function public.connections_refresh_stats()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_uid uuid;
begin
  -- NEW isn't set on DELETE and OLD isn't set on INSERT, so each case reads
  -- only the row it has.
  if tg_op = 'INSERT' then
    v_ids := array[new.requester_id, new.addressee_id];
  elsif tg_op = 'DELETE' then
    v_ids := array[old.requester_id, old.addressee_id];
  else
    v_ids := array[new.requester_id, new.addressee_id, old.requester_id, old.addressee_id];
  end if;

  for v_uid in
    select distinct u from unnest(v_ids) as u where u is not null order by u
  loop
    perform public._refresh_connection_stats(v_uid);
  end loop;
  return null;
end;
$$;

revoke execute on function public.connections_refresh_stats() from public, anon, authenticated;

create trigger connections_refresh_stats
  after insert or update or delete on public.connections
  for each row execute function public.connections_refresh_stats();

-- ---------------------------------------------------------------------------
-- Profile completion and member numbers
-- ---------------------------------------------------------------------------

-- The one definition of a "completed" profile. To require a verified phone,
-- flip require_phone in _badge_rules(); see the header.
create or replace function public._profile_is_complete(p public.profiles)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p.username is not null
    and nullif(btrim(coalesce(p.full_name, '')), '') is not null
    and nullif(btrim(coalesce(p.city, '')), '') is not null
    and p.business_stage is not null
    and (
      not coalesce((public._badge_rules() ->> 'require_phone')::boolean, false)
      or exists (
        select 1 from auth.users u
        where u.id = p.id and u.phone_confirmed_at is not null
      )
    );
$$;

revoke execute on function public._profile_is_complete(public.profiles) from public, anon, authenticated;

-- Before each profile write:
--   - clients can't set profile_completed_at, member_number or
--     lifetime_premium (errors on update; ignored on insert);
--   - the first time the profile counts as complete, it's stamped and gets
--     the next member number. Both stay even if a field is cleared later.
create or replace function public.profiles_completion()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_number integer;
begin
  if public._is_untrusted_write() then
    if tg_op = 'INSERT' then
      new.profile_completed_at := null;
      new.member_number := null;
      new.lifetime_premium := false;
    elsif new.profile_completed_at is distinct from old.profile_completed_at
       or new.member_number is distinct from old.member_number
       or new.lifetime_premium is distinct from old.lifetime_premium then
      raise exception 'server_managed_field' using errcode = '42501';
    end if;
  end if;

  if new.profile_completed_at is null and public._profile_is_complete(new) then
    new.profile_completed_at := now();
    if new.member_number is null then
      update public.badge_counters
      set last_number = last_number + 1
      where key = 'member'
      returning last_number into v_number;
      new.member_number := v_number;
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.profiles_completion() from public, anon, authenticated;

create trigger profiles_completion
  before insert or update on public.profiles
  for each row execute function public.profiles_completion();

-- After the number is saved: the Founder / Early Member badge (the badge row
-- needs the profile row to exist, so this can't be in the before trigger).
create or replace function public.profiles_award_member_badge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.member_number is not null
     and (tg_op = 'INSERT' or old.member_number is null) then
    perform public._award_member_badge(new.id, new.member_number);
  end if;
  return null;
end;
$$;

revoke execute on function public.profiles_award_member_badge() from public, anon, authenticated;

create trigger profiles_award_member_badge
  after insert or update on public.profiles
  for each row execute function public.profiles_award_member_badge();

-- For when phone verification is required: confirming a phone re-checks the
-- profile right away. Harmless while require_phone is false.
create or replace function public.auth_phone_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.phone_confirmed_at is not null and old.phone_confirmed_at is null then
    perform set_config('bolas.trusted_write', 'on', true);
    update public.profiles set updated_at = now()
    where id = new.id and profile_completed_at is null;
    perform set_config('bolas.trusted_write', 'off', true);
  end if;
  return null;
end;
$$;

revoke execute on function public.auth_phone_confirmed() from public, anon, authenticated;

create trigger on_auth_phone_confirmed
  after update of phone_confirmed_at on auth.users
  for each row execute function public.auth_phone_confirmed();

-- ---------------------------------------------------------------------------
-- Lifetime premium + Supporter badge
-- ---------------------------------------------------------------------------

create or replace function public._supporter_cap()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select (criteria ->> 'cap')::integer from public.badge_definitions where key = 'supporter';
$$;

revoke execute on function public._supporter_cap() from public, anon, authenticated;

-- For the "N spots left" countdown. 0 = sold out (hide/disable lifetime).
create or replace function public.supporter_spots_remaining()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(public._supporter_cap() - c.last_number, 0)
  from public.badge_counters c
  where c.key = 'supporter';
$$;

revoke execute on function public.supporter_spots_remaining() from public, anon;
grant execute on function public.supporter_spots_remaining() to authenticated;

-- Grants lifetime premium and, the first time, the next Supporter number.
-- Refuses once the cap is reached (checked while holding the counter row,
-- so two buyers can't both take the last spot). Someone who had it before
-- keeps their original number. Internal: the admin toggle below and, later,
-- the purchase webhook.
-- Returns { outcome: 'granted' | 'already' | 'sold_out' | 'not_found', number }.
create or replace function public._grant_lifetime_premium(p_uid uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_number integer;
begin
  select * into v_profile from public.profiles where id = p_uid for update;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  if v_profile.lifetime_premium then
    return jsonb_build_object('outcome', 'already',
      'number', (select number from public.user_badges where user_id = p_uid and badge_key = 'supporter'));
  end if;

  select ub.number into v_number
  from public.user_badges ub
  where ub.user_id = p_uid and ub.badge_key = 'supporter';

  if v_number is null then
    update public.badge_counters
    set last_number = last_number + 1
    where key = 'supporter' and last_number < public._supporter_cap()
    returning last_number into v_number;

    if v_number is null then
      return jsonb_build_object('outcome', 'sold_out');
    end if;

    insert into public.user_badges (user_id, badge_key, number)
    values (p_uid, 'supporter', v_number);
  end if;

  perform set_config('bolas.trusted_write', 'on', true);
  update public.profiles set lifetime_premium = true, is_premium = true where id = p_uid;
  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object('outcome', 'granted', 'number', v_number);
end;
$$;

revoke execute on function public._grant_lifetime_premium(uuid) from public, anon, authenticated;

-- Admin-only test toggle until in-app purchase exists. Turning it off keeps
-- the Supporter badge (badges are permanent). Until subscriptions exist,
-- premium comes only from lifetime, so off also turns is_premium off;
-- revisit when in-app purchase lands.
create or replace function public.admin_set_lifetime_premium(p_user_id uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._require_admin();

  if p_on then
    return public._grant_lifetime_premium(p_user_id);
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('outcome', 'not_found');
  end if;
  perform set_config('bolas.trusted_write', 'on', true);
  update public.profiles set lifetime_premium = false, is_premium = false where id = p_user_id;
  perform set_config('bolas.trusted_write', 'off', true);
  return jsonb_build_object('outcome', 'removed');
end;
$$;

revoke execute on function public.admin_set_lifetime_premium(uuid, boolean) from public, anon;
grant execute on function public.admin_set_lifetime_premium(uuid, boolean) to authenticated;

-- For the admin screen: whether someone has lifetime premium, and their
-- Supporter number if any.
create or replace function public.admin_get_lifetime_premium(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._require_admin();
  return (
    select jsonb_build_object(
      'lifetime_premium', p.lifetime_premium,
      'supporter_number', (select ub.number from public.user_badges ub where ub.user_id = p.id and ub.badge_key = 'supporter')
    )
    from public.profiles p where p.id = p_user_id
  );
end;
$$;

revoke execute on function public.admin_get_lifetime_premium(uuid) from public, anon;
grant execute on function public.admin_get_lifetime_premium(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Event check-in
-- ---------------------------------------------------------------------------

-- The check-in window for an event: opens 15 min before the start, closes
-- when the event ends (no end time = 3 hours after the start).
create or replace function public._checkin_window(p_starts_at timestamptz, p_ends_at timestamptz)
returns table (opens_at timestamptz, closes_at timestamptz)
language sql
immutable
set search_path = public
as $$
  select
    p_starts_at - make_interval(mins => (public._badge_rules() ->> 'checkin_opens_minutes_before')::integer),
    coalesce(p_ends_at, p_starts_at + interval '3 hours');
$$;

revoke execute on function public._checkin_window(timestamptz, timestamptz) from public, anon, authenticated;

-- Host only: a fresh check-in code for their event while the window is open.
-- Returns { outcome: 'ok', token, expires_at, checkin_count, closes_at }
-- or { outcome: 'not_found' | 'not_open' (with opens_at) | 'ended' }.
create or replace function public.create_event_checkin_token(p_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_event public.events%rowtype;
  v_opens timestamptz;
  v_closes timestamptz;
  v_token text;
  v_expires timestamptz;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_event from public.events e
  where e.id = p_event_id and e.creator_id = v_me and e.status = 'active';
  if not found or public.is_suspended(v_me) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  select w.opens_at, w.closes_at into v_opens, v_closes
  from public._checkin_window(v_event.starts_at, v_event.ends_at) w;
  if now() < v_opens then
    return jsonb_build_object('outcome', 'not_open', 'opens_at', v_opens);
  end if;
  if now() > v_closes then
    return jsonb_build_object('outcome', 'ended');
  end if;

  delete from public.event_checkin_tokens where expires_at < now() - interval '1 hour';

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_expires := now() + make_interval(secs => (public._badge_rules() ->> 'checkin_token_seconds')::integer);
  insert into public.event_checkin_tokens (token, event_id, expires_at)
  values (v_token, p_event_id, v_expires);

  return jsonb_build_object(
    'outcome', 'ok',
    'token', v_token,
    'expires_at', v_expires,
    'closes_at', v_closes,
    'checkin_count', (select count(*) from public.event_checkins c where c.event_id = p_event_id)
  );
end;
$$;

revoke execute on function public.create_event_checkin_token(uuid) from public, anon;
grant execute on function public.create_event_checkin_token(uuid) to authenticated;

-- Attendee: check in with a scanned code and this phone's location.
-- Returns { outcome: 'checked_in', event_id, event_title } or
-- { outcome: 'invalid' | 'expired' | 'closed' | 'host' | 'unavailable' |
--   'location_required' | 'poor_location' | 'too_far' | 'already_checked_in' }.
-- Same visibility as seeing the event (public or connected to the host, no
-- block either way, host not suspended); suspended callers and callers who
-- haven't accepted the current Terms can't check in, same as RSVPs.
create or replace function public.redeem_event_checkin(
  p_token text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_m double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  r jsonb := public._badge_rules();
  v_tok public.event_checkin_tokens%rowtype;
  v_event public.events%rowtype;
  v_spot_lat double precision;
  v_spot_lng double precision;
  v_opens timestamptz;
  v_closes timestamptz;
  v_rows integer;
  v_count integer;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  select * into v_tok from public.event_checkin_tokens t where t.token = p_token;
  if not found then
    return jsonb_build_object('outcome', 'invalid');
  end if;
  if v_tok.expires_at < now() then
    return jsonb_build_object('outcome', 'expired');
  end if;

  select * into v_event from public.events e where e.id = v_tok.event_id;
  if not found
     or v_event.status <> 'active'
     or public.is_suspended(v_event.creator_id)
     or public._blocked_between(v_me, v_event.creator_id)
     or (v_event.visibility <> 'public' and not public.is_connected_to(v_event.creator_id)) then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  if v_event.creator_id = v_me then
    return jsonb_build_object('outcome', 'host');
  end if;

  if public.is_suspended(v_me) or not public.has_accepted_current_terms(v_me) then
    return jsonb_build_object('outcome', 'unavailable');
  end if;

  select w.opens_at, w.closes_at into v_opens, v_closes
  from public._checkin_window(v_event.starts_at, v_event.ends_at) w;
  if now() < v_opens or now() > v_closes then
    return jsonb_build_object('outcome', 'closed');
  end if;

  -- Location: near the event's real spot (not the fuzzed map point).
  if p_lat is null or p_lng is null or p_accuracy_m is null then
    return jsonb_build_object('outcome', 'location_required');
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy_m <= 0 then
    return jsonb_build_object('outcome', 'location_required');
  end if;
  if p_accuracy_m > (r ->> 'checkin_max_accuracy_m')::float8 then
    return jsonb_build_object('outcome', 'poor_location');
  end if;

  select l.latitude, l.longitude into v_spot_lat, v_spot_lng
  from public.event_locations l where l.event_id = v_event.id;
  if v_spot_lat is null then
    v_spot_lat := v_event.approx_latitude;
    v_spot_lng := v_event.approx_longitude;
  end if;

  if public._distance_m(p_lat, p_lng, v_spot_lat, v_spot_lng)
     > greatest((r ->> 'checkin_min_distance_m')::float8,
                least(p_accuracy_m, (r ->> 'checkin_max_distance_m')::float8)) then
    return jsonb_build_object('outcome', 'too_far');
  end if;

  -- One check-in at a time per event, so the 3-check-in count below can't
  -- be missed by two people checking in at the same moment.
  perform 1 from public.events e where e.id = v_event.id for update;

  insert into public.event_checkins (event_id, user_id)
  values (v_event.id, v_me)
  on conflict (event_id, user_id) do nothing;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return jsonb_build_object('outcome', 'already_checked_in',
      'event_id', v_event.id, 'event_title', v_event.title);
  end if;

  -- Lifetime counter for the attendee.
  insert into public.profile_stats (user_id, events_attended, updated_at)
  values (v_me, 1, now())
  on conflict (user_id) do update set
    events_attended = public.profile_stats.events_attended + 1,
    updated_at = now();
  perform public._award_milestone_badges(v_me);

  -- The host's credit, once per event, at the 3rd check-in (host excluded:
  -- the host can't check in to their own event).
  select count(*) into v_count from public.event_checkins c where c.event_id = v_event.id;
  if v_count >= (r ->> 'hosted_min_checkins')::integer and v_event.checkin_qualified_at is null then
    update public.events set checkin_qualified_at = now()
    where id = v_event.id and checkin_qualified_at is null;
    if found and exists (select 1 from public.profiles p where p.id = v_event.creator_id) then
      insert into public.profile_stats (user_id, events_hosted, updated_at)
      values (v_event.creator_id, 1, now())
      on conflict (user_id) do update set
        events_hosted = public.profile_stats.events_hosted + 1,
        updated_at = now();
      perform public._award_milestone_badges(v_event.creator_id);
    end if;
  end if;

  return jsonb_build_object('outcome', 'checked_in', 'event_id', v_event.id, 'event_title', v_event.title);
end;
$$;

revoke execute on function public.redeem_event_checkin(text, double precision, double precision, double precision) from public, anon;
grant execute on function public.redeem_event_checkin(text, double precision, double precision, double precision) to authenticated;

-- For the event detail screen: the window, whether I'm checked in, and (host
-- only) how many have checked in. Nothing for an event I can't see.
create or replace function public.get_event_checkin_info(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_event public.events%rowtype;
  v_opens timestamptz;
  v_closes timestamptz;
  v_is_host boolean;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_event from public.events e where e.id = p_event_id;
  if not found then
    return null;
  end if;
  v_is_host := v_event.creator_id = v_me;
  if not v_is_host and (
       v_event.status <> 'active'
       or public.is_suspended(v_event.creator_id)
       or public._blocked_between(v_me, v_event.creator_id)
       or (v_event.visibility <> 'public' and not public.is_connected_to(v_event.creator_id))) then
    return null;
  end if;

  select w.opens_at, w.closes_at into v_opens, v_closes
  from public._checkin_window(v_event.starts_at, v_event.ends_at) w;

  return jsonb_build_object(
    'is_host', v_is_host,
    'opens_at', v_opens,
    'closes_at', v_closes,
    'is_open', now() between v_opens and v_closes and v_event.status = 'active',
    'checked_in', exists (select 1 from public.event_checkins c where c.event_id = p_event_id and c.user_id = v_me),
    'checkin_count', case when v_is_host
      then (select count(*) from public.event_checkins c where c.event_id = p_event_id) end,
    'counts_as_hosted', case when v_is_host then v_event.checkin_qualified_at is not null end
  );
end;
$$;

revoke execute on function public.get_event_checkin_info(uuid) from public, anon;
grant execute on function public.get_event_checkin_info(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Reading stats and badges
-- ---------------------------------------------------------------------------

-- A profile's stats. Acquaintances only for the owner (null for everyone
-- else). No row if the profile is hidden from me (blocked either way,
-- suspended), same as the profile itself.
create or replace function public.get_profile_stats(p_user_id uuid)
returns table (
  in_person_connections integer,
  events_attended integer,
  events_hosted integer,
  acquaintances integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select
    coalesce(s.in_person_connections, 0),
    coalesce(s.events_attended, 0),
    coalesce(s.events_hosted, 0),
    case when p.id = v_me then coalesce(s.acquaintances, 0) end
  from public.profiles p
  left join public.profile_stats s on s.user_id = p.id
  where p.id = p_user_id
    and (
      p.id = v_me
      or (not public._blocked_between(v_me, p.id) and not public.is_suspended(p.id))
    );
end;
$$;

revoke execute on function public.get_profile_stats(uuid) from public, anon;
grant execute on function public.get_profile_stats(uuid) to authenticated;

-- A profile's badges (featured first, then in config order). Same
-- visibility as the profile.
create or replace function public.get_profile_badges(p_user_id uuid)
returns table (
  badge_key text,
  number integer,
  awarded_at timestamptz,
  featured_rank smallint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select ub.badge_key, ub.number, ub.awarded_at, ub.featured_rank
  from public.user_badges ub
  join public.badge_definitions d on d.key = ub.badge_key
  join public.profiles p on p.id = ub.user_id
  where ub.user_id = p_user_id
    and (
      p.id = v_me
      or (not public._blocked_between(v_me, p.id) and not public.is_suspended(p.id))
    )
  order by ub.featured_rank nulls last, d.sort_order;
end;
$$;

revoke execute on function public.get_profile_badges(uuid) from public, anon;
grant execute on function public.get_profile_badges(uuid) to authenticated;

-- My badges that haven't had a toast yet (oldest first).
create or replace function public.get_unseen_badges()
returns table (badge_key text, number integer, awarded_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select ub.badge_key, ub.number, ub.awarded_at
  from public.user_badges ub
  where ub.user_id = auth.uid() and ub.seen_at is null
  order by ub.awarded_at, ub.badge_key;
end;
$$;

revoke execute on function public.get_unseen_badges() from public, anon;
grant execute on function public.get_unseen_badges() to authenticated;

create or replace function public.mark_badges_seen(p_badge_keys text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  update public.user_badges ub
  set seen_at = now()
  where ub.user_id = auth.uid()
    and ub.seen_at is null
    and ub.badge_key = any (coalesce(p_badge_keys, '{}'));
end;
$$;

revoke execute on function public.mark_badges_seen(text[]) from public, anon;
grant execute on function public.mark_badges_seen(text[]) to authenticated;

-- Choose up to 3 of my badges to feature, in order. Replaces the old
-- choice; an empty list clears it.
-- Returns { outcome: 'ok' | 'too_many' | 'not_owned' | 'duplicate' }.
create or replace function public.set_featured_badges(p_badge_keys text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_keys text[] := coalesce(p_badge_keys, '{}');
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if cardinality(v_keys) > 3 then
    return jsonb_build_object('outcome', 'too_many');
  end if;
  if cardinality(v_keys) <> (select count(distinct k) from unnest(v_keys) k) then
    return jsonb_build_object('outcome', 'duplicate');
  end if;
  if exists (
    select 1 from unnest(v_keys) k
    where not exists (select 1 from public.user_badges ub where ub.user_id = v_me and ub.badge_key = k)
  ) then
    return jsonb_build_object('outcome', 'not_owned');
  end if;

  update public.user_badges set featured_rank = null
  where user_id = v_me and featured_rank is not null;

  update public.user_badges ub
  set featured_rank = k.ord
  from unnest(v_keys) with ordinality as k(badge_key, ord)
  where ub.user_id = v_me and ub.badge_key = k.badge_key;

  return jsonb_build_object('outcome', 'ok');
end;
$$;

revoke execute on function public.set_featured_badges(text[]) from public, anon;
grant execute on function public.set_featured_badges(text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- One-time backfill (run by hand: supabase/queries/backfill_stats_and_badges.sql)
-- ---------------------------------------------------------------------------

-- Safe to run more than once. For existing accounts: recounts connection
-- stats (+ milestone badges), then completes and numbers profiles that are
-- already complete, in sign-up order. Event stats start at 0 (no check-ins
-- existed before this migration). No client grants.
create or replace function public.backfill_stats_and_badges()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_stats integer := 0;
  v_numbered integer := 0;
begin
  for v_id in select p.id from public.profiles p order by p.created_at, p.id loop
    perform public._refresh_connection_stats(v_id);
    v_stats := v_stats + 1;
  end loop;

  perform set_config('bolas.trusted_write', 'on', true);
  for v_id in
    select p.id from public.profiles p
    where p.profile_completed_at is null
    order by p.created_at, p.id
  loop
    -- Touch the row; the completion trigger decides and numbers it.
    update public.profiles set updated_at = now() where id = v_id;
    if (select member_number from public.profiles where id = v_id) is not null then
      v_numbered := v_numbered + 1;
    end if;
  end loop;
  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object('profiles_recounted', v_stats, 'profiles_numbered', v_numbered);
end;
$$;

revoke execute on function public.backfill_stats_and_badges() from public, anon, authenticated;
