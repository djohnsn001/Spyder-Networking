-- One-time backfill for 20260930030000_profile_stats_and_badges.sql.
-- Run once per project AFTER that migration, dev first:
--
--   npx supabase db query --linked -f supabase/queries/backfill_stats_and_badges.sql
--
-- What it does (safe to run again; it skips what's already done):
--   1. Recounts every profile's in-person connections and acquaintances into
--      profile_stats, and awards the connection milestone badges they've
--      already reached (First Handshake, Connector, ...).
--   2. Completes and numbers every profile that's already complete
--      (username, full name, city, business stage), in sign-up order, so the
--      earliest accounts get the lowest Founder / Early Member numbers.
--   Events attended / hosted start at 0: no check-ins existed before.
--
-- Returns { profiles_recounted, profiles_numbered }.

select public.backfill_stats_and_badges();

-- Check the result: numbers in order, with their badge.
select p.username, p.member_number, p.profile_completed_at, ub.badge_key
from public.profiles p
left join public.user_badges ub
  on ub.user_id = p.id and ub.badge_key in ('founder', 'early_member')
order by p.member_number nulls last, p.created_at;
