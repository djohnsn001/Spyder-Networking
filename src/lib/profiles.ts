import type { LookingForTag } from '@/lib/looking-for';
import { callRpc } from '@/lib/rpc';
import type { BusinessStage, DiscoverProfile } from '@/lib/types';

// Column lists for profile reads, so screens only fetch what they show
// (security item M8). They must match the types in types.ts.
// OWN_PROFILE_COLUMNS is only used on get_my_profile(), so it can include
// columns other people can't read (settings, tags, premium, member number).
export const OWN_PROFILE_COLUMNS =
  'id, username, full_name, avatar_url, bio, interests, business_stage, city, notifications_enabled, location_sharing, looking_for, tags_updated_at, is_premium, profile_completed_at, member_number, lifetime_premium, created_at, updated_at';
export const PUBLIC_PROFILE_COLUMNS =
  'id, username, full_name, avatar_url, bio, interests, business_stage, city';
export const PROFILE_SUMMARY_COLUMNS = 'id, username, full_name, avatar_url';
export const CONNECTION_PROFILE_COLUMNS = 'id, username, full_name, avatar_url, city, business_stage';

// The server never returns more than 30 per page, whatever we ask for.
export const DISCOVER_PAGE_SIZE = 30;

// Discover filters. Empty means "no filter". Interests and Looking For tags
// match anyone with at least one of them; city is a case-insensitive
// "contains". lookingFor is Premium-only: the server refuses it otherwise.
export type DiscoverFilters = {
  stages: BusinessStage[];
  interests: string[];
  city: string;
  lookingFor: LookingForTag[];
};

export const EMPTY_DISCOVER_FILTERS: DiscoverFilters = {
  stages: [],
  interests: [],
  city: '',
  lookingFor: [],
};

export function countActiveFilters(filters: DiscoverFilters) {
  return (
    filters.stages.length +
    filters.interests.length +
    filters.lookingFor.length +
    (filters.city.trim() ? 1 : 0)
  );
}

// One page of Discover, newest profiles first. Pass the last row's cursor
// to get the next page; a page shorter than DISCOVER_PAGE_SIZE is the end.
// Throws RpcError (see friendlyRpcError). The server skips me, blocked (either way) and suspended people.
export async function fetchDiscoverPage(
  cursor: string | null,
  search: string,
  filters: DiscoverFilters = EMPTY_DISCOVER_FILTERS,
): Promise<DiscoverProfile[]> {
  const rows = await callRpc<DiscoverProfile[] | null>('discover_profiles', {
    p_cursor: cursor,
    p_limit: DISCOVER_PAGE_SIZE,
    p_search: search.trim() || null,
    p_stages: filters.stages.length > 0 ? filters.stages : null,
    p_interests: filters.interests.length > 0 ? filters.interests : null,
    p_city: filters.city.trim() || null,
    p_looking_for: filters.lookingFor.length > 0 ? filters.lookingFor : null,
  });
  return rows ?? [];
}
