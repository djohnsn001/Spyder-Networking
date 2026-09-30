-- Security M2, step 1 of 2: limits on profile fields.
--
-- Before this, full_name, city and interests had no limits (a 10 MB name
-- was possible) and username only checked its length, so lookalike names
-- ("bolas_support", Cyrillic letters that look Latin) could fool people.
--
-- Rules (the database is the source of truth; profile-form.tsx mirrors them
-- only to show friendly errors):
--   username   a-z, 0-9, _ ; 3-20 chars; saved lower-case (trigger below);
--              unique ignoring case; not a reserved name.
--   full_name  <= 50 characters
--   city       <= 80 characters
--   interests  <= 12 items, no repeats, each from the fixed list in
--              public.profile_interest_options()
--
-- NOT VALID: new inserts/updates are checked from now on; existing rows are
-- checked in step 2 (supabase/pending-migrations/m2_step2_validate_profile_limits.sql)
-- once supabase/queries/m2_profile_limit_violations.sql shows all zeros.
-- Fix bad rows BEFORE pushing this step: a row that breaks a rule can't be
-- updated at all until it's fixed, even to turn location sharing off.
--
-- The unique index on lower(username) is created here, not in step 2. The
-- push fails (and changes nothing) if two usernames differ only in case;
-- the query's case_collisions count must be 0 first.

-- ---------------------------------------------------------------------------
-- Interest list. KEEP IN SYNC with InterestOptions in
-- src/lib/profile-options.ts. `npm run check:interests` compares the two
-- (it reads the newest migration that defines this function). To change the
-- list: edit profile-options.ts, add a migration that re-creates this
-- function with the same list, run the check. To REMOVE an option, first
-- remove it from everyone's interests: existing rows aren't re-checked when
-- this function changes.
-- ---------------------------------------------------------------------------
create or replace function public.profile_interest_options()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
    'SaaS',
    'AI / ML',
    'E-commerce',
    'Marketplace',
    'Fintech',
    'Consumer',
    'Hardware',
    'Health',
    'Education',
    'Social',
    'Sustainability',
    'Creator tools'
  ]::text[];
$$;

create or replace function public.profile_interests_valid(p_interests text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_interests is not null
    and cardinality(p_interests) <= 12
    and array_position(p_interests, null) is null
    and p_interests <@ public.profile_interest_options()
    and cardinality(p_interests) = (select count(distinct i) from unnest(p_interests) as i);
$$;

-- Reserved usernames: names that look official. KEEP IN SYNC with
-- ReservedUsernames in src/lib/profile-options.ts (only for friendly errors).
create or replace function public.username_is_reserved(p_username text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select lower(p_username) = any (array[
      'admin', 'administrator', 'bolas', 'support', 'help', 'team',
      'official', 'security', 'moderator', 'staff'
    ])
    or starts_with(lower(p_username), 'bolas_');
$$;

-- ---------------------------------------------------------------------------
-- Usernames are saved lower-case. The app used to allow capitals, so this
-- runs on every insert and update (not just when username is in the update):
-- an old "Zane" becomes "zane" the next time that row is saved for any
-- reason, instead of blocking the save.
-- ---------------------------------------------------------------------------
create or replace function public.profiles_lowercase_username()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.username := lower(new.username);
  return new;
end;
$$;

revoke execute on function public.profiles_lowercase_username() from public, anon, authenticated;

create trigger profiles_lowercase_username
  before insert or update on public.profiles
  for each row execute function public.profiles_lowercase_username();

-- ---------------------------------------------------------------------------
-- The rules. [a-z] in a Postgres regex means those 26 code points only, so
-- Cyrillic "а" (U+0430) and other lookalikes don't match.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add constraint profiles_username_format
  check (username is null or username ~ '^[a-z0-9_]{3,20}$')
  not valid;

alter table public.profiles
  add constraint profiles_username_not_reserved
  check (username is null or not public.username_is_reserved(username))
  not valid;

alter table public.profiles
  add constraint profiles_full_name_length
  check (full_name is null or char_length(full_name) <= 50)
  not valid;

alter table public.profiles
  add constraint profiles_city_length
  check (city is null or char_length(city) <= 80)
  not valid;

alter table public.profiles
  add constraint profiles_interests_valid
  check (public.profile_interests_valid(interests))
  not valid;

-- "Zane" and "zane" can't both exist. (The old unique constraint on the
-- exact text stays; this one also covers case.)
create unique index profiles_username_lower_key
  on public.profiles (lower(username));
