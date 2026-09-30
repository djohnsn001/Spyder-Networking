-- Security H5, step 1 of 2: profile photos must live in our own storage.
--
-- Before this, profiles.avatar_url took any string, so someone could point
-- their photo at a server they control and collect the IP address of every
-- person whose app loaded their profile. Now avatar_url must be null or a
-- public URL in the avatars bucket, inside the row owner's own folder:
--
--   <project URL>/storage/v1/object/public/avatars/<profile id>/...
--
-- That is exactly what src/lib/avatar.ts (uploadAvatar -> getPublicUrl) and
-- scripts/update-seed-avatars.js produce.
--
-- Why the project URL is HARD-CODED (not read from a setting):
--   * A check constraint is re-checked on every insert/update, including
--     from triggers and the service role. A database setting
--     (current_setting('app.x')) can be missing in some sessions; a missing
--     value makes the check NULL, and Postgres treats a NULL check as a PASS,
--     so it would silently stop protecting anything. Supabase also limits
--     who can set database-level custom settings.
--   * The URL is not a secret (it ships inside the app).
-- The allowed URLs live in one function, so adding the dev project later is
-- a one-line `create or replace` with no constraint changes. Allowing BOTH of
-- our projects in each database is safe: either one only logs requests to us.
--
-- NOT VALID: the rule applies to every new insert/update from now on, but
-- existing rows aren't checked yet. Step 2 (VALIDATE) is a separate
-- migration, added only after supabase/queries/h5_bad_avatar_urls.sql
-- returns zero rows. Clean bad rows up BEFORE pushing this step: any update
-- to a row that still has a bad URL fails, even one that doesn't touch the
-- photo (for example turning location sharing off).

create or replace function public.avatar_url_allowed(p_profile_id uuid, p_url text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_url is null
    or starts_with(
      p_url,
      -- PRODUCTION project URL (matches EXPO_PUBLIC_SUPABASE_URL).
      'https://fhevoocpcnrjxyjvitai.supabase.co/storage/v1/object/public/avatars/'
        || p_profile_id::text || '/'
    )
    -- DEV project: uncomment with the real ref once it exists.
    -- or starts_with(
    --   p_url,
    --   'https://REPLACE_WITH_DEV_PROJECT_REF.supabase.co/storage/v1/object/public/avatars/'
    --     || p_profile_id::text || '/'
    -- )
    ;
$$;

comment on function public.avatar_url_allowed(uuid, text) is
  'H5: avatar_url must be null or a public avatars-bucket URL in the owner''s own folder on one of our Supabase projects.';

alter table public.profiles
  add constraint profiles_avatar_url_own_storage
  check (public.avatar_url_allowed(id, avatar_url))
  not valid;
