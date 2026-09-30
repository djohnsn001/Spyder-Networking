import { supabase } from '@/lib/supabase';

// Typed wrappers around the in-person connect RPCs (see the
// connection_levels / connect_tokens / bump_events migrations). The RPCs
// return loose JSON; everything here turns it into discriminated unions so
// screens can switch on `kind` instead of poking at strings.

const RPC_TIMEOUT_MS = 8000;

export type OtherProfile = {
  id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
};

export type InPersonMatch = {
  outcome: 'created' | 'upgraded' | 'already_connected';
  connectionId: string;
  metCity: string | null;
  undoUntil: string | null;
  other: OtherProfile;
};

// A phone's position for connecting in person. Both the code's owner and the
// scanner send one; the server only connects them if they're close
// (security item H2).
export type ConnectFix = { latitude: number; longitude: number; accuracy: number };

export type CreateTokenResult =
  | { kind: 'ok'; token: string; expiresAt: string }
  | { kind: 'rate_limited' | 'location_required' | 'poor_location' };

export type RedeemResult =
  | { kind: 'matched'; match: InPersonMatch }
  | {
      kind:
        | 'invalid'
        | 'used'
        | 'expired'
        | 'self'
        | 'too_far'
        | 'location_required'
        | 'poor_location';
    };

export type TokenStatus =
  | { kind: 'active' | 'expired' | 'not_found' }
  | { kind: 'used'; match: InPersonMatch | null };

export type BumpResult =
  | { kind: 'waiting'; bumpId: string }
  | { kind: 'matched'; bumpId: string; match: InPersonMatch }
  | { kind: 'ambiguous' | 'no_match' | 'not_found' | 'poor_location' | 'rate_limited' };

export type UndoResult = 'undone' | 'too_late' | 'not_found';

export type ConnectErrorKind = 'offline' | 'timeout' | 'unknown';

export class ConnectError extends Error {
  kind: ConnectErrorKind;
  constructor(kind: ConnectErrorKind, cause?: unknown) {
    super(kind);
    this.kind = kind;
    if (__DEV__ && cause) console.warn('[connect]', cause);
  }
}

// The one place user-facing error copy lives. Never show raw Supabase or
// Postgres text to users.
export function friendlyConnectError(error: unknown): string {
  if (error instanceof ConnectError) {
    if (error.kind === 'offline') {
      return "You're offline. Connecting in person needs internet on both phones.";
    }
    if (error.kind === 'timeout') return 'That took too long. Check your connection and try again.';
  }
  return 'Something went wrong. Try again.';
}

export const RATE_LIMITED_MESSAGE = 'Slow down a sec and try again.';

async function callRpc(name: string, args?: Record<string, unknown>): Promise<Record<string, any>> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS);
  try {
    const { data, error } = await supabase.rpc(name, args).abortSignal(controller.signal);
    if (error) {
      if (controller.signal.aborted) throw new ConnectError('timeout', error);
      if (/network request failed|failed to fetch|network error/i.test(error.message ?? '')) {
        throw new ConnectError('offline', error);
      }
      throw new ConnectError('unknown', error);
    }
    return (data ?? {}) as Record<string, any>;
  } catch (error) {
    if (error instanceof ConnectError) throw error;
    if (controller.signal.aborted) throw new ConnectError('timeout', error);
    throw new ConnectError('offline', error);
  } finally {
    clearTimeout(timer);
  }
}

function toMatch(raw: Record<string, any> | null | undefined): InPersonMatch | null {
  if (!raw?.connection_id || !raw.other_profile) return null;
  return {
    outcome: raw.outcome,
    connectionId: raw.connection_id,
    metCity: raw.met_city ?? null,
    undoUntil: raw.undo_until ?? null,
    other: raw.other_profile,
  };
}

export async function createConnectToken(fix: ConnectFix | null): Promise<CreateTokenResult> {
  const raw = await callRpc('create_connect_token', {
    p_lat: fix?.latitude ?? null,
    p_lng: fix?.longitude ?? null,
    p_accuracy_m: fix?.accuracy ?? null,
  });
  if (raw.outcome === 'ok') return { kind: 'ok', token: raw.token, expiresAt: raw.expires_at };
  if (raw.outcome === 'location_required' || raw.outcome === 'poor_location') {
    return { kind: raw.outcome };
  }
  return { kind: 'rate_limited' };
}

export async function getConnectTokenStatus(token: string): Promise<TokenStatus> {
  const raw = await callRpc('get_connect_token_status', { p_token: token });
  if (raw.status === 'used') return { kind: 'used', match: toMatch(raw.result) };
  if (raw.status === 'active' || raw.status === 'expired') return { kind: raw.status };
  return { kind: 'not_found' };
}

export async function redeemConnectToken(
  token: string,
  city: string | null,
  fix: ConnectFix | null,
): Promise<RedeemResult> {
  const raw = await callRpc('redeem_connect_token', {
    p_token: token,
    p_city: city,
    p_lat: fix?.latitude ?? null,
    p_lng: fix?.longitude ?? null,
    p_accuracy_m: fix?.accuracy ?? null,
  });
  const match = toMatch(raw);
  if (match) return { kind: 'matched', match };
  if (
    raw.outcome === 'used' ||
    raw.outcome === 'expired' ||
    raw.outcome === 'self' ||
    raw.outcome === 'too_far' ||
    raw.outcome === 'location_required' ||
    raw.outcome === 'poor_location'
  ) {
    return { kind: raw.outcome };
  }
  // 'invalid', and 'unavailable' (blocked / suspended): never say which.
  return { kind: 'invalid' };
}

// Friendly copy for the location outcomes, shared by My code, Scan, and the
// link screen.
export const LOCATION_MESSAGE = {
  too_far: "You need to be together to connect. Scan their code while you're with them.",
  location_required: 'Connecting needs your location, so Bolas knows you two are together.',
  poor_location: "Can't get a good location right now. Step outside or try Tap instead.",
} as const;

export async function submitBump(
  lat: number,
  lng: number,
  accuracyM: number,
  city: string | null,
): Promise<BumpResult> {
  const raw = await callRpc('submit_bump', {
    p_lat: lat,
    p_lng: lng,
    p_accuracy_m: accuracyM,
    p_city: city,
  });
  return toBumpResult(raw);
}

export async function getBumpResult(bumpId: string): Promise<BumpResult> {
  return toBumpResult(await callRpc('get_bump_result', { p_bump_id: bumpId }));
}

function toBumpResult(raw: Record<string, any>): BumpResult {
  if (raw.status === 'waiting') return { kind: 'waiting', bumpId: raw.bump_id };
  if (raw.status === 'matched') {
    const match = toMatch(raw);
    if (match) return { kind: 'matched', bumpId: raw.bump_id, match };
  }
  if (
    raw.status === 'ambiguous' ||
    raw.status === 'no_match' ||
    raw.status === 'poor_location' ||
    raw.status === 'rate_limited'
  ) {
    return { kind: raw.status };
  }
  return { kind: 'not_found' };
}

export async function undoInPersonConnection(connectionId: string): Promise<UndoResult> {
  const raw = await callRpc('undo_in_person_connection', { p_connection_id: connectionId });
  if (raw.outcome === 'undone' || raw.outcome === 'too_late') return raw.outcome;
  return 'not_found';
}
