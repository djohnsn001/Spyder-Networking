-- Security item M8: Discover loads profiles a page at a time through one
-- RPC instead of select('*') on the whole profiles table.
--
-- discover_profiles(p_cursor, p_limit, p_search) returns only the columns
-- the Discover card shows, at most 30 rows per call no matter what p_limit
-- asks for, newest profiles first. It skips the caller, profiles that
-- haven't picked a username yet, anyone blocked either way, and suspended
-- accounts. A suspended caller gets nothing.
--
-- Keyset pagination: each row carries an opaque `cursor`; pass the last
-- row's cursor to get the next page. Unlike offset paging, rows can't be
-- skipped or repeated when someone new signs up between pages.
--
-- p_search (optional, extra to the item's two parameters) matches name,
-- username, or an interest. The old screen filtered the full list on the
-- phone; with pages that would only search what's already loaded.
--
-- Not a full scraping fix on its own: the profiles select policy still lets
-- any signed-in user read profiles directly through the API. The dashboard's
-- API "Max rows" (set to 100, see the M8 summary) caps each such request.

-- Matches the ORDER BY below, so each page is an index range scan.
create index if not exists profiles_discover_idx
  on public.profiles (created_at desc, id desc)
  where username is not null;

create or replace function public.discover_profiles(
  p_cursor text default null,
  p_limit integer default 30,
  p_search text default null
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
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$$;

revoke execute on function public.discover_profiles(text, integer, text) from public, anon;
grant execute on function public.discover_profiles(text, integer, text) to authenticated;
