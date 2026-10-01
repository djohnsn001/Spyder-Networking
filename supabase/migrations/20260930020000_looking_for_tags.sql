-- "Looking For" tags, suggested matches in Discover, and the premium-only
-- tag filter.
--
-- 1. profiles.looking_for: 0-3 intent tags ("hiring", "open_to_work", ...),
--    separate from business_stage. The database enforces the list and the
--    limit (profiles_looking_for_valid).
-- 2. profiles.tags_updated_at: stamped by the server whenever the tags change
--    or the owner confirms them (confirm_looking_for). Clients can't backdate
--    it. Tags older than 90 days are "stale": suggested_matches puts them at
--    the bottom and the tag filter ignores them.
-- 3. profiles.is_premium: set by the server only (later, by the in-app
--    purchase webhook). A client that tries to change it gets an error.
-- 4. suggested_matches(): free for everyone. People whose tags pair with
--    yours, ranked: fresh first, then mutual connections, then same city
--    (the public city field, never map location), then most recently
--    updated tags. Skips you, blocks either way, suspended accounts, and
--    people you've already met in person.
-- 5. discover_profiles() gains p_looking_for. Filtering by tag needs
--    is_premium, checked here in the database.
--
-- Tags are public (shown on every profile), but looking_for,
-- tags_updated_at and is_premium are deliberately NOT added to the column
-- select grant from 20260930000000. Other people read tags only through the
-- functions below, so nobody can filter by tag with a direct table query
-- and skip the premium check. (Anyone can still scroll Discover and read the
-- tags on each card; the check is on filtering, not on seeing.)
--
-- Apply this migration BEFORE shipping the app build that sends
-- p_looking_for: the old build keeps working against it (the new parameter
-- has a default).

-- ---------------------------------------------------------------------------
-- 1. The tag list and who pairs with whom. KEEP IN SYNC with LookingForTags
-- in src/lib/looking-for.ts; `npm run check:looking-for` compares the two
-- (it reads the newest migration that defines this function). To change a
-- pair or add a tag: edit looking-for.ts, add a migration that re-creates
-- this function, run the check. Labels live only in the app.
-- ---------------------------------------------------------------------------
create or replace function public.looking_for_tag_pairs()
returns table (tag text, pairs_with text)
language sql
immutable
set search_path = ''
as $$
  select t.tag, t.pairs_with
  from (values
    ('hiring', 'open_to_work'),
    ('open_to_work', 'hiring'),
    ('seeking_investment', 'looking_to_invest'),
    ('looking_to_invest', 'seeking_investment'),
    ('need_cofounder', 'open_to_cofounding'),
    ('open_to_cofounding', 'need_cofounder'),
    ('looking_for_clients', 'looking_for_services'),
    ('looking_for_services', 'looking_for_clients'),
    ('looking_for_partners', 'looking_for_partners')
  ) as t (tag, pairs_with);
$$;

