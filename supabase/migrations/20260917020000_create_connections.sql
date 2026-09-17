-- Connections table: a connection request between two users.
-- requester_id = who sent it, addressee_id = who received it.
-- status starts 'pending' and becomes 'accepted' when the addressee accepts.
-- Declining or cancelling just deletes the row (no 'declined' status in v1).
create table if not exists public.connections (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  constraint no_self_connection check (requester_id <> addressee_id)
);

-- One connection per pair, no matter which direction it was sent.
-- least()/greatest() sort the two ids so (A, B) and (B, A) collide.
create unique index if not exists connections_unique_pair
  on public.connections (least(requester_id, addressee_id), greatest(requester_id, addressee_id));

-- Speed up "all my connections" lookups from either side.
create index if not exists connections_requester_idx on public.connections (requester_id);
create index if not exists connections_addressee_idx on public.connections (addressee_id);

alter table public.connections enable row level security;

-- You can only see a connection if you're one of the two people in it.
create policy "Users can view their own connections"
  on public.connections
  for select
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- You can only send a request as yourself.
create policy "Users can send connection requests"
  on public.connections
  for insert
  to authenticated
  with check (auth.uid() = requester_id);

-- Only the addressee can update a request (accepting it).
create policy "Addressee can respond to a request"
  on public.connections
  for update
  to authenticated
  using (auth.uid() = addressee_id)
  with check (auth.uid() = addressee_id);

-- Either side can remove a connection: cancel a pending request,
-- decline one, or later "unfriend" an accepted one.
create policy "Either side can remove a connection"
  on public.connections
  for delete
  to authenticated
  using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- Returns the profiles that are connected (accepted) to both the current
-- user and other_user — used to show mutual connection counts/lists.
-- security definer: needs to read other_user's connection rows too, which
-- RLS would normally hide from the caller. It only ever returns profile
-- data, which any authenticated user can already see.
create or replace function public.get_mutuals(other_user uuid)
returns setof public.profiles
language sql
stable
security definer
set search_path = public
as $$
  select p.*
  from public.profiles p
  where p.id in (
    select case when c.requester_id = auth.uid() then c.addressee_id else c.requester_id end
    from public.connections c
    where c.status = 'accepted'
      and (c.requester_id = auth.uid() or c.addressee_id = auth.uid())
  )
  and p.id in (
    select case when c.requester_id = other_user then c.addressee_id else c.requester_id end
    from public.connections c
    where c.status = 'accepted'
      and (c.requester_id = other_user or c.addressee_id = other_user)
  );
$$;

revoke all on function public.get_mutuals(uuid) from public;
grant execute on function public.get_mutuals(uuid) to authenticated;
