-- Discover filters: business stage, interests, and city, on top of the
-- existing search (20260929110000_discover_profiles.sql).
--
-- discover_profiles gains three optional parameters:
--   p_stages    text[]  match any of these business stages
--   p_interests text[]  match anyone with at least one of these interests
--   p_city      text    case-insensitive "contains" on city
-- Null or empty means "no filter". Everything else (the 30-row cap, keyset
-- paging, skipping me / blocked / suspended / no-username) is unchanged.
--
-- The old 3-argument version is dropped: two overloads that both have
-- defaults make PostgREST calls ambiguous. Apply this migration BEFORE
-- shipping the app build that sends the new parameters.

drop function if exists public.discover_profiles(text, integer, text);

create or replace function public.discover_profiles(
  p_cursor text default null,
  p_limit integer default 30,
  p_search text default null,
  p_stages text[] default null,
  p_interests text[] default null,
  p_city text default null
)
returns table (
  id uuid,
  username text,
  full_name text,
  avatar_url text,
  bio text,
  interests text[],
  business_stage text,
  city text,
  cursor text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 30);
  v_search text := lower(left(nullif(trim(p_search), ''), 100));
  v_city text := lower(left(nullif(trim(p_city), ''), 80));
  -- Filter lists are capped so a caller can't send a huge array. Real
  -- options are 3 stages and 12 interests; unknown values just match nothing.
  v_stages text[] := (select array_agg(s) from (select distinct s from unnest(p_stages) s where s is not null limit 10) x);
  v_interests text[] := (select array_agg(i) from (select distinct i from unnest(p_interests) i where i is not null limit 20) x);
  v_after_ts timestamptz;
  v_after_id uuid;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if public.is_suspended(v_me) then
    return;
  end if;

  if p_cursor is not null then
    begin
      v_after_ts := split_part(p_cursor, '|', 1)::timestamptz;
      v_after_id := split_part(p_cursor, '|', 2)::uuid;
    exception when others then
      raise exception 'invalid_cursor' using errcode = '22023';
    end;
    if v_after_ts is null or v_after_id is null then
      raise exception 'invalid_cursor' using errcode = '22023';
    end if;
  end if;

  return query
  select
    p.id,
    p.username,
    p.full_name,
    p.avatar_url,
    p.bio,
    p.interests,
    p.business_stage,
    p.city,
    -- UTC with an explicit Z, so parsing it back doesn't depend on the
    -- session's timezone or DateStyle.
    to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') || '|' || p.id
  from public.profiles p
  where p.id <> v_me
    and p.username is not null
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = v_me and b.blocked_id = p.id)
         or (b.blocker_id = p.id and b.blocked_id = v_me)
    )
    and not exists (select 1 from public.account_restrictions r where r.user_id = p.id)
    and (p_cursor is null or (p.created_at, p.id) < (v_after_ts, v_after_id))
    -- strpos, not ilike: a search for "%" or "_" is plain text, not a wildcard.
    and (
      v_search is null
      or strpos(lower(coalesce(p.full_name, '')), v_search) > 0
      or strpos(lower(p.username), v_search) > 0
      or exists (select 1 from unnest(p.interests) i where strpos(lower(i), v_search) > 0)
    )
    and (v_stages is null or p.business_stage = any (v_stages))
    and (v_interests is null or p.interests && v_interests)
    and (v_city is null or strpos(lower(coalesce(p.city, '')), v_city) > 0)
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$$;

revoke execute on function public.discover_profiles(text, integer, text, text[], text[], text) from public, anon;
grant execute on function public.discover_profiles(text, integer, text, text[], text[], text) to authenticated;
