import { callRpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';

// Badges and profile stats (migration 20260930030000). The database decides
// who earns what; the app only reads, marks toasts seen, and picks featured
// badges. The badge config (names, descriptions, placeholder icons,
// thresholds) lives in public.badge_definitions, so it's fetched rather than
// duplicated here.

export type BadgeStyle = 'founder' | 'early_member' | 'supporter' | 'milestone';

export type BadgeDefinition = {
  key: string;
  name: string;
  description: string;
  icon: string;
  style: BadgeStyle;
  numbered: boolean;
  sort_order: number;
};

// One badge someone has earned.
export type EarnedBadge = {
  badge_key: string;
  number: number | null;
  awarded_at: string;
  featured_rank: number | null;
};

export type ProfileStats = {
  in_person_connections: number;
  events_attended: number;
  events_hosted: number;
  // Only for your own profile; null for everyone else.
  acquaintances: number | null;
};

export const FeaturedBadgeLimit = 3;

let definitionsPromise: Promise<Map<string, BadgeDefinition>> | null = null;

// The badge config rarely changes, so it's loaded once per app run.
export function fetchBadgeDefinitions(): Promise<Map<string, BadgeDefinition>> {
  if (!definitionsPromise) {
    definitionsPromise = (async () => {
      const { data, error } = await supabase
        .from('badge_definitions')
        .select('key, name, description, icon, style, numbered, sort_order')
        .order('sort_order');
      if (error) throw error;
      return new Map((data ?? []).map((row) => [row.key, row as BadgeDefinition]));
    })().catch((error) => {
      definitionsPromise = null;
      throw error;
    });
  }
  return definitionsPromise;
}

// "#047": numbered badges always show three digits.
export function formatBadgeNumber(number: number) {
  return `#${String(number).padStart(3, '0')}`;
}

// "Founder #047", or just "Connector".
export function badgeLabel(definition: BadgeDefinition | undefined, badge: EarnedBadge) {
  const name = definition?.name ?? badge.badge_key;
  return badge.number != null ? `${name} ${formatBadgeNumber(badge.number)}` : name;
}

export async function fetchProfileBadges(userId: string): Promise<EarnedBadge[]> {
  return (await callRpc<EarnedBadge[] | null>('get_profile_badges', { p_user_id: userId })) ?? [];
}

// Null when the profile is hidden from me.
export async function fetchProfileStats(userId: string): Promise<ProfileStats | null> {
  const rows = await callRpc<ProfileStats[] | null>('get_profile_stats', { p_user_id: userId });
  return rows?.[0] ?? null;
}

export async function fetchUnseenBadges(): Promise<EarnedBadge[]> {
  const rows = await callRpc<Omit<EarnedBadge, 'featured_rank'>[] | null>('get_unseen_badges');
  return (rows ?? []).map((row) => ({ ...row, featured_rank: null }));
}

export async function markBadgesSeen(keys: string[]) {
  if (keys.length === 0) return;
  await callRpc('mark_badges_seen', { p_badge_keys: keys });
}

export type SetFeaturedOutcome = 'ok' | 'too_many' | 'not_owned' | 'duplicate';

export async function setFeaturedBadges(keys: string[]): Promise<SetFeaturedOutcome> {
  const result = await callRpc<{ outcome: SetFeaturedOutcome }>('set_featured_badges', {
    p_badge_keys: keys,
  });
  return result.outcome;
}

// For the Supporter countdown. 0 = sold out.
export async function fetchSupporterSpotsRemaining(): Promise<number> {
  return (await callRpc<number | null>('supporter_spots_remaining')) ?? 0;
}

// Admin only (the server refuses everyone else). A test toggle until in-app
// purchase exists; the Supporter badge stays even when turned off.
export type LifetimePremiumStatus = { lifetime_premium: boolean; supporter_number: number | null };

export async function adminGetLifetimePremium(userId: string): Promise<LifetimePremiumStatus | null> {
  return callRpc<LifetimePremiumStatus | null>('admin_get_lifetime_premium', { p_user_id: userId });
}

export type SetLifetimeOutcome = 'granted' | 'already' | 'sold_out' | 'not_found' | 'removed';

export async function adminSetLifetimePremium(
  userId: string,
  on: boolean,
): Promise<{ outcome: SetLifetimeOutcome; number?: number }> {
  return callRpc('admin_set_lifetime_premium', { p_user_id: userId, p_on: on });
}

export function formatEarnedDate(iso: string) {
  return new Date(iso).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  });
}
