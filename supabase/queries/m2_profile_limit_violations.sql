-- Review for security item M2 (READ-ONLY).
--
-- Counts existing profiles that break each new rule from
-- 20260929050000_profile_field_limits.sql. Works before or after that
-- migration (the rules are written out here, not called).
--
-- It only reads. The first line makes the whole run read-only, so even a
-- mistake can't write. Paste it into the Supabase SQL editor, or:
--   npx supabase db query --linked -f supabase/queries/m2_profile_limit_violations.sql
-- (check which project is linked first: cat supabase/.temp/project-ref)
--
-- Before pushing step 1: case_collisions must be 0 (the unique index would
-- fail) and ideally every count is 0 (a row that breaks a rule can't be
-- saved at all until it's fixed). Before step 2 (VALIDATE): all zeros.
-- username_has_capitals alone is fixed automatically the next time that row
-- is saved, but VALIDATE needs it fixed first.
--
-- Seed accounts (@bolas-seed.local): supabase/queries/m2_fix_seed_profiles.sql
-- fixes them. The second query below lists every bad row with the reason,
-- so real users can be handled one by one.
--
-- The reserved list and interest list must match the migration's
-- username_is_reserved() and profile_interest_options().

set transaction read only;

with rules as (
  select
    p.id,
    p.username,
    p.username is not null and p.username <> lower(p.username)
      as username_has_capitals,
    p.username is not null and lower(p.username) !~ '^[a-z0-9_]{3,20}$'
      as username_bad_format,
    p.username is not null and (
      lower(p.username) = any (array[
        'admin', 'administrator', 'bolas', 'support', 'help', 'team',
        'official', 'security', 'moderator', 'staff'])
      or starts_with(lower(p.username), 'bolas_')
    ) as username_reserved,
    p.full_name is not null and char_length(p.full_name) > 50 as full_name_too_long,
    p.city is not null and char_length(p.city) > 80 as city_too_long,
    cardinality(p.interests) > 12 as interests_too_many,
    exists (
      select 1 from unnest(p.interests) as i
      where i is null or i <> all (array[
        'SaaS', 'AI / ML', 'E-commerce', 'Marketplace', 'Fintech', 'Consumer',
        'Hardware', 'Health', 'Education', 'Social', 'Sustainability', 'Creator tools'])
    ) as interests_unknown,
    cardinality(p.interests) <> (select count(distinct i) from unnest(p.interests) as i)
      as interests_repeated
  from public.profiles p
)
select
  count(*) filter (where username_has_capitals) as username_has_capitals,
  count(*) filter (where username_bad_format)   as username_bad_format,
  count(*) filter (where username_reserved)     as username_reserved,
  (select count(*) from (
     select lower(username) from public.profiles
     where username is not null
     group by 1 having count(*) > 1) d)         as case_collisions,
  count(*) filter (where full_name_too_long)    as full_name_too_long,
  count(*) filter (where city_too_long)         as city_too_long,
  count(*) filter (where interests_too_many)    as interests_too_many,
  count(*) filter (where interests_unknown)     as interests_unknown,
  count(*) filter (where interests_repeated)    as interests_repeated
from rules;

-- Every row that breaks something, with the reasons. (Long values are cut
-- to 60 characters for display.)
with rules as (
  select
    p.id,
    left(p.username, 60) as username,
    left(p.full_name, 60) as full_name,
    char_length(p.full_name) as full_name_chars,
    char_length(p.city) as city_chars,
    p.interests,
    array_remove(array[
      case when p.username <> lower(p.username) then 'username_has_capitals' end,
      case when lower(p.username) !~ '^[a-z0-9_]{3,20}$' then 'username_bad_format' end,
      case when lower(p.username) = any (array[
             'admin', 'administrator', 'bolas', 'support', 'help', 'team',
             'official', 'security', 'moderator', 'staff'])
             or starts_with(lower(p.username), 'bolas_') then 'username_reserved' end,
      case when exists (select 1 from public.profiles o
                        where o.id <> p.id and lower(o.username) = lower(p.username))
           then 'case_collision' end,
      case when char_length(p.full_name) > 50 then 'full_name_too_long' end,
      case when char_length(p.city) > 80 then 'city_too_long' end,
      case when cardinality(p.interests) > 12 then 'interests_too_many' end,
      case when exists (
             select 1 from unnest(p.interests) as i
             where i is null or i <> all (array[
               'SaaS', 'AI / ML', 'E-commerce', 'Marketplace', 'Fintech', 'Consumer',
               'Hardware', 'Health', 'Education', 'Social', 'Sustainability', 'Creator tools']))
           then 'interests_unknown' end,
      case when cardinality(p.interests) <> (select count(distinct i) from unnest(p.interests) as i)
           then 'interests_repeated' end
    ], null) as problems
  from public.profiles p
)
select r.id, r.username, r.full_name, r.full_name_chars, r.city_chars, r.interests, r.problems,
       u.email like '%@bolas-seed.local' as is_seed_account
from rules r
left join auth.users u on u.id = r.id
where cardinality(r.problems) > 0
order by is_seed_account, r.username;
