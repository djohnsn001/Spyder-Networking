-- Safer map events, part 4: reports, auto-hide, and admin tools.
-- Plan: docs/plans/event-safety.md (Phase 4).
--
-- Anyone who can see an event can report it once. When auto_hide_reports
-- open reports from accounts at least reporter_min_account_age_days old
-- pile up, the event is hidden until an admin looks. Admins (app_admins)
-- restore or remove events and approve or suspend hosts through the
-- admin_* RPCs below; every one of them refuses non-admins with 42501.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.event_reports (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reason text not null check (reason in (
    'spam', 'selling_or_scam', 'unsafe_location', 'harassment', 'inappropriate', 'fake', 'other'
  )),
  details text check (char_length(details) <= 500),
  status text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at timestamptz not null default now(),
  unique (event_id, reporter_id)
);

create index event_reports_reporter_idx on public.event_reports (reporter_id, created_at desc);
create index event_reports_open_idx on public.event_reports (event_id) where status = 'open';

-- RLS on with no policies: reports are only reachable through the RPCs.
alter table public.event_reports enable row level security;

grant select on public.event_reports to anon;
grant select, insert, update, delete on public.event_reports to authenticated;
grant select, insert, update, delete on public.event_reports to service_role;

-- Who did what, so two admins can tell what the other one changed.
create table public.moderation_log (
  id bigint generated always as identity primary key,
  admin_id uuid references public.profiles (id) on delete set null,
  action text not null,   -- event_active / event_removed / host_approved / host_suspended / host_cleared
  event_id uuid references public.events (id) on delete set null,
  user_id uuid references public.profiles (id) on delete set null,
  note text check (char_length(note) <= 300),
  created_at timestamptz not null default now()
);

-- RLS on with no policies: read it in the SQL editor.
alter table public.moderation_log enable row level security;

grant select on public.moderation_log to anon;
grant select, insert, update, delete on public.moderation_log to authenticated;
grant select, insert, update, delete on public.moderation_log to service_role;

-- ---------------------------------------------------------------------------
-- report_event
-- ---------------------------------------------------------------------------

-- Returns one of:
--   { outcome: 'reported', hidden }   the app always just says "Thanks, we'll take a look"
--   { outcome: 'already_reported' }
--   { outcome: 'self' }               can't report your own event
--   { outcome: 'not_found' }          no such event, or you can't see it
--   { outcome: 'invalid', field }     reason / details
--   { outcome: 'rate_limited', limit }
create or replace function public.report_event(p_event_id uuid, p_reason text, p_details text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._event_rules();
  v_me uuid := auth.uid();
  v_admin boolean := public.is_admin();
  v_event public.events%rowtype;
  v_details text := nullif(btrim(p_details), '');
  v_recent int;
  v_counted int;
  v_hidden boolean := false;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- Locked so two reports at once can't both miss the auto-hide.
  select * into v_event from public.events where id = p_event_id for update;

  -- Definer functions skip RLS, so repeat the events select policy by hand.
  if not found or not (
    v_admin
    or v_event.creator_id = v_me
    or (
      v_event.status = 'active'
      and (v_event.visibility = 'public' or public.is_connected_to(v_event.creator_id))
    )
  ) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if v_event.creator_id = v_me then
    return jsonb_build_object('outcome', 'self');
  end if;

  if p_reason is null or p_reason not in (
    'spam', 'selling_or_scam', 'unsafe_location', 'harassment', 'inappropriate', 'fake', 'other'
  ) then
    return jsonb_build_object('outcome', 'invalid', 'field', 'reason');
  end if;
  if char_length(coalesce(v_details, '')) > 500 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'details');
  end if;

  if exists (select 1 from public.event_reports where event_id = p_event_id and reporter_id = v_me) then
    return jsonb_build_object('outcome', 'already_reported');
  end if;

  if not v_admin then
    select count(*) into v_recent
    from public.event_reports
    where reporter_id = v_me and created_at > now() - interval '24 hours';
    if v_recent >= (r ->> 'max_reports_per_day')::int then
      return jsonb_build_object('outcome', 'rate_limited', 'limit', r -> 'max_reports_per_day');
    end if;
  end if;

  insert into public.event_reports (event_id, reporter_id, reason, details)
  values (p_event_id, v_me, p_reason, v_details)
  on conflict (event_id, reporter_id) do nothing;

  -- Only reports from accounts old enough count, so a handful of brand-new
  -- accounts can't knock an event off the map. Age comes from auth.users
  -- (see _account_created_at).
  select count(*) into v_counted
  from public.event_reports er
  where er.event_id = p_event_id
    and er.status = 'open'
    and public._account_created_at(er.reporter_id)
        <= now() - make_interval(days => (r ->> 'reporter_min_account_age_days')::int);

  if v_event.status = 'active' and v_counted >= (r ->> 'auto_hide_reports')::int then
    update public.events set status = 'hidden' where id = p_event_id;
    v_hidden := true;
  end if;

  return jsonb_build_object('outcome', 'reported', 'hidden', v_hidden);
