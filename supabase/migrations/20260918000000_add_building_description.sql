-- What the person is actually working on, in their own words.
-- Distinct from business_stage, which is just idea/building/launched.
alter table public.profiles
  add column if not exists building_description text
  check (char_length(building_description) <= 160);
