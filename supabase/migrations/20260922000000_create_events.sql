-- Map events: builders drop a pin on the Web Map for a meetup, study
-- session, pitch night, etc.
--
-- Two tables:
--   events          — one row per event, owned by its creator
--   event_attendees — who's going (one row per person per event)
--
-- Unlike user_locations, events store the exact spot the creator picked —
-- an event is meant to be found. The app tells creators to use a public
-- place for exactly that reason.

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 60),
  description text check (char_length(description) <= 500),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  location_name text check (char_length(location_name) <= 100),
  starts_at timestamptz not null,
  ends_at timestamptz,
  -- 'public' = any signed-in user; 'connections' = only the creator's
  -- accepted connections (and the creator).
  visibility text not null default 'public' check (visibility in ('public', 'connections')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_ends_after_starts check (ends_at is null or ends_at > starts_at)
);

-- The map asks for "events inside this rectangle" — latitude first since
-- that's the range the index can narrow on directly.
create index if not exists events_lat_lng_idx on public.events (latitude, longitude);
create index if not exists events_starts_at_idx on public.events (starts_at);
create index if not exists events_creator_idx on public.events (creator_id);

create table if not exists public.event_attendees (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  -- One row per person per event.
  primary key (event_id, user_id)
);

-- The primary key already covers lookups by event_id; this covers "events
-- I'm going to".
create index if not exists event_attendees_user_idx on public.event_attendees (user_id);

create trigger on_events_updated
  before update on public.events
  for each row execute function public.handle_updated_at();

-- True if the caller has an accepted connection with other_user.
-- Deliberately one-argument (always relative to auth.uid()) and NOT
-- security definer: it only ever reads the caller's own connection rows,
-- which the existing connections RLS already lets them see. A two-person
-- definer version would let anyone probe whether two strangers are
-- connected.
create or replace function public.is_connected_to(other_user uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1 from public.connections c
    where c.status = 'accepted'
      and (
        (c.requester_id = auth.uid() and c.addressee_id = other_user)
        or (c.requester_id = other_user and c.addressee_id = auth.uid())
      )
  );
$$;

revoke execute on function public.is_connected_to(uuid) from anon, public;
grant execute on function public.is_connected_to(uuid) to authenticated;

alter table public.events enable row level security;
alter table public.event_attendees enable row level security;

-- Public events are visible to every signed-in user; connections-only
-- events to the creator and their accepted connections.
create policy "Users can view events visible to them"
  on public.events
  for select
  to authenticated
  using (
    visibility = 'public'
    or creator_id = auth.uid()
    or public.is_connected_to(creator_id)
  );

-- You can only create an event as yourself.
create policy "Users can create their own events"
  on public.events
  for insert
  to authenticated
  with check (creator_id = auth.uid());

-- Only the creator can edit, and can't hand the event to someone else.
create policy "Creators can update their events"
  on public.events
  for update
  to authenticated
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());

create policy "Creators can delete their events"
  on public.events
  for delete
  to authenticated
  using (creator_id = auth.uid());

-- Attendee policies all check "the event exists" from *inside* RLS, so the
-- events select policy above automatically limits them to events the
-- caller can see. No recursion risk: the events policy never looks at
-- event_attendees.

-- Anyone who can see an event can see who's going (needed for the count).
create policy "Users can view attendees of visible events"
  on public.event_attendees
  for select
  to authenticated
  using (exists (select 1 from public.events e where e.id = event_attendees.event_id));

-- RSVP only as yourself, only to an event you can see.
create policy "Users can RSVP to visible events"
  on public.event_attendees
  for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.events e where e.id = event_attendees.event_id)
  );

-- Un-RSVP only yourself. The creator always counts as going, so they can't
-- remove their own row (deleting the event removes it via cascade).
create policy "Users can remove their own RSVP"
  on public.event_attendees
  for delete
  to authenticated
  using (
    user_id = auth.uid()
    and exists (
      select 1 from public.events e
      where e.id = event_attendees.event_id and e.creator_id <> auth.uid()
    )
  );

-- The creator automatically counts as attending. Runs as the inserting
-- user, whose own RSVP the policies above already allow.
create function public.handle_new_event()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  insert into public.event_attendees (event_id, user_id)
  values (new.id, new.creator_id)
  on conflict (event_id, user_id) do nothing;
  return new;
end;
$$;

revoke execute on function public.handle_new_event() from anon, authenticated, public;

create trigger on_event_created
  after insert on public.events
  for each row execute function public.handle_new_event();

-- What the app actually reads: each event plus its creator, attendee count,
-- whether the caller is going, and effective_ends_at (events without an end
-- time count as over 3 hours after they start, so they don't sit on the
-- map forever).
-- security_invoker makes the view run as the caller, so every RLS policy
-- above still applies — it can never show an event the caller couldn't
-- read from the table directly.
create or replace view public.event_summaries
with (security_invoker = true)
as
select
  e.id,
  e.creator_id,
  e.title,
  e.description,
  e.latitude,
  e.longitude,
  e.location_name,
  e.starts_at,
  e.ends_at,
  e.visibility,
  e.created_at,
  e.updated_at,
  coalesce(e.ends_at, e.starts_at + interval '3 hours') as effective_ends_at,
  p.username as creator_username,
  p.full_name as creator_full_name,
  p.avatar_url as creator_avatar_url,
  (select count(*) from public.event_attendees a where a.event_id = e.id)::integer as attendee_count,
  exists (
    select 1 from public.event_attendees a
    where a.event_id = e.id and a.user_id = auth.uid()
  ) as is_going
from public.events e
join public.profiles p on p.id = e.creator_id;

revoke all on public.event_summaries from anon;
grant select on public.event_summaries to authenticated;