end;
$$;

revoke execute on function public.report_event(uuid, text, text) from public, anon;
grant execute on function public.report_event(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Admin RPCs
-- ---------------------------------------------------------------------------

create or replace function public._require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'admin_only' using errcode = '42501';
  end if;
end;
$$;

revoke execute on function public._require_admin() from public, anon, authenticated;

-- Events that are hidden or have open reports, most recently reported first.
create or replace function public.admin_list_flagged_events()
returns table (
  event_id uuid,
  title text,
  description text,
  status text,
  visibility text,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz,
  going_count integer,
  creator_id uuid,
  creator_username text,
  creator_full_name text,
  host_status text,
  latitude double precision,
  longitude double precision,
  location_name text,
  open_reports integer,
  counted_reports integer,
  reports_by_reason jsonb,
  latest_report_at timestamptz,
  recent_reports jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_min_age interval := make_interval(
    days => (public._event_rules() ->> 'reporter_min_account_age_days')::int
  );
begin
  perform public._require_admin();

  return query
  with open_reports as (
    select er.*, pr.username as reporter_username,
      public._account_created_at(er.reporter_id) <= now() - v_min_age as counts
    from public.event_reports er
    join public.profiles pr on pr.id = er.reporter_id
    where er.status = 'open'
  )
  select
    e.id,
    e.title,
    e.description,
    e.status,
    e.visibility,
    e.starts_at,
    e.ends_at,
    e.created_at,
    e.going_count,
    e.creator_id,
    p.username,
    p.full_name,
    h.status,
    l.latitude,
    l.longitude,
    l.location_name,
    coalesce(agg.open_reports, 0)::integer,
    coalesce(agg.counted_reports, 0)::integer,
    coalesce(agg.by_reason, '{}'::jsonb),
    agg.latest_at,
    coalesce(agg.recent, '[]'::jsonb)
  from public.events e
  join public.profiles p on p.id = e.creator_id
  left join public.host_permissions h on h.user_id = e.creator_id
  left join public.event_locations l on l.event_id = e.id
  left join lateral (
    select
      count(*) as open_reports,
      count(*) filter (where o.counts) as counted_reports,
      max(o.created_at) as latest_at,
      (
        select jsonb_object_agg(x.reason, x.n)
        from (select o2.reason, count(*) as n from open_reports o2 where o2.event_id = e.id group by o2.reason) x
      ) as by_reason,
      (
        select jsonb_agg(jsonb_build_object(
          'reason', y.reason,
          'details', y.details,
          'reporter_username', y.reporter_username,
          'counts', y.counts,
          'created_at', y.created_at
        ) order by y.created_at desc)
        from (select * from open_reports o3 where o3.event_id = e.id order by o3.created_at desc limit 5) y
      ) as recent
    from open_reports o
    where o.event_id = e.id
  ) agg on true
  where e.status = 'hidden' or coalesce(agg.open_reports, 0) > 0
  order by agg.latest_at desc nulls last, e.created_at desc;
end;
$$;

revoke execute on function public.admin_list_flagged_events() from public, anon;
grant execute on function public.admin_list_flagged_events() to authenticated;

-- Restore (active) or take down (removed) an event. Restoring dismisses its
-- open reports, so it takes a fresh set to hide it again; removing marks
-- them actioned.
create or replace function public.admin_set_event_status(p_event_id uuid, p_status text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(p_note), '');
begin
  perform public._require_admin();

  if p_status is null or p_status not in ('active', 'removed') then
    return jsonb_build_object('outcome', 'invalid', 'field', 'status');
  end if;
  if char_length(coalesce(v_note, '')) > 300 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'note');
  end if;

  update public.events set status = p_status where id = p_event_id;
  if not found then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  update public.event_reports
  set status = case when p_status = 'active' then 'dismissed' else 'actioned' end
  where event_id = p_event_id and status = 'open';

  insert into public.moderation_log (admin_id, action, event_id, note)
  values (auth.uid(), 'event_' || p_status, p_event_id, v_note);

  return jsonb_build_object('outcome', 'updated', 'status', p_status);
end;
$$;

revoke execute on function public.admin_set_event_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_event_status(uuid, text, text) to authenticated;

-- Approve, suspend, or clear (p_status = null) a host's override.
-- Suspending also removes their events that haven't ended yet (active or
-- hidden) and marks those events' open reports actioned. Past events stay
-- as they are. Lifting a suspension doesn't bring removed events back.
create or replace function public.admin_set_host_status(p_user_id uuid, p_status text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(p_note), '');
  v_removed int := 0;
