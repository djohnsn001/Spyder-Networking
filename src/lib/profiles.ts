import { callRpc } from '@/lib/rpc';
import type { DiscoverProfile } from '@/lib/types';

// Column lists for profile reads, so screens only fetch what they show
// (security item M8). They must match the types in types.ts.
export const OWN_PROFILE_COLUMNS =
  'id, username, full_name, avatar_url, bio, interests, business_stage, city, notifications_enabled, location_sharing, created_at, updated_at';
export const PUBLIC_PROFILE_COLUMNS =
  'id, username, full_name, avatar_url, bio, interests, business_stage, city';
export const PROFILE_SUMMARY_COLUMNS = 'id, username, full_name, avatar_url';
export const CONNECTION_PROFILE_COLUMNS = 'id, username, full_name, avatar_url, city, business_stage';

// The server never returns more than 30 per page, whatever we ask for.
export const DISCOVER_PAGE_SIZE = 30;

// One page of Discover, newest profiles first. Pass the last row's cursor
// to get the next page; a page shorter than DISCOVER_PAGE_SIZE is the end.
// Throws RpcError (see friendlyRpcError). The server skips me, blocked (either way) and suspended people.
export async function fetchDiscoverPage(
  cursor: string | null,
  search: string,
): Promise<DiscoverProfile[]> {
  const rows = await callRpc<DiscoverProfile[] | null>('discover_profiles', {
    p_cursor: cursor,
    p_limit: DISCOVER_PAGE_SIZE,
    p_search: search.trim() || null,
  });
  return rows ?? [];
}
