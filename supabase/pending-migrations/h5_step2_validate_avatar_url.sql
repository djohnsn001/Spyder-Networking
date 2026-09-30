-- Security H5, step 2 of 2: check the rows that already exist.
--
-- NOT IN supabase/migrations ON PURPOSE. Step 1 (20260929040000) made the
-- rule apply to new writes; this makes Postgres check every existing row too,
-- after which the constraint is fully trusted.
--
-- Only when supabase/queries/h5_bad_avatar_urls.sql returns ZERO rows on
-- the project you're pushing to: move this file into supabase/migrations
-- with a fresh timestamp name (e.g. <today>000000_validate_avatar_url.sql)
-- and db push. If a bad row is still there, VALIDATE fails, the push stops
-- and nothing changes, so it's safe, just noisy.
--
-- VALIDATE doesn't block normal reads or writes while it scans.

alter table public.profiles
  validate constraint profiles_avatar_url_own_storage;
