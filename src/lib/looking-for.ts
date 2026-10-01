import { callRpc } from '@/lib/rpc';

// "Looking For" tags: what someone wants from the network right now. A
// separate dimension from business stage (idea / building / launched).
//
// THE central config: labels, pairs and the reason-line wording all live
// here; logic elsewhere only reads it. Keys and pairs are also enforced by
// the database, so KEEP IN SYNC with public.looking_for_tag_pairs() in the
// newest migration that defines it. `npm run check:looking-for` compares the
// two and checks that every pair goes both ways.
//
// theyPhrase / youPhrase build the Discover reason line:
//   `${name} ${their.theyPhrase} — ${mine.youPhrase}`
//   e.g. "Maya is hiring — you're open to work"

export type LookingForTag =
  | 'hiring'
  | 'open_to_work'
  | 'seeking_investment'
  | 'looking_to_invest'
  | 'need_cofounder'
  | 'open_to_cofounding'
  | 'looking_for_clients'
  | 'looking_for_services'
  | 'looking_for_partners';

export type LookingForTagConfig = {
  key: LookingForTag;
  label: string;
  pairsWith: LookingForTag;
  theyPhrase: string;
  youPhrase: string;
};

export const LookingForTags: LookingForTagConfig[] = [
  { key: 'hiring', label: 'Hiring', pairsWith: 'open_to_work', theyPhrase: 'is hiring', youPhrase: "you're hiring" },
  { key: 'open_to_work', label: 'Open to work', pairsWith: 'hiring', theyPhrase: 'is open to work', youPhrase: "you're open to work" },
  { key: 'seeking_investment', label: 'Seeking investment', pairsWith: 'looking_to_invest', theyPhrase: 'is seeking investment', youPhrase: "you're seeking investment" },
  { key: 'looking_to_invest', label: 'Looking to invest', pairsWith: 'seeking_investment', theyPhrase: 'is looking to invest', youPhrase: "you're looking to invest" },
  { key: 'need_cofounder', label: 'Need co-founder', pairsWith: 'open_to_cofounding', theyPhrase: 'needs a co-founder', youPhrase: 'you need a co-founder' },
  { key: 'open_to_cofounding', label: 'Open to co-founding', pairsWith: 'need_cofounder', theyPhrase: 'is open to co-founding', youPhrase: "you're open to co-founding" },
  { key: 'looking_for_clients', label: 'Looking for clients', pairsWith: 'looking_for_services', theyPhrase: 'is looking for clients', youPhrase: "you're looking for clients" },
  { key: 'looking_for_services', label: 'Looking for services', pairsWith: 'looking_for_clients', theyPhrase: 'is looking for services', youPhrase: "you're looking for services" },
  { key: 'looking_for_partners', label: 'Looking for partners', pairsWith: 'looking_for_partners', theyPhrase: 'is looking for partners', youPhrase: "you're looking for partners" },
];

// Mirrors the database (profiles_looking_for_valid, looking_for_is_fresh);
// the app only uses these to explain things before saving.
export const LookingForLimit = 3;
export const LookingForStaleDays = 90;

const byKey = new Map(LookingForTags.map((tag) => [tag.key, tag]));

export function getLookingForTag(key: string): LookingForTagConfig | null {
  return byKey.get(key as LookingForTag) ?? null;
}

export function getLookingForLabel(key: string) {
  return getLookingForTag(key)?.label ?? null;
}

// Keeps only known tags, in config order, without repeats.
export function normalizeLookingFor(tags: readonly string[] | null | undefined): LookingForTag[] {
  const set = new Set(tags ?? []);
  return LookingForTags.filter((tag) => set.has(tag.key)).map((tag) => tag.key);
}

export function isLookingForStale(updatedAt: string | null | undefined, now = Date.now()) {
  if (!updatedAt) return true;
  const time = Date.parse(updatedAt);
  if (Number.isNaN(time)) return true;
  return now - time > LookingForStaleDays * 24 * 60 * 60 * 1000;
}

// "updated today", "updated 3 days ago", "updated 2 mo ago".
export function formatTagsUpdatedAgo(updatedAt: string | null | undefined, now = Date.now()) {
  if (!updatedAt) return null;
  const time = Date.parse(updatedAt);
  if (Number.isNaN(time)) return null;
  const days = Math.max(0, Math.floor((now - time) / (24 * 60 * 60 * 1000)));
  if (days === 0) return 'updated today';
  if (days === 1) return 'updated yesterday';
  if (days < 30) return `updated ${days} days ago`;
  const months = Math.floor(days / 30);
  if (months < 12) return `updated ${months} mo ago`;
  const years = Math.floor(months / 12);
  return `updated ${years} yr ago`;
}

// The one-line reason on a suggestion card.
export function buildMatchReason(name: string, myTag: string, theirTag: string) {
  const mine = getLookingForTag(myTag);
  const theirs = getLookingForTag(theirTag);
  if (!mine || !theirs) return null;
  if (mine.key === theirs.key) return `${name} ${theirs.theyPhrase.replace(/^is /, 'is also ')}`;
  return `${name} ${theirs.theyPhrase} — ${mine.youPhrase}`;
}

// One row of suggested_matches().
export type SuggestedMatch = {
  id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
  city: string | null;
  business_stage: string | null;
  looking_for: string[];
  tags_updated_at: string | null;
  my_tag: string;
  their_tag: string;
  mutual_count: number;
  same_city: boolean;
  is_stale: boolean;
};

// Everyone gets these (not premium). The server ranks and caps them, and
// skips me, blocks, suspended accounts and people I've met in person.
export async function fetchSuggestedMatches(limit = 20): Promise<SuggestedMatch[]> {
  const rows = await callRpc<SuggestedMatch[] | null>('suggested_matches', { p_limit: limit });
  return rows ?? [];
}

export type LookingForInfo = { looking_for: string[]; tags_updated_at: string | null };

// Someone else's tags (they aren't a readable column; see the migration).
// Null when their profile is hidden from me.
export async function fetchLookingFor(userId: string): Promise<LookingForInfo | null> {
  const rows = await callRpc<LookingForInfo[] | null>('get_looking_for', { p_user_id: userId });
  return rows?.[0] ?? null;
}

// "Still accurate": restarts the 90-day clock.
export async function confirmLookingFor() {
  await callRpc('confirm_looking_for');
}
