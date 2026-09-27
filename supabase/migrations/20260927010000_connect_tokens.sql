-- QR codes for connecting in person.
--
-- The person showing their code calls create_connect_token() and displays
-- bolas://connect/<token>. The code rotates every ~30s in the app and
-- expires after 60s server-side, works exactly once, and is 128 random bits
-- so it can't be guessed. The scanner calls redeem_connect_token(), which
-- makes the in-person connection. The code owner's phone polls
-- get_connect_token_status() so both people see the match card.

create table public.connect_tokens (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references public.profiles (id) on delete set null,
  -- What the code owner's phone reads back after a scan (who scanned, outcome).
  result jsonb
);

create index connect_tokens_user_idx on public.connect_tokens (user_id, created_at desc);

-- RLS on with no policies: unreachable from clients even with the grants
-- below. Only the security-definer functions in this file touch the table.
alter table public.connect_tokens enable row level security;

grant select on public.connect_tokens to anon;
grant select, insert, update, delete on public.connect_tokens to authenticated;
grant select, insert, update, delete on public.connect_tokens to service_role;

-- The public bits of a profile shown on the match card. Internal only.
create or replace function public._profile_card(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id,
    'username', p.username,
    'full_name', p.full_name,
    'avatar_url', p.avatar_url
  )
  from public.profiles p
  where p.id = p_user;
$$;

revoke execute on function public._profile_card(uuid) from anon, authenticated, public;

-- Makes a fresh code for the caller.
-- Returns { outcome: 'ok', token, expires_at } or { outcome: 'rate_limited' }.
create or replace function public.create_connect_token()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunables. The app rotates every 30s and after each scan, so 6/min
  -- allows ~5 scans a minute at a busy event.
  c_max_per_minute constant int := 6;
  c_lifetime constant interval := interval '60 seconds';

  v_me uuid := auth.uid();
  v_token text;
  v_expires timestamptz;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- Housekeeping: anything older than an hour is useless, and the caller's
  -- own unused expired codes can go now. Used codes stay until the hourly
  -- sweep so the owner's phone can still read the result.
  delete from public.connect_tokens where created_at < now() - interval '1 hour';
  delete from public.connect_tokens
  where user_id = v_me and used_at is null and expires_at < now();

  if (
    select count(*) from public.connect_tokens
    where user_id = v_me and created_at > now() - interval '1 minute'
  ) >= c_max_per_minute then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  v_token := encode(extensions.gen_random_bytes(16), 'hex');
  v_expires := now() + c_lifetime;

  insert into public.connect_tokens (token, user_id, expires_at)
  values (v_token, v_me, v_expires);

  return jsonb_build_object('outcome', 'ok', 'token', v_token, 'expires_at', v_expires);
end;
$$;

-- Called by the person scanning. p_city is the city their phone is in (or
-- null if location is off); falls back to the scanner's profile city, then
-- the code owner's.
-- Returns { outcome: 'invalid' | 'used' | 'expired' | 'self' } on failure, or
-- _connect_in_person's result ('created' | 'upgraded' | 'already_connected',
-- connection_id, met_city, undo_until) plus other_user_id and other_profile.
create or replace function public.redeem_connect_token(p_token text, p_city text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_tok public.connect_tokens%rowtype;
  v_city text;
  v jsonb;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  select * into v_tok from public.connect_tokens where token = p_token for update;

  if not found then
    return jsonb_build_object('outcome', 'invalid');
  elsif v_tok.user_id = v_me then
    return jsonb_build_object('outcome', 'self');
  elsif v_tok.used_at is not null then
    return jsonb_build_object('outcome', 'used');
  elsif v_tok.expires_at < now() then
    return jsonb_build_object('outcome', 'expired');
  end if;

  v_city := coalesce(
    nullif(trim(p_city), ''),
    nullif(trim((select city from public.profiles where id = v_me)), ''),
    nullif(trim((select city from public.profiles where id = v_tok.user_id)), '')
  );

  v := public._connect_in_person(v_me, v_tok.user_id, 'qr', v_city);

  -- The owner's copy names the scanner as "the other person".
  update public.connect_tokens set
    used_at = now(),
    used_by = v_me,
    result = v || jsonb_build_object(
      'other_user_id', v_me,
      'other_profile', public._profile_card(v_me)
    )
  where token = p_token;

  return v || jsonb_build_object(
    'other_user_id', v_tok.user_id,
    'other_profile', public._profile_card(v_tok.user_id)
  );
end;
$$;

-- Polled (~1s) by the code owner's phone while their QR is on screen.
-- Returns { status: 'active' | 'expired' | 'used' | 'not_found', result, other_profile }.
-- Only the owner can see a code's status; anyone else gets not_found.
create or replace function public.get_connect_token_status(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tok public.connect_tokens%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_tok
  from public.connect_tokens
  where token = p_token and user_id = auth.uid();

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  return jsonb_build_object(
    'status', case
      when v_tok.used_at is not null then 'used'
      when v_tok.expires_at < now() then 'expired'
      else 'active'
    end,
    'result', v_tok.result,
    'other_profile', v_tok.result -> 'other_profile'
  );
end;
$$;

revoke execute on function public.create_connect_token() from anon, public;
revoke execute on function public.redeem_connect_token(text, text) from anon, public;
revoke execute on function public.get_connect_token_status(text) from anon, public;
grant execute on function public.create_connect_token() to authenticated;
grant execute on function public.redeem_connect_token(text, text) to authenticated;
grant execute on function public.get_connect_token_status(text) to authenticated;
