-- Security C1 + C2: stop clients forging accepted connections.
--
-- C1: the insert policy never checked status, and connections_guard() reset
--     level/method on insert but not status. A client could insert
--     { requester_id: me, addressee_id: anyone, status: 'accepted' } and be
--     connected to anyone instantly.
-- C2: the update policy only checked auth.uid() = addressee_id. The addressee
--     could change requester_id to any third user and set status = 'accepted',
--     forging a connection with someone who never agreed.
--
-- An accepted connection unlocks messaging, connections-only events,
-- attendee visibility and mutuals, so both were critical.
--
-- Fix, three layers:
--   1. connections_guard(): untrusted inserts always start as 'pending'; untrusted
--      updates can't touch the two people, created_at, or the in-person columns,
--      and the only allowed status change is pending -> accepted.
--   2. The insert policy also requires status = 'pending'.
--   3. authenticated can UPDATE only the status column.
--
-- Unchanged: the in-person path (_connect_in_person, undo_in_person_connection,
-- _retention_sweep) is security definer and sets bolas.trusted_write, so it
-- can still create accepted/in_person rows and restore them on undo.

-- ---------------------------------------------------------------------------
-- 1. Guard
-- ---------------------------------------------------------------------------

-- "Trusted" means either:
--   - bolas.trusted_write = 'on' (set by the in-person/undo/cleanup functions;
--     clients reach the database only through PostgREST, which can't call
--     set_config, and the flag resets at the end of every transaction), or
--   - the write isn't coming from a client role at all. PostgREST runs every
--     app/web request as `authenticated` or `anon`. Other roles are the
--     service key (seed scripts), `postgres` (migrations, SQL editor, tests),
--     or a security-definer function's owner. Without this, seed scripts and
--     test fixtures that insert 'accepted' rows directly would be silently
--     turned into requests. Any future definer function that writes
--     connections from client input must do its own checks.
create or replace function public.connections_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('bolas.trusted_write', true), '') = 'on'
     or current_user not in ('authenticated', 'anon') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- A client insert is always a fresh request, whatever it asked for.
    new.status := 'pending';
    new.level := 'acquaintance';
    new.method := 'request';
    new.met_at := null;
    new.met_city := null;
    new.undo_until := null;
    new.undo_snapshot := null;
    new.created_at := now();
  elsif tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.requester_id is distinct from old.requester_id
      or new.addressee_id is distinct from old.addressee_id
      or new.created_at is distinct from old.created_at then
      raise exception 'The people in a connection can''t be changed'
        using errcode = '42501';
    end if;

    -- Accepting a request is the only status change a client can make.
    -- (Declining, cancelling and unfriending are deletes.)
    if new.status is distinct from old.status
      and not (old.status = 'pending' and new.status = 'accepted') then
      raise exception 'A connection can only go from pending to accepted'
        using errcode = '42501';
    end if;

    if new.level is distinct from old.level
      or new.method is distinct from old.method
      or new.met_at is distinct from old.met_at
      or new.met_city is distinct from old.met_city
      or new.undo_until is distinct from old.undo_until
      or new.undo_snapshot is distinct from old.undo_snapshot then
      raise exception 'Connection level can only change through an in-person connect'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

-- The trigger itself (connections_guard, before insert or update) already
-- exists from 20260927000000; replacing the function is enough.
revoke execute on function public.connections_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Insert policy: same as 20260928020000, plus status = 'pending'
-- ---------------------------------------------------------------------------

-- The guard already forces 'pending' before this check runs (row-level
-- security is checked after BEFORE triggers); this is the second lock.
drop policy "Users can send connection requests" on public.connections;
create policy "Users can send connection requests"
  on public.connections
  for insert
  to authenticated
  with check (
    auth.uid() = requester_id
    and status = 'pending'
    and not public.is_blocked_with(addressee_id)
    and not public.is_suspended(auth.uid())
    and not public.is_suspended(addressee_id)
  );

-- ---------------------------------------------------------------------------
-- 3. Column privileges: clients may only update status
-- ---------------------------------------------------------------------------

-- Any client UPDATE touching another column now fails with 42501 before the
-- row is even read. anon never had an update policy; take the privilege
-- away too (AGENTS.md rule 3).
revoke update on public.connections from authenticated;
revoke update on public.connections from anon;
grant update (status) on public.connections to authenticated;