begin
  perform public._require_admin();

  if p_status is not null and p_status not in ('approved', 'suspended') then
    return jsonb_build_object('outcome', 'invalid', 'field', 'status');
  end if;
  if char_length(coalesce(v_note, '')) > 300 then
    return jsonb_build_object('outcome', 'invalid', 'field', 'note');
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    return jsonb_build_object('outcome', 'not_found');
  end if;

  if p_status is null then
    delete from public.host_permissions where user_id = p_user_id;
  else
    insert into public.host_permissions (user_id, status, note, updated_at, updated_by)
    values (p_user_id, p_status, v_note, now(), auth.uid())
    on conflict (user_id) do update set
      status = excluded.status,
      note = excluded.note,
      updated_at = excluded.updated_at,
      updated_by = excluded.updated_by;
  end if;

  if p_status = 'suspended' then
    with removed as (
      update public.events
      set status = 'removed'
      where creator_id = p_user_id
        and status in ('active', 'hidden')
        and coalesce(ends_at, starts_at + interval '3 hours') > now()
      returning id
    ),
    reports as (
      update public.event_reports
      set status = 'actioned'
      where status = 'open' and event_id in (select id from removed)
    )
    select count(*) into v_removed from removed;
  end if;

  insert into public.moderation_log (admin_id, action, user_id, note)
  values (
    auth.uid(),
    case when p_status is null then 'host_cleared' else 'host_' || p_status end,
    p_user_id,
    v_note
  );

  return jsonb_build_object('outcome', 'updated', 'status', p_status, 'events_removed', v_removed);
end;
$$;

revoke execute on function public.admin_set_host_status(uuid, text, text) from public, anon;
grant execute on function public.admin_set_host_status(uuid, text, text) to authenticated;

-- Username search (case-insensitive, starts-with) so an admin can find
-- someone to approve or suspend. hosting is the same shape as
-- get_my_hosting_status(), for that user.
create or replace function public.admin_find_user(p_username text)
returns table (
  user_id uuid,
  username text,
  full_name text,
  avatar_url text,
  host_status text,
  host_note text,
  hosting jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  -- Escape LIKE wildcards so "a_b" means a literal underscore.
  v_prefix text := replace(replace(replace(
    lower(btrim(coalesce(p_username, ''))), '\', '\\'), '%', '\%'), '_', '\_');
begin
  perform public._require_admin();

  if v_prefix = '' then
    return;
  end if;

  return query
  select
    p.id,
    p.username,
    p.full_name,
    p.avatar_url,
    h.status,
    h.note,
    public._hosting_status(p.id)
  from public.profiles p
  left join public.host_permissions h on h.user_id = p.id
  where lower(p.username) like v_prefix || '%'
  order by lower(p.username) = lower(btrim(p_username)) desc, p.username
  limit 20;
end;
$$;

revoke execute on function public.admin_find_user(text) from public, anon;
grant execute on function public.admin_find_user(text) to authenticated;
