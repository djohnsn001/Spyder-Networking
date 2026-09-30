-- Security H4: admin power needs two-step verification (MFA), not just a
-- password.
--
-- Before, anyone with an admin's password was an admin: is_admin() only
-- checked the app_admins table. Now it also needs the session's assurance
-- level to be aal2, which Supabase Auth only grants after a second factor
-- (an authenticator-app code) has been verified in that session.
--
-- An admin whose session is aal1 is treated exactly like a normal user:
--   - every admin_* RPC refuses them (via _require_admin -> is_admin);
--   - the policies that call is_admin() (profiles, events, event_locations,
--     event_attendees, "Admins can delete any event") and the rate-limit
--     exemptions in report_event / report_user follow automatically;
--   - the two places that read app_admins directly are fixed below:
--     _hosting_status (admin hosting perks) and the RSVP rate-limit trigger.

-- ---------------------------------------------------------------------------
-- is_admin / _require_admin
-- ---------------------------------------------------------------------------

-- auth.jwt() ->> 'aal' is set by Supabase Auth: 'aal1' after a password
-- sign-in, 'aal2' once a second factor was verified. No uid or no aal2 ->
-- false.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
     and exists (select 1 from public.app_admins where user_id = auth.uid());
$$;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Unchanged logic (it already relied on is_admin), restated so the aal2
-- requirement is visible where every admin RPC starts.
create or replace function public._require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin_only' using errcode = '42501',
      hint = 'Admins need two-step verification (an aal2 session).';
  end if;
end;
$$;

revoke execute on function public._require_admin() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- get_my_admin_status: lets the app say "Verify to open Admin"
-- ---------------------------------------------------------------------------

-- { is_admin, needs_mfa }. is_admin = admin AND aal2 (same as is_admin()).
-- needs_mfa = on the admin list but this session isn't aal2. Only ever about
-- the caller.
create or replace function public.get_my_admin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_member boolean;
  v_aal2 boolean := coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  v_member := exists (select 1 from public.app_admins where user_id = v_me);

  return jsonb_build_object(
    'is_admin', v_member and v_aal2,
    'needs_mfa', v_member and not v_aal2
  );
end;
$$;

revoke execute on function public.get_my_admin_status() from public, anon;
grant execute on function public.get_my_admin_status() to authenticated;

-- ---------------------------------------------------------------------------
-- _hosting_status: admin perks only at aal2
-- ---------------------------------------------------------------------------

-- Same as 20260928020000, except for the admin flag. For the CALLER's own
-- status (get_my_hosting_status, create_event) it uses is_admin(), so an
-- aal1 admin hosts like everyone else (trust rule, limits). For someone
-- else (admin_find_user, which only admins at aal2 can call) it still shows
-- whether that person is on the admin list.
create or replace function public._hosting_status(p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  v_min_age int := (r ->> 'min_account_age_days')::int;
  v_min_in_person int := (r ->> 'min_in_person_connections')::int;
  v_max_active int := (r ->> 'max_active_events')::int;

  v_has_profile boolean;
  v_created timestamptz;
  v_age int := 0;
  v_in_person int := 0;
  v_active int := 0;
  v_host_status text;
  v_account_suspended boolean;
  v_admin boolean;
  v_can_host boolean;
  v_can_public boolean;
  v_reason text;
begin
  select p.username is not null into v_has_profile
  from public.profiles p
  where p.id = p_uid;
  v_has_profile := coalesce(v_has_profile, false);

  v_created := public._account_created_at(p_uid);
  if v_created is not null then
    v_age := floor(extract(epoch from (now() - v_created)) / 86400)::int;
  end if;

  select count(*) into v_in_person
  from public.connections c
  where c.status = 'accepted'
    and c.level = 'in_person'
    and (c.requester_id = p_uid or c.addressee_id = p_uid);

  select count(*) into v_active
  from public.events e
  where e.creator_id = p_uid
    and e.status <> 'removed'
    and coalesce(e.ends_at, e.starts_at + interval '3 hours') > now();

  select h.status into v_host_status from public.host_permissions h where h.user_id = p_uid;
  v_account_suspended := public.is_suspended(p_uid);
  v_admin := case
    when p_uid = auth.uid() then public.is_admin()
    else exists (select 1 from public.app_admins a where a.user_id = p_uid)
  end;

  -- "is [not] distinct from" rather than "=": v_host_status is null when an
  -- admin never set one, and null = 'approved' is null, not false — which
  -- would make can_host_public null and skip the public lock entirely.
  v_can_host := v_has_profile
    and v_host_status is distinct from 'suspended'
    and not v_account_suspended;
  v_can_public := v_can_host and (
    v_admin
    or v_host_status is not distinct from 'approved'
    or (v_age >= v_min_age and v_in_person >= v_min_in_person)
  );

  v_reason := case
    when v_account_suspended or v_host_status = 'suspended' then 'suspended'
    when not v_has_profile then 'no_profile'
    when v_can_public then null
    when v_age < v_min_age then 'new_account'   -- wins when both are short
    else 'needs_in_person'
  end;

  return jsonb_build_object(
    'can_host', v_can_host,
    'can_host_public', v_can_public,
    'reason', v_reason,
    'account_age_days', v_age,
    'in_person_count', v_in_person,
    'needed_in_person', v_min_in_person,
    'needed_age_days', v_min_age,
    'active_events', v_active,
    'max_active_events', v_max_active,
    'is_admin', v_admin
  );
end;
$$;

revoke execute on function public._hosting_status(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- RSVP rate limit: the admin exemption only at aal2
-- ---------------------------------------------------------------------------

-- Same as 20260927060000, except the admin exemption now uses is_admin() for
-- the person RSVPing (clients can only RSVP as themselves).
create or replace function public.event_attendees_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent int;
begin
  if exists (select 1 from public.events e where e.id = new.event_id and e.creator_id = new.user_id)
     or (new.user_id = auth.uid() and public.is_admin()) then
    return new;
  end if;

  select count(*) into v_recent
  from public.event_rsvp_log l
  where l.user_id = new.user_id and l.created_at > now() - interval '24 hours';

  if v_recent >= (public._event_rules() ->> 'max_rsvps_per_day')::int then
    raise exception 'rsvp_rate_limited' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public.event_attendees_rate_limit() from public, anon, authenticated;
