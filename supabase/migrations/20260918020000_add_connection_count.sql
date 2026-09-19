-- Returns how many accepted connections a user has. Needed because the
-- connections RLS policy only lets you see rows you're part of, so a
-- plain client-side count query returns 0 for anyone else's profile.
-- Mirrors get_mutuals: security definer, but only ever returns a number,
-- never row-level connection details of people other than the caller.
create or replace function public.get_connection_count(target_user uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.connections c
  where c.status = 'accepted'
    and (c.requester_id = target_user or c.addressee_id = target_user);
$$;

revoke execute on function public.get_connection_count(uuid) from anon, public;
grant execute on function public.get_connection_count(uuid) to authenticated;
