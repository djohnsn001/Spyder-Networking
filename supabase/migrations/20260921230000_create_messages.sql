-- Direct messages between accepted connections.
--
-- Three tables:
--   conversations            — one row per conversation
--   conversation_participants — who's in it (a junction table, not just two
--                               columns on conversations) so a group chat
--                               later only needs new rows here, not a schema
--                               change
--   messages                 — the messages themselves
--
-- Mutation is split the same way user_locations already is: some tables are
-- readable directly by clients under RLS, but the tricky bits (creating a
-- conversation, keeping its "last message" pointer current) only happen
-- through security-definer functions below, so plain RLS never has to
-- reason about them.

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  -- Not used yet — group chats aren't being built now — but having the
  -- column means adding them later doesn't require touching this table's
  -- shape or the direct-pair uniqueness index below.
  is_group boolean not null default false,
  -- Only set for 1:1 conversations. Lets "one conversation per pair" be a
  -- plain unique index instead of a scan over conversation_participants,
  -- the same trick public.connections already uses.
  user_a_id uuid references public.profiles (id) on delete cascade,
  user_b_id uuid references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  -- Denormalized so the inbox can sort/preview without joining messages.
  last_message_at timestamptz not null default now(),
  last_message_id uuid,
  constraint direct_conversation_has_users check (
    is_group or (user_a_id is not null and user_b_id is not null and user_a_id <> user_b_id)
  )
);

create unique index if not exists conversations_direct_pair_idx
  on public.conversations (least(user_a_id, user_b_id), greatest(user_a_id, user_b_id))
  where not is_group;

create table if not exists public.conversation_participants (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  -- Everything the other participant sent after this timestamp is unread.
  last_read_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create index if not exists conversation_participants_user_idx
  on public.conversation_participants (user_id);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) > 0 and char_length(body) <= 2000),
  created_at timestamptz not null default now()
);

-- Powers both "load this conversation's messages, newest first, paginated"
-- and the last-message-pointer trigger below.
create index if not exists messages_conversation_created_idx
  on public.messages (conversation_id, created_at desc);

-- Added after messages exists, since conversations.last_message_id points
-- into it (the two tables reference each other).
alter table public.conversations
  add constraint conversations_last_message_fk
  foreign key (last_message_id) references public.messages (id) on delete set null;

-- Keeps conversations.last_message_at/last_message_id current on every new
-- message, so the inbox query never has to scan or aggregate messages.
-- security definer because this writes to a *different* table than the one
-- being inserted into, which plain RLS on conversations doesn't allow for
-- a regular participant — same reasoning as the other definer functions
-- here, just triggered instead of called directly.
create function public.handle_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.conversations
  set last_message_at = new.created_at,
      last_message_id = new.id
  where id = new.conversation_id;
  return new;
end;
$$;

create trigger on_message_inserted
  after insert on public.messages
  for each row execute function public.handle_new_message();

alter table public.conversations enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages enable row level security;

-- Conversations: readable if you're a participant. No insert/update/delete
-- policy — rows are only ever created by get_or_create_direct_conversation
-- and only ever updated by the trigger above, both security definer.
create policy "Members can view their conversations"
  on public.conversations
  for select
  to authenticated
  using (
    exists (
      select 1 from public.conversation_participants cp
      where cp.conversation_id = conversations.id and cp.user_id = auth.uid()
    )
  );

-- Participants: you can see every row in a conversation you're part of
-- (not just your own), because the client needs to know who the *other*
-- participant is to render their name/avatar. This "self-join" shape —
-- checking membership by querying the same table the policy is on — is
-- the standard pattern for this and terminates fine; it's not recursive
-- the way it might look at first glance.
create policy "Members can view participants in their conversations"
  on public.conversation_participants
  for select
  to authenticated
  using (
    exists (
      select 1 from public.conversation_participants self
      where self.conversation_id = conversation_participants.conversation_id
        and self.user_id = auth.uid()
    )
  );

-- You can update your own read state (last_read_at) and nobody else's.
-- No insert/delete policy — rows are only created by the RPC below, which
-- is what stops a user adding themselves to someone else's conversation.
create policy "Members can update their own read state"
  on public.conversation_participants
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Messages: readable if you're a participant in the conversation.
create policy "Members can view messages in their conversations"
  on public.messages
  for select
  to authenticated
  using (
    exists (
      select 1 from public.conversation_participants cp
      where cp.conversation_id = messages.conversation_id and cp.user_id = auth.uid()
    )
  );