-- 0-3 known tags, no repeats, no nulls.
create or replace function public.profile_looking_for_valid(p_tags text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_tags is not null
    and cardinality(p_tags) <= 3
    and array_position(p_tags, null) is null
    and p_tags <@ (select array_agg(t.tag) from public.looking_for_tag_pairs() as t)
    and cardinality(p_tags) = (select count(distinct x) from unnest(p_tags) as x);
$$;

-- Fresh = changed or confirmed within 90 days. KEEP IN SYNC with
-- LookingForStaleDays in src/lib/looking-for.ts (the check script compares).
create or replace function public.looking_for_is_fresh(p_updated_at timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_updated_at is not null and p_updated_at >= now() - interval '90 days';
$$;

-- The check constraint runs as the caller, so authenticated needs execute
-- (same as profile_interests_valid).
revoke execute on function public.looking_for_tag_pairs() from public, anon;
revoke execute on function public.profile_looking_for_valid(text[]) from public, anon;
revoke execute on function public.looking_for_is_fresh(timestamptz) from public, anon;
grant execute on function public.looking_for_tag_pairs() to authenticated;
grant execute on function public.profile_looking_for_valid(text[]) to authenticated;
grant execute on function public.looking_for_is_fresh(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Columns
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column looking_for text[] not null default '{}',
  add column tags_updated_at timestamptz,
  add column is_premium boolean not null default false;

-- Every existing row has '{}', so this can be checked right away.
alter table public.profiles
  add constraint profiles_looking_for_valid
  check (public.profile_looking_for_valid(looking_for));

-- suggested_matches and the tag filter look up "anyone with one of these
-- tags" (&&). Not a partial index: the planner can't tell that && implies
-- a non-empty array, so a "where cardinality(...) > 0" index would never
-- be used by those queries.
create index profiles_looking_for_idx
  on public.profiles using gin (looking_for);

-- ---------------------------------------------------------------------------
-- 3. Guard: premium is server-managed; tag timestamps are real time.
--
-- For client writes (_is_untrusted_write: the app/web, not a trusted
-- function or the dashboard):
--   - is_premium can't be set on insert or changed on update;
--   - tags_updated_at is stamped with now() whenever looking_for changes or
--     the client touches tags_updated_at at all (that's "confirm"), so it
--     can't be backdated or pushed into the future; it's null with no tags.
-- Server writes (tests, the future purchase webhook) may set both freely;
-- if they change the tags without giving a time, it's stamped too.
-- Definer so it can call _is_untrusted_write (no client grants).
-- ---------------------------------------------------------------------------
create or replace function public.profiles_guard_looking_for_and_premium()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_untrusted boolean := public._is_untrusted_write();
begin
  if tg_op = 'INSERT' then
    if v_untrusted then
      new.is_premium := false;
    end if;
    if v_untrusted or new.tags_updated_at is null then
      new.tags_updated_at := case when cardinality(new.looking_for) > 0 then now() end;
    end if;
    return new;
  end if;

  if v_untrusted and new.is_premium is distinct from old.is_premium then
    raise exception 'premium_is_server_managed' using errcode = '42501';
  end if;

  if v_untrusted then
    if new.looking_for is distinct from old.looking_for
       or new.tags_updated_at is distinct from old.tags_updated_at then
      new.tags_updated_at := case when cardinality(new.looking_for) > 0 then now() end;
    end if;
  elsif new.looking_for is distinct from old.looking_for
        and new.tags_updated_at is not distinct from old.tags_updated_at then
    new.tags_updated_at := case when cardinality(new.looking_for) > 0 then now() end;
  end if;

  return new;
end;
$$;

revoke execute on function public.profiles_guard_looking_for_and_premium() from public, anon, authenticated;

create trigger profiles_guard_looking_for_and_premium
  before insert or update on public.profiles
  for each row execute function public.profiles_guard_looking_for_and_premium();

-- ---------------------------------------------------------------------------
-- 4. Reading and confirming tags
-- ---------------------------------------------------------------------------

-- Someone's tags for their profile page. Same visibility as the profile
-- itself: yourself always; otherwise nothing if blocked either way or
-- suspended. Returns no row when hidden (the app shows no tags).
create or replace function public.get_looking_for(p_user_id uuid)
returns table (looking_for text[], tags_updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  return query
  select p.looking_for, p.tags_updated_at
  from public.profiles p
  where p.id = p_user_id
    and (
      p.id = v_me
      or (not public._blocked_between(v_me, p.id) and not public.is_suspended(p.id))
    );
end;
$$;

revoke execute on function public.get_looking_for(uuid) from public, anon;
grant execute on function public.get_looking_for(uuid) to authenticated;

-- "These are still right": resets the 90-day clock. Returns the new time,
-- or null if you have no tags.
create or replace function public.confirm_looking_for()
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_at timestamptz;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- The guard trigger stamps now() (this is a client-role write).
  update public.profiles p
  set tags_updated_at = now()
  where p.id = v_me and cardinality(p.looking_for) > 0
  returning p.tags_updated_at into v_at;

  return v_at;
end;
$$;

revoke execute on function public.confirm_looking_for() from public, anon;
grant execute on function public.confirm_looking_for() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Suggested for you (free)
-- ---------------------------------------------------------------------------

-- At most p_limit (default 20, max 50) people whose tags pair with the
-- caller's, one row each, with the pair that matched (for the reason line).
-- is_stale: the caller's or their tags are older than 90 days; those rows
-- come last. No rows if the caller has no tags or is suspended.
create or replace function public.suggested_matches(p_limit integer default 20)
returns table (
  id uuid,
  username text,
  full_name text,
  avatar_url text,
  city text,
  business_stage text,
  looking_for text[],
  tags_updated_at timestamptz,
  my_tag text,
  their_tag text,
  mutual_count integer,
  same_city boolean,
  is_stale boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_my_tags text[];
  v_my_fresh boolean;
  v_my_city text;
  v_wanted text[];
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if public.is_suspended(v_me) then
    return;
  end if;

  select me.looking_for, public.looking_for_is_fresh(me.tags_updated_at), lower(nullif(trim(me.city), ''))
  into v_my_tags, v_my_fresh, v_my_city
  from public.profiles me
  where me.id = v_me;

  if v_my_tags is null or cardinality(v_my_tags) = 0 then
    return;
  end if;

  select array_agg(distinct lp.pairs_with)
  into v_wanted
  from public.looking_for_tag_pairs() lp
  where lp.tag = any (v_my_tags);

  -- Every name below is qualified: the output columns (id, city, ...) are
  -- also PL/pgSQL variables here.
  return query
  with my_connections as (
    select
      case when c.requester_id = v_me then c.addressee_id else c.requester_id end as other_id,
      c.level::text as lvl
    from public.connections c
    where c.status = 'accepted'
      and (c.requester_id = v_me or c.addressee_id = v_me)
  ),
  pairs as (
    select lp.tag as mine, lp.pairs_with as theirs
    from public.looking_for_tag_pairs() lp
    where lp.tag = any (v_my_tags)
  ),
  candidates as (
    -- One row per person: the first matching pair by my tag.
    select distinct on (p.id)
      p.id as cand_id,
      p.username as cand_username,
      p.full_name as cand_full_name,
      p.avatar_url as cand_avatar_url,
      p.city as cand_city,
      p.business_stage as cand_stage,
      p.looking_for as cand_tags,
      p.tags_updated_at as cand_tags_at,
      pr.mine as pair_mine,
      pr.theirs as pair_theirs,
      not (v_my_fresh and public.looking_for_is_fresh(p.tags_updated_at)) as cand_stale,
      (v_my_city is not null and lower(trim(coalesce(p.city, ''))) = v_my_city) as cand_same_city
    from public.profiles p
    join pairs pr on pr.theirs = any (p.looking_for)
    where p.looking_for && v_wanted
      and p.id <> v_me
      and p.username is not null
      and not public._blocked_between(v_me, p.id)
      and not exists (select 1 from public.account_restrictions r where r.user_id = p.id)
      and not exists (
        select 1 from my_connections mc
        where mc.other_id = p.id and mc.lvl = 'in_person'
      )
    order by p.id, pr.mine
  ),
  ranked as (
    select
      cd.*,
      (
        select count(*)::integer
        from my_connections mc
        where exists (
          select 1 from public.connections c2
          where c2.status = 'accepted'
            and (
              (c2.requester_id = cd.cand_id and c2.addressee_id = mc.other_id)
              or (c2.addressee_id = cd.cand_id and c2.requester_id = mc.other_id)
            )
        )
      ) as cand_mutuals
    from candidates cd
  )
  select
    rk.cand_id,
    rk.cand_username,
    rk.cand_full_name,
    rk.cand_avatar_url,
    rk.cand_city,
    rk.cand_stage,
    rk.cand_tags,
    rk.cand_tags_at,
    rk.pair_mine,
    rk.pair_theirs,
    rk.cand_mutuals,
    rk.cand_same_city,
    rk.cand_stale
  from ranked rk
  order by
    rk.cand_stale,
    rk.cand_mutuals desc,
    rk.cand_same_city desc,
    rk.cand_tags_at desc nulls last,
    rk.cand_id
  limit v_limit;
end;
$$;

revoke execute on function public.suggested_matches(integer) from public, anon;
grant execute on function public.suggested_matches(integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. discover_profiles: returns tags; p_looking_for is premium-only
--
-- Same as 20260930010000 plus:
--   - looking_for and tags_updated_at in each row (tags are public);
--   - p_looking_for text[]: people with any of these tags, fresh tags only.
--     A non-premium caller who sends it gets 'premium_required' (42501).
-- The return type changes, so the old version is dropped first.
-- ---------------------------------------------------------------------------

drop function if exists public.discover_profiles(text, integer, text, text[], text[], text);

create or replace function public.discover_profiles(
  p_cursor text default null,
  p_limit integer default 30,
  p_search text default null,
  p_stages text[] default null,
  p_interests text[] default null,
  p_city text default null,
  p_looking_for text[] default null
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
  looking_for text[],
  tags_updated_at timestamptz,
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
  -- options are 3 stages, 12 interests and 9 tags; unknown values just
  -- match nothing.
  v_stages text[] := (select array_agg(s) from (select distinct s from unnest(p_stages) s where s is not null limit 10) x);
  v_interests text[] := (select array_agg(i) from (select distinct i from unnest(p_interests) i where i is not null limit 20) x);
  v_tags text[] := (select array_agg(t) from (select distinct t from unnest(p_looking_for) t where t is not null limit 10) x);
  v_after_ts timestamptz;
  v_after_id uuid;
begin
  if v_me is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  if public.is_suspended(v_me) then
    return;
  end if;

  -- The premium gate. Checked here, not just hidden in the app.
  if v_tags is not null
     and not coalesce((select me.is_premium from public.profiles me where me.id = v_me), false) then
    raise exception 'premium_required' using errcode = '42501',
      hint = 'Filtering Discover by Looking For tags is a Premium feature.';
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
    p.looking_for,
    p.tags_updated_at,
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
    and (v_tags is null or (p.looking_for && v_tags and public.looking_for_is_fresh(p.tags_updated_at)))
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$$;

revoke execute on function public.discover_profiles(text, integer, text, text[], text[], text, text[]) from public, anon;
grant execute on function public.discover_profiles(text, integer, text, text[], text[], text, text[]) to authenticated;
