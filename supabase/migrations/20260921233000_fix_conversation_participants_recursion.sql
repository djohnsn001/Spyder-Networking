-- Fixes 42P17 "infinite recursion detected in policy for relation
-- conversation_participants", hit while testing the previous migration.
--
-- The read policy on conversation_participants checked "is the caller a
-- participant in this conversation" by querying conversation_participants
-- from inside its own USING clause. Evaluating that inner query re-triggers
-- the same policy, which queries the table again — forever. Postgres
-- detects the cycle and errors instead of looping.
--
-- Fix: move that check into a security-definer function. Its owner
-- bypasses RLS (same reason get_mutuals needs security definer), so the
-- internal query doesn't re-trigger the policy — no cycle. The
-- conversations and messages policies switch to the same function, both
-- for consistency and because they were doing an equivalent check.
create or replace function public.is_conversation_participant(_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.conversation_participants cp
    where cp.conversation_id = _conversation_id
      and cp.user_id = auth.uid()
  );
$$;

revoke execute on function public.is_conversation_participant(uuid) from anon, public;
grant execute on function public.is_conversation_participant(uuid) to authenticated;

drop policy "Members can view their conversations" on public.conversations;
create policy "Members can view their conversations"
  on public.conversations
  for select
  to authenticated
  using (public.is_conversation_participant(id));

drop policy "Members can view participants in their conversations" on public.conversation_participants;
create policy "Members can view participants in their conversations"
  on public.conversation_participants
  for select
  to authenticated
  using (public.is_conversation_participant(conversation_id));

drop policy "Members can view messages in their conversations" on public.messages;
create policy "Members can view messages in their conversations"
  on public.messages
  for select
  to authenticated
  using (public.is_conversation_participant(conversation_id));

drop policy "Members can send messages if still connected" on public.messages;
create policy "Members can send messages if still connected"
  on public.messages
  for insert
  to authenticated
  with check (
    sender_id = auth.uid()
    and public.is_conversation_participant(conversation_id)
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
