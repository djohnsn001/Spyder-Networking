-- Security M2, step 2 of 2: check the profile rows that already exist.
--
-- NOT IN supabase/migrations ON PURPOSE. Step 1 (20260929050000) made the
-- rules apply to new writes; this makes Postgres check every existing row
-- too, after which the constraints are fully trusted.
--
-- Only when supabase/queries/m2_profile_limit_violations.sql shows ALL
-- ZEROS on the project you're pushing to: move this file into
-- supabase/migrations with a fresh timestamp name (e.g.
-- <today>000000_validate_profile_limits.sql) and db push. If a bad row is
-- still there, the push fails and nothing changes, so it's safe, just noisy.
--
-- VALIDATE doesn't block normal reads or writes while it scans.

alter table public.profiles validate constraint profiles_username_format;
alter table public.profiles validate constraint profiles_username_not_reserved;
alter table public.profiles validate constraint profiles_full_name_length;
alter table public.profiles validate constraint profiles_city_length;
alter table public.profiles validate constraint profiles_interests_valid;
