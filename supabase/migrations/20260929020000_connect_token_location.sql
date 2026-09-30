-- Security H2: QR codes only work when the two phones are actually together.
--
-- A connect QR code used to work from anywhere for 60 seconds, so a
-- screenshot shared online created an "in-person" connection between people
-- who never met (bumps already check distance in submit_bump; QR didn't).
--
-- Now:
--   - create_connect_token() needs the owner's location. It's stored rounded
--     to 3 decimals (~100 m) on the token, and the lifetime drops to 30 s.
--   - redeem_connect_token() needs the scanner's location. If the two points
--     are more than max(300 m, owner accuracy + scanner accuracy) apart, it
--     returns 'too_far' and leaves the code unused.
--   - Either side without a location -> 'location_required' (Zane's default:
--     block rather than rely on the H1 confirm step).
--   - Accuracy worse than 1 km -> 'poor_location' (same cut-off as bumps),
--     so a caller can't widen the allowed distance by claiming a huge
--     accuracy.
--   - The token's location is erased as soon as the code is used, and unused
--     codes are deleted within an hour (create_connect_token housekeeping and
--     _retention_sweep). Nothing else stores it: the result JSON never
--     includes coordinates.
--
-- The old signatures (create_connect_token() and
-- redeem_connect_token(text, text)) are dropped: kept alongside, an attacker
-- could simply call the old redeem, which has no distance check. The new
-- ones give every location argument a default, so old-style calls still
-- resolve — they just get 'location_required'. Only this app calls them
-- (repo search, 2026-09-29); the partner's web app doesn't.
--
-- Known limit: a phone can fake its GPS. This stops shared screenshots, and
-- anyone faking a location would need to know where the victim is.

-- ---------------------------------------------------------------------------
-- Location on the token
-- ---------------------------------------------------------------------------

alter table public.connect_tokens
  add column lat double precision check (lat between -90 and 90),
  add column lng double precision check (lng between -180 and 180),
  add column accuracy_m real check (accuracy_m > 0),
  add constraint connect_tokens_coords_together
    check ((lat is null) = (lng is null) and (lat is null) = (accuracy_m is null));

-- ---------------------------------------------------------------------------
-- create_connect_token(p_lat, p_lng, p_accuracy_m)
-- ---------------------------------------------------------------------------

drop function public.create_connect_token();

-- Returns one of:
--   { outcome: 'ok', token, expires_at }
--   { outcome: 'location_required' }   no location from the phone
--   { outcome: 'poor_location' }       accuracy worse than 1 km
--   { outcome: 'rate_limited' }
create or replace function public.create_connect_token(
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_m double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunables. The app rotates every 25 s and after each scan, so 6/min
  -- allows ~5 scans a minute at a busy event.
  c_max_per_minute constant int := 6;
  c_lifetime constant interval := interval '30 seconds';
  c_max_accuracy_m constant float8 := 1000;

  v_me uuid := auth.uid();
  v_token text;
  v_expires timestamptz;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if p_lat is null or p_lng is null or p_accuracy_m is null then
    return jsonb_build_object('outcome', 'location_required');
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy_m <= 0 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;
  if p_accuracy_m > c_max_accuracy_m then
    return jsonb_build_object('outcome', 'poor_location');
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

  insert into public.connect_tokens (token, user_id, expires_at, lat, lng, accuracy_m)
  values (
    v_token, v_me, v_expires,
    round(p_lat::numeric, 3)::double precision,
    round(p_lng::numeric, 3)::double precision,
    p_accuracy_m
  );

  return jsonb_build_object('outcome', 'ok', 'token', v_token, 'expires_at', v_expires);
end;
$$;

revoke execute on function public.create_connect_token(double precision, double precision, double precision)
  from public, anon;
grant execute on function public.create_connect_token(double precision, double precision, double precision)
  to authenticated;

-- ---------------------------------------------------------------------------
-- redeem_connect_token(p_token, p_city, p_lat, p_lng, p_accuracy_m)
-- ---------------------------------------------------------------------------

drop function public.redeem_connect_token(text, text);

-- Same as 20260928020000 (blocks, suspensions -> 'unavailable'), plus the
-- distance check. Returns, on failure:
--   { outcome: 'invalid' | 'used' | 'expired' | 'self' }
--   { outcome: 'location_required' }  the scanner (or the code) has no location
--   { outcome: 'poor_location' }      scanner accuracy worse than 1 km
--   { outcome: 'too_far' }            not together; the code stays usable
--   { outcome: 'unavailable' }        blocked either way / suspended
-- On success: _connect_in_person's result ('created' | 'upgraded' |
-- 'already_connected', connection_id, met_city, undo_until) plus
-- other_user_id and other_profile.
create or replace function public.redeem_connect_token(
  p_token text,
  p_city text default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_m double precision default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tunables.
  c_min_distance_m constant float8 := 300;   -- always allow at least this
  c_max_accuracy_m constant float8 := 1000;  -- worse -> poor_location

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

  -- Both phones must say where they are, and be close enough.
  if p_lat is null or p_lng is null or p_accuracy_m is null or v_tok.lat is null then
    return jsonb_build_object('outcome', 'location_required');
  end if;
  if p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy_m <= 0 then
    raise exception 'invalid_location' using errcode = '22023';
  end if;
  if p_accuracy_m > c_max_accuracy_m then
    return jsonb_build_object('outcome', 'poor_location');
  end if;
  if public._distance_m(p_lat, p_lng, v_tok.lat, v_tok.lng)
     > greatest(c_min_distance_m, v_tok.accuracy_m + p_accuracy_m) then
    -- Not used up: if this was a GPS glitch, scanning again can still work.
    return jsonb_build_object('outcome', 'too_far');
  end if;

  v_city := coalesce(
    nullif(trim(p_city), ''),
    nullif(trim((select city from public.profiles where id = v_me)), ''),
    nullif(trim((select city from public.profiles where id = v_tok.user_id)), '')
  );

  v := public._connect_in_person(v_me, v_tok.user_id, 'qr', v_city);

  if v ->> 'outcome' = 'unavailable' then
    return jsonb_build_object('outcome', 'unavailable');
  end if;

  -- The owner's copy names the scanner as "the other person". The code's
  -- location isn't needed any more, so it goes now.
  update public.connect_tokens set
    used_at = now(),
    used_by = v_me,
    lat = null,
    lng = null,
    accuracy_m = null,
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

revoke execute on function
  public.redeem_connect_token(text, text, double precision, double precision, double precision)
  from public, anon;
grant execute on function
  public.redeem_connect_token(text, text, double precision, double precision, double precision)
  to authenticated;
