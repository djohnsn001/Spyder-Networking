-- Reverts 20260918000000_add_building_description.sql.
-- Redundant with business_stage's "building" value showing right below it
-- on the profile screen, so dropping it rather than keeping unused data.
alter table public.profiles
  drop column if exists building_description;