-- Sendable only as yourself, only into a conversation you're in, and only
-- if every *other* participant is currently an accepted connection. That
-- last check is written as "no other participant fails the connection
-- test" rather than "the other participant passes it", so it already
-- generalizes to a future group chat with several other participants
-- without changing this policy.
-- No update/delete policy at all — messages can't be edited or deleted by
-- anyone, including the sender, which is what's wanted for v1.
create policy "Members can send messages if still connected"
  on public.messages
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.conversation_participants cp
      where cp.conversation_id = messages.conversation_id and cp.user_id = auth.uid()
    )
    and not exists (
      select 1 from public.conversation_participants other
      where other.conversation_id = messages.conversation_id
        and other.user_id <> auth.uid()
        and not exists (
          select 1 from public.connections c
          where c.status = 'accepted'
            and (
              (c.requester_id = auth.uid() and c.addressee_id = other.user_id)
              or (c.requester_id = other.user_id and c.addressee_id = auth.uid())
            )
        )
    )
  );

-- Finds the existing direct conversation between the caller and other_user,
-- or creates one (plus both participant rows). security definer because
-- inserting the *other* person's participant row isn't something a plain
-- RLS insert policy can allow you to do as yourself — this function is the
-- one narrow, validated door for it: it always checks an accepted
-- connection first, and only ever inserts the two specific rows this call
-- needs.
create or replace function public.get_or_create_direct_conversation(other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  lo uuid := least(auth.uid(), other_user);
  hi uuid := greatest(auth.uid(), other_user);
  found_id uuid;
begin
  if me is null then
    raise exception 'not authenticated';
  end if;
  if me = other_user then
    raise exception 'cannot start a conversation with yourself';
  end if;

  if not exists (
    select 1 from public.connections c
    where c.status = 'accepted'
      and (
        (c.requester_id = me and c.addressee_id = other_user)
        or (c.requester_id = other_user and c.addressee_id = me)
      )
  ) then
    raise exception 'not connected';
  end if;

  select id into found_id
  from public.conversations
  where not is_group and least(user_a_id, user_b_id) = lo and greatest(user_a_id, user_b_id) = hi;

  if found_id is not null then
    return found_id;
  end if;

  -- Two people could hit this at once (both starting the chat from their
  -- own side simultaneously); the unique index added above turns the
  -- loser's insert into a unique_violation instead of a duplicate row, and
  -- this just looks up the row the winner created.
  begin
    insert into public.conversations (user_a_id, user_b_id)
    values (lo, hi)
    returning id into found_id;
  exception when unique_violation then
    select id into found_id
    from public.conversations
    where not is_group and least(user_a_id, user_b_id) = lo and greatest(user_a_id, user_b_id) = hi;
  end;

  insert into public.conversation_participants (conversation_id, user_id)
  values (found_id, lo), (found_id, hi)
  on conflict (conversation_id, user_id) do nothing;

  return found_id;
end;
$$;

revoke execute on function public.get_or_create_direct_conversation(uuid) from anon, public;
grant execute on function public.get_or_create_direct_conversation(uuid) to authenticated;

-- Unread count per conversation for the caller. Not security definer —
-- unlike get_mutuals/get_connection_count, this never needs to see anyone
-- else's rows, just the caller's own participant rows and the messages
-- their own membership already lets them read, so plain RLS is enough.
create or replace function public.get_unread_counts()
returns table (conversation_id uuid, unread_count integer)
language sql
stable
as $$
  select cp.conversation_id, count(m.id)::integer as unread_count
  from public.conversation_participants cp
  join public.messages m
    on m.conversation_id = cp.conversation_id
    and m.sender_id <> cp.user_id
    and m.created_at > cp.last_read_at
  where cp.user_id = auth.uid()
  group by cp.conversation_id;
$$;

grant execute on function public.get_unread_counts() to authenticated;

-- Single number for the nav badge, built on the function above.
create or replace function public.get_total_unread_count()
returns integer
language sql
stable
as $$
  select coalesce(sum(unread_count), 0)::integer from public.get_unread_counts();
$$;

grant execute on function public.get_total_unread_count() to authenticated;

-- Realtime only on messages (not conversations/conversation_participants —
-- nothing needs to watch those live). Postgres Changes checks each
-- subscriber's own SELECT policy before delivering a row, so a client
-- subscribing with no filter still only ever receives inserts for
-- conversations they're a participant in — the "Members can view messages"
-- policy above is doing double duty as the realtime access rule too.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;
