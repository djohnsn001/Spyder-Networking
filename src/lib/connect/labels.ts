import type { ConnectionLevel } from '@/lib/types';

// Every user-facing name for a connection level comes from here, so renaming
// a level (e.g. once "Map connection" gets its final name) is a one-line change.
export const CONNECTION_LEVEL_LABEL: Record<ConnectionLevel, string> = {
  acquaintance: 'Acquaintance',
  in_person: 'Map connection',
};

export const CONNECTION_LEVEL_LABEL_PLURAL: Record<ConnectionLevel, string> = {
  acquaintance: 'Acquaintances',
  in_person: 'Map connections',
};

// For mid-sentence use: "You're now map connections".
export const CONNECTION_LEVEL_LABEL_IN_SENTENCE: Record<ConnectionLevel, string> = {
  acquaintance: 'acquaintances',
  in_person: 'map connections',
};

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

// "Met Sep 27 · Boise" (city left off when unknown).
export function formatMet(metAt: string | null, metCity: string | null): string | null {
  if (!metAt) return null;
  const date = new Date(metAt);
  const when = `Met ${MONTHS[date.getMonth()]} ${date.getDate()}`;
  return metCity ? `${when} · ${metCity}` : when;
}
