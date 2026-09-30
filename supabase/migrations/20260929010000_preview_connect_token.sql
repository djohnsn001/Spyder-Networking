-- Security H1: a bolas://connect/<token> link no longer connects on tap.
--
-- Before, the link screen called redeem_connect_token() as soon as it opened.
-- Any link (a website, a text, a DM) created an in-person connection when
-- tapped, so an attacker could host a page that mints a fresh token per visit
-- and redirects to it, becoming the victim's in-person connection and seeing
-- their approximate map area.
--
-- Now the link screen first calls preview_connect_token(), which only READS:
-- it shows whose code it is, and redeem runs only when the person taps
-- Connect. The in-app scanner (face to face) still redeems directly.

-- ---------------------------------------------------------------------------
-- Rate-limit log (20 previews per minute per user)
-- ---------------------------------------------------------------------------

-- Only who previewed and when; rows older than an hour are deleted on every
-- call. Failed lookups count too, so it can't be used to probe for codes.
create table public.connect_token_preview_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

create index connect_token_preview_log_user_idx
  on public.connect_token_preview_log (user_id, created_at desc);

-- RLS on with no policies, and no client grants at all (AGENTS.md rule 3):
-- only preview_connect_token (security definer) touches it.
alter table public.connect_token_preview_log enable row level security;

revoke all on public.connect_token_preview_log from anon, authenticated;
grant select, insert, update, delete on public.connect_token_preview_log to service_role;

-- ---------------------------------------------------------------------------
-- preview_connect_token
-- ---------------------------------------------------------------------------

-- Returns one of:
--   { outcome: 'ok', other_profile, expires_at }   valid, unused, unexpired
--   { outcome: 'invalid' }        bad format, unknown, or someone you can't see
--                                 (blocked either way / suspended) — generic on purpose
--   { outcome: 'used' | 'expired' | 'self' }
--   { outcome: 'rate_limited' }
-- Never marks the token used. other_profile is _profile_card():
-- { id, username, full_name, avatar_url }.
create or replace function public.preview_connect_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunable.
  c_max_per_minute constant int := 20;

  v_me uuid := auth.uid();
  v_tok public.connect_tokens%rowtype;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- Housekeeping: the limit only looks back a minute.
  delete from public.connect_token_preview_log where created_at < now() - interval '1 hour';

  if (
    select count(*) from public.connect_token_preview_log
    where user_id = v_me and created_at > now() - interval '1 minute'
  ) >= c_max_per_minute then
    return jsonb_build_object('outcome', 'rate_limited');
  end if;

  insert into public.connect_token_preview_log (user_id) values (v_me);

  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  select * into v_tok from public.connect_tokens where token = p_token;

  if not found then
    return jsonb_build_object('outcome', 'invalid');
  elsif v_tok.user_id = v_me then
    return jsonb_build_object('outcome', 'self');
  elsif v_tok.used_at is not null then
    return jsonb_build_object('outcome', 'used');
  elsif v_tok.expires_at < now() then
    return jsonb_build_object('outcome', 'expired');
  end if;

  -- Same people redeem would refuse (_connect_in_person -> 'unavailable'):
  -- never show their profile, and never say why.
  if public._blocked_between(v_me, v_tok.user_id)
     or public.is_suspended(v_me)
     or public.is_suspended(v_tok.user_id) then
    return jsonb_build_object('outcome', 'invalid');
  end if;

  return jsonb_build_object(
    'outcome', 'ok',
    'other_profile', public._profile_card(v_tok.user_id),
    'expires_at', v_tok.expires_at
  );
end;
$$;

revoke execute on function public.preview_connect_token(text) from public, anon;
grant execute on function public.preview_connect_token(text) to authenticated;
