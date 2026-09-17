import type { BusinessStage } from '@/lib/types';

export const BusinessStages: { value: BusinessStage; label: string }[] = [
  { value: 'idea', label: 'Idea' },
  { value: 'building', label: 'Building' },
  { value: 'launched', label: 'Launched' },
];

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

export const UsernamePattern = /^[a-zA-Z0-9_]{3,20}$/;
export const BioLimit = 160;

export function getBusinessStageLabel(stage: BusinessStage | null) {
  return BusinessStages.find((option) => option.value === stage)?.label ?? null;
}
