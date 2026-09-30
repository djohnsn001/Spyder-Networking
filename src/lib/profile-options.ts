import type { BusinessStage } from '@/lib/types';

export const BusinessStages: { value: BusinessStage; label: string }[] = [
  { value: 'idea', label: 'Idea' },
  { value: 'building', label: 'Building' },
  { value: 'launched', label: 'Launched' },
];

// KEEP IN SYNC with public.profile_interest_options() in the newest
// migration that defines it: the database rejects anything not on its list.
// `npm run check:interests` compares the two.
export const InterestOptions = [
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
  'Creator tools',
];

// The database is the source of truth for these (security item M2,
// migration 20260929050000); they're mirrored here only so the form can
// explain a problem before saving.
export const UsernamePattern = /^[a-z0-9_]{3,20}$/;
export const BioLimit = 160;
export const FullNameLimit = 50;
export const CityLimit = 80;
export const InterestLimit = 12;

// KEEP IN SYNC with public.username_is_reserved() (`npm run check:interests`
// checks this list too). Anything starting with ReservedUsernamePrefix is
// also reserved.
export const ReservedUsernames = [
  'admin',
  'administrator',
  'bolas',
  'support',
  'help',
  'team',
  'official',
  'security',
  'moderator',
  'staff',
];
export const ReservedUsernamePrefix = 'bolas_';

export function isReservedUsername(username: string) {
  const lower = username.toLowerCase();
  return ReservedUsernames.includes(lower) || lower.startsWith(ReservedUsernamePrefix);
}

export function getBusinessStageLabel(stage: BusinessStage | null) {
  return BusinessStages.find((option) => option.value === stage)?.label ?? null;
}
