-- Safer map events, part 3: attendee privacy.
-- Plan: docs/plans/event-safety.md (Phase 3).
--
-- Everyone sees how many people are going. The host (and admins) see the
-- full list; everyone else sees only themselves plus their own connections
-- who are going. RSVPs are limited to active events that haven't ended, and
-- to max_rsvps_per_day per person, so nobody can tap Going on every event
-- just to collect exact locations (part 2 unlocks them on RSVP).

-- ---------------------------------------------------------------------------
-- Stored going count
-- ---------------------------------------------------------------------------

-- Once attendee rows are private, count(*) run by the viewer would only
-- count the rows they're allowed to see. So the count is stored on the
-- event and kept up to date by a trigger.
alter table public.events
  add column going_count integer not null default 0 check (going_count >= 0);

update public.events e
set going_count = (select count(*) from public.event_attendees a where a.event_id = e.id);

-- updated_at means "the host edited this". Only bump it when a host-editable
-- column is in the update, so the counter trigger below doesn't touch it.
drop trigger on_events_updated on public.events;
create trigger on_events_updated
  before update of title, description, starts_at, ends_at, visibility, status
  on public.events
  for each row execute function public.handle_updated_at();

-- ---------------------------------------------------------------------------
-- RSVP log: the daily limit counts this, not event_attendees
-- ---------------------------------------------------------------------------

-- Counting current attendee rows could be dodged by tapping Going, reading
-- the location, and un-tapping: the row disappears and the count never
-- grows. This log keeps every RSVP (hosts' automatic ones aren't logged).
create table public.event_rsvp_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  event_id uuid references public.events (id) on delete set null,
  created_at timestamptz not null default now()
);

create index event_rsvp_log_user_idx on public.event_rsvp_log (user_id, created_at desc);

-- RLS on with no policies: unreachable from clients.
alter table public.event_rsvp_log enable row level security;

grant select on public.event_rsvp_log to anon;
grant select, insert, update, delete on public.event_rsvp_log to authenticated;
grant select, insert, update, delete on public.event_rsvp_log to service_role;

-- ---------------------------------------------------------------------------
-- Triggers on event_attendees
-- ---------------------------------------------------------------------------

-- Before an RSVP: enforce max_rsvps_per_day. The host's own automatic RSVP
-- and admins are exempt. Security definer so it can read events and the log
-- no matter what the caller can see.
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
     or exists (select 1 from public.app_admins a where a.user_id = new.user_id) then
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

create trigger event_attendees_rate_limit
  before insert on public.event_attendees
  for each row execute function public.event_attendees_rate_limit();

-- After an RSVP is added or removed: keep going_count right, and log new
-- RSVPs. Runs only for rows that really changed, so a double-tapped Going
-- (insert ... on conflict do nothing) isn't counted twice.
create or replace function public.event_attendees_after_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    update public.events set going_count = going_count + 1 where id = new.event_id;

    if not exists (
      select 1 from public.events e where e.id = new.event_id and e.creator_id = new.user_id
    ) then
      insert into public.event_rsvp_log (user_id, event_id) values (new.user_id, new.event_id);
      -- Housekeeping: the limit only looks back 24 hours.
      delete from public.event_rsvp_log
      where user_id = new.user_id and created_at < now() - interval '7 days';
    end if;
    return new;
  else
    -- When the whole event is being deleted this updates nothing, which is fine.
    update public.events set going_count = greatest(going_count - 1, 0) where id = old.event_id;
    return old;
  end if;
end;
$$;

revoke execute on function public.event_attendees_after_change() from public, anon, authenticated;

create trigger event_attendees_after_change
  after insert or delete on public.event_attendees
  for each row execute function public.event_attendees_after_change();

-- ---------------------------------------------------------------------------
-- Policies on event_attendees
-- ---------------------------------------------------------------------------

drop policy "Users can view attendees of visible events" on public.event_attendees;
create policy "Attendees visible to self, host, admins, and your connections"
  on public.event_attendees
  for select
  to authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or (
      -- Still has to be an event you can see (the events policy applies here).
      exists (select 1 from public.events e where e.id = event_attendees.event_id)
      and (
        exists (
          select 1 from public.events e
          where e.id = event_attendees.event_id and e.creator_id = auth.uid()
        )
        or public.is_connected_to(user_id)
      )
    )
  );

-- RSVP only as yourself, only to a visible, active event that hasn't ended.
drop policy "Users can RSVP to visible events" on public.event_attendees;
create policy "Users can RSVP to visible active events"
  on public.event_attendees
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.events e
      where e.id = event_attendees.event_id
        and e.status = 'active'
        and coalesce(e.ends_at, e.starts_at + interval '3 hours') > now()
    )
  );

-- Un-RSVP only yourself, and never from your own event (the host always
-- counts as going). Written as "not the host" rather than "a visible event
-- I don't host", so people can still leave an event that was hidden or
-- removed after they RSVP'd.
drop policy "Users can remove their own RSVP" on public.event_attendees;
create policy "Users can remove their own RSVP"
  on public.event_attendees
  for delete
  to authenticated
  using (
    user_id = auth.uid()
    and not exists (
      select 1 from public.events e
      where e.id = event_attendees.event_id and e.creator_id = auth.uid()
    )
  );

-- ---------------------------------------------------------------------------
-- Who's going, for the event screen
-- ---------------------------------------------------------------------------

-- Plain SQL, NOT security definer: the policies above decide who comes
-- back. The host gets everyone; others get themselves plus their
-- connections. Host first, then connections, then in RSVP order.
create or replace function public.get_event_attendees(p_event_id uuid)
returns table (
  user_id uuid,
  username text,
  full_name text,
  avatar_url text,
  is_connection boolean,
  is_host boolean
)
language sql
stable
set search_path = public
as $$
  select
    a.user_id,
    p.username,
    p.full_name,
    p.avatar_url,
    public.is_connected_to(a.user_id) as is_connection,
    coalesce(e.creator_id = a.user_id, false) as is_host
  from public.event_attendees a
  join public.profiles p on p.id = a.user_id
  left join public.events e on e.id = a.event_id
  where a.event_id = p_event_id
  order by is_host desc, is_connection desc, a.created_at;
$$;

revoke execute on function public.get_event_attendees(uuid) from public, anon;
grant execute on function public.get_event_attendees(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- event_summaries: attendee_count -> going_count
-- ---------------------------------------------------------------------------

-- Same as part 2 except the count now comes from the stored column (a view
-- can't drop a column in place, hence drop + create).
drop view public.event_summaries;
create view public.event_summaries
with (security_invoker = true)
as
select
  e.id,
  e.creator_id,
  e.title,
  e.description,
  e.approx_latitude,
  e.approx_longitude,
  l.latitude as exact_latitude,
  l.longitude as exact_longitude,
  l.location_name,
  e.starts_at,
  e.ends_at,
  e.visibility,
  e.status,
  e.time_changed_at,
  e.created_at,
  e.updated_at,
  coalesce(e.ends_at, e.starts_at + interval '3 hours') as effective_ends_at,
  p.username as creator_username,
  p.full_name as creator_full_name,
  p.avatar_url as creator_avatar_url,
  e.going_count,
  exists (
    select 1 from public.event_attendees a
    where a.event_id = e.id and a.user_id = auth.uid()
  ) as is_going
from public.events e
join public.profiles p on p.id = e.creator_id
left join public.event_locations l on l.event_id = e.id;

revoke all on public.event_summaries from anon;
grant select on public.event_summaries to authenticated;
