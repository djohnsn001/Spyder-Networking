-- Security M4: rate limits on messages and connection requests.
--
-- Before this, one account could send hundreds of messages or connection
-- requests a minute (a spam bot only needs the public key and one login).
-- RSVPs already had a limit (event_attendees_rate_limit in 20260927060000);
-- this follows the same pattern: a BEFORE INSERT trigger, security definer,
-- that raises a short error code the app turns into a friendly message.
--
--   messages:            30 a minute and 500 a day per sender
--                        (accounts under 3 days old: 10 a minute, 100 a day)
--   connection requests: 20 a day (accounts under 3 days old: 5 a day)
--
-- All the numbers live in _rate_limits() below.
--
-- Errors (sqlstate P0001, the detail says which window was hit):
--   message_rate_limited     detail 'minute' or 'day'
--   connection_rate_limited  detail 'day'
--
-- Not limited ("trusted" writes, same idea as connections_guard):
--   - bolas.trusted_write = 'on': the in-person QR connect, undo and the
--     retention sweep. Meeting people face to face at an event is exactly
--     what the app is for, so it never counts against the request cap.
--   - Writes that don't come from a client role: seed scripts (service key),
--     migrations, the SQL editor. These functions are security definer, so
--     current_user is the owner here; the 'role' setting still holds the
--     caller's role (PostgREST sets it to authenticated/anon per request).

-- ---------------------------------------------------------------------------
-- The numbers (edit here to tune)
-- ---------------------------------------------------------------------------

create or replace function public._rate_limits()
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'new_account_days', 3,                      -- "new" = auth.users.created_at within this
    'messages_per_minute', 30,
    'messages_per_day', 500,
    'new_account_messages_per_minute', 10,
    'new_account_messages_per_day', 100,
    'connection_requests_per_day', 20,
    'new_account_connection_requests_per_day', 5
  );
$$;

revoke execute on function public._rate_limits() from public, anon, authenticated;

-- True when a write comes from the app/web (a client role) and isn't one of
-- the trusted functions above. Internal helper.
create or replace function public._is_untrusted_write()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('bolas.trusted_write', true), '') <> 'on'
     and coalesce(current_setting('role', true), '') in ('authenticated', 'anon');
$$;

revoke execute on function public._is_untrusted_write() from public, anon, authenticated;

-- Whether an account is still inside its first few days. Age comes from
-- auth.users (see _account_created_at), which nobody can edit from the app.
-- A missing auth row counts as new.
create or replace function public._is_new_account(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public._account_created_at(p_uid)
      > now() - make_interval(days => (public._rate_limits() ->> 'new_account_days')::int),
    true
  );
$$;

revoke execute on function public._is_new_account(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

-- Keeps both counts below cheap: an index range scan over one sender's
-- recent messages, however big the table gets.
create index if not exists messages_sender_created_idx
  on public.messages (sender_id, created_at desc);

-- Clients can't delete messages, so counting the messages table itself is
-- safe (unlike connections, below).
create or replace function public.messages_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._rate_limits();
  v_new boolean;
  v_per_minute int;
  v_per_day int;
  v_count int;
begin
  if not public._is_untrusted_write() then
    return new;
  end if;

  -- The insert policy doesn't restrict created_at, so a client could send
  -- it backdated and slip under the per-minute count (and jump the chat's
  -- order). Always stamp it with the real time.
  new.created_at := now();

  v_new := public._is_new_account(new.sender_id);
  v_per_minute := (r ->> case when v_new then 'new_account_messages_per_minute' else 'messages_per_minute' end)::int;
  v_per_day := (r ->> case when v_new then 'new_account_messages_per_day' else 'messages_per_day' end)::int;

  select count(*) into v_count
  from (
    select 1 from public.messages m
    where m.sender_id = new.sender_id and m.created_at > now() - interval '1 minute'
    limit v_per_minute
  ) recent;
  if v_count >= v_per_minute then
    raise exception 'message_rate_limited' using errcode = 'P0001', detail = 'minute';
  end if;

  select count(*) into v_count
  from (
    select 1 from public.messages m
    where m.sender_id = new.sender_id and m.created_at > now() - interval '24 hours'
    limit v_per_day
  ) recent;
  if v_count >= v_per_day then
    raise exception 'message_rate_limited' using errcode = 'P0001', detail = 'day';
  end if;

  return new;
end;
$$;

revoke execute on function public.messages_rate_limit() from public, anon, authenticated;

create trigger messages_rate_limit
  before insert on public.messages
  for each row execute function public.messages_rate_limit();

-- ---------------------------------------------------------------------------
-- Connection requests
-- ---------------------------------------------------------------------------

-- Request log: the daily cap counts this, not the connections table.
-- Counting live rows could be dodged: requests that are cancelled, declined
-- or removed are deleted, so a spammer could send 20, cancel, and send 20
-- more (every one still pinging someone). Only untrusted inserts are logged.
create table public.connection_request_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index connection_request_log_user_idx
  on public.connection_request_log (user_id, created_at desc);

-- RLS on with no policies, and no client grants: only the triggers below
-- (security definer) touch it.
alter table public.connection_request_log enable row level security;

revoke all on public.connection_request_log from public, anon, authenticated;
grant select, insert, update, delete on public.connection_request_log to service_role;

-- Before a client sends a request: enforce the daily cap.
create or replace function public.connections_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := public._rate_limits();
  v_per_day int;
  v_count int;
begin
  if not public._is_untrusted_write() then
    return new;
  end if;

  v_per_day := (r ->> case when public._is_new_account(new.requester_id)
                        then 'new_account_connection_requests_per_day'
                        else 'connection_requests_per_day' end)::int;

  select count(*) into v_count
  from (
    select 1 from public.connection_request_log l
    where l.user_id = new.requester_id and l.created_at > now() - interval '24 hours'
    limit v_per_day
  ) recent;
  if v_count >= v_per_day then
    raise exception 'connection_rate_limited' using errcode = 'P0001', detail = 'day';
  end if;

  return new;
end;
$$;

revoke execute on function public.connections_rate_limit() from public, anon, authenticated;

create trigger connections_rate_limit
  before insert on public.connections
  for each row execute function public.connections_rate_limit();

-- After the request is really saved: log it. An AFTER trigger, like the RSVP
-- log, so a request that fails (duplicate, blocked, RLS) isn't counted.
create or replace function public.connections_log_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_untrusted_write() then
    return new;
  end if;

  insert into public.connection_request_log (user_id) values (new.requester_id);
  -- Housekeeping: the cap only looks back 24 hours.
  delete from public.connection_request_log
  where user_id = new.requester_id and created_at < now() - interval '7 days';
  return new;
end;
$$;

revoke execute on function public.connections_log_request() from public, anon, authenticated;

create trigger connections_log_request
  after insert on public.connections
  for each row execute function public.connections_log_request();
