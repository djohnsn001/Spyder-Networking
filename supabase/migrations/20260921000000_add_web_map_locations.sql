-- Web Map locations: privacy-first by design.
--
-- Locations live in their own table rather than as columns on profiles, so
-- they can never leak through the existing "profiles are viewable by
-- authenticated users" policy. user_locations has RLS enabled with NO
-- select/insert/update policies for clients at all — that means even the
-- owning user cannot query or write this table directly through the
-- Supabase client. The only way in or out is the three security-definer
-- functions below, which each enforce their own rules (rounded coordinates,
-- sharing-on-only, connections-only).

-- Ghost mode setting: 'connections' (default, visible to accepted
-- connections) or 'off' (hidden from everyone, including connections).
alter table public.profiles
  add column if not exists location_sharing text not null default 'connections'
    check (location_sharing in ('connections', 'off'));

create table if not exists public.user_locations (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  lat double precision not null,
  lng double precision not null,
  updated_at timestamptz not null default now()
);

-- RLS on with zero policies = locked to every client role, full stop.
-- Reads and writes only happen inside the security-definer functions below.
alter table public.user_locations enable row level security;

-- Saves the caller's own location. Coordinates are rounded to 2 decimal
-- places (~1.1km at Boise's latitude) on the server before they're ever
-- written — the exact GPS fix never touches the database. security definer
-- is required because clients have no insert/update grant on the table.
create or replace function public.update_my_location(lat double precision, lng double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if lat < -90 or lat > 90 or lng < -180 or lng > 180 then
    raise exception 'invalid coordinates';
  end if;

  insert into public.user_locations (user_id, lat, lng, updated_at)
  values (auth.uid(), round(lat::numeric, 2), round(lng::numeric, 2), now())
  on conflict (user_id)
  do update set lat = excluded.lat, lng = excluded.lng, updated_at = excluded.updated_at;
end;
$$;

revoke execute on function public.update_my_location(double precision, double precision) from anon, public;
grant execute on function public.update_my_location(double precision, double precision) to authenticated;

-- Locations to plot on the caller's Web Map: their accepted connections who
-- have location_sharing = 'connections', plus the caller's own pin if their
-- own sharing is on (the location_sharing filter applies to every row here,
-- including the caller's, so ghost mode hides you from your own map too —
-- consistent with "off" meaning off everywhere).
create or replace function public.get_connection_locations()
returns table (
  id uuid,
  username text,
  full_name text,
  avatar_url text,
  lat double precision,
  lng double precision,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url, ul.lat, ul.lng, ul.updated_at
  from public.user_locations ul
  join public.profiles p on p.id = ul.user_id
  where p.location_sharing = 'connections'
    and (
      p.id = auth.uid()
      or exists (
        select 1
        from public.connections c
        where c.status = 'accepted'
          and (
            (c.requester_id = auth.uid() and c.addressee_id = p.id)
            or (c.addressee_id = auth.uid() and c.requester_id = p.id)
          )
      )
    );
$$;

revoke execute on function public.get_connection_locations() from anon, public;
grant execute on function public.get_connection_locations() to authenticated;

-- Pairs of the caller's own connections who are also accepted connections
-- with each other — the lines to draw *between* mutuals on the web, as
-- opposed to the caller's own spokes (which the client draws itself from
-- get_connection_locations, since it always knows its own position).
-- Restricted to pairs where both people currently have a visible location,
-- so this never reveals a connection between two people neither of whom
-- will actually appear as a pin.
create or replace function public.get_connection_edges()
returns table (
  user_a uuid,
  user_b uuid
)
language sql
stable
security definer
set search_path = public
as $$
  with my_connections as (
    select case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end as connection_id
    from public.connections c
    where c.status = 'accepted'
      and (c.requester_id = auth.uid() or c.addressee_id = auth.uid())
  ),
  visible as (
    select mc.connection_id
    from my_connections mc
    join public.profiles p on p.id = mc.connection_id
    where p.location_sharing = 'connections'
      and exists (select 1 from public.user_locations ul where ul.user_id = mc.connection_id)
  )
  select least(c.requester_id, c.addressee_id) as user_a,
         greatest(c.requester_id, c.addressee_id) as user_b
  from public.connections c
  where c.status = 'accepted'
    and c.requester_id in (select connection_id from visible)
    and c.addressee_id in (select connection_id from visible)
    and c.requester_id <> auth.uid()
    and c.addressee_id <> auth.uid();
$$;

revoke execute on function public.get_connection_edges() from anon, public;
grant execute on function public.get_connection_edges() to authenticated;
