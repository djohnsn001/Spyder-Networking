-- The Web Map shows only people you've met in person (level = 'in_person').
-- Acquaintances still count everywhere else (chat, events, connection counts,
-- mutuals); this only changes what's drawn on the map.
--
-- Same signatures and behavior as in 20260921000000_add_web_map_locations.sql,
-- plus the level filter.

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
          and c.level = 'in_person'
          and (
            (c.requester_id = auth.uid() and c.addressee_id = p.id)
            or (c.addressee_id = auth.uid() and c.requester_id = p.id)
          )
      )
    );
$$;

revoke execute on function public.get_connection_locations() from anon, public;
grant execute on function public.get_connection_locations() to authenticated;

-- Lines between two of the caller's in-person connections, drawn only when
-- those two have also met each other in person.
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
      and c.level = 'in_person'
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
    and c.level = 'in_person'
    and c.requester_id in (select connection_id from visible)
    and c.addressee_id in (select connection_id from visible)
    and c.requester_id <> auth.uid()
    and c.addressee_id <> auth.uid();
$$;

revoke execute on function public.get_connection_edges() from anon, public;
grant execute on function public.get_connection_edges() to authenticated;
