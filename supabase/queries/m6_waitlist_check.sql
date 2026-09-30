-- Security M6: READ-ONLY check of the waitlist after 20260929090000.
-- Run in the Supabase SQL editor. Shows counts only, no emails.
--   bad_format        rows that fail the email check (keep the constraint NOT VALID)
--   not_normalized    rows with capitals or spaces left over
--   case_duplicates   extra rows that only differ by case from another row
--   constraint_valid  true once Postgres trusts the check for every row
select
  (select count(*) from public.waitlist
    where not (char_length(email) <= 254
      and email ~ '^[^[:space:][:cntrl:]@]+@[^[:space:][:cntrl:]@]+\.[^[:space:][:cntrl:]@]+$')) as bad_format,
  (select count(*) from public.waitlist where email <> lower(btrim(email))) as not_normalized,
  (select count(*) - count(distinct lower(btrim(email))) from public.waitlist) as case_duplicates,
  (select convalidated from pg_constraint where conname = 'waitlist_email_valid') as constraint_valid;
