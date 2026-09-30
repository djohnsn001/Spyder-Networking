import type { ConnectFix } from '@/lib/connect/api';
import { callRpc } from '@/lib/rpc';

// Event check-in by QR (migration 20260930030000). The host shows a code
// that rotates every 25 s (the server keeps each one 30 s); attendees scan
// it near the event's real spot. One check-in per person per event.

const TOKEN_PATTERN = /^[0-9a-f]{32}$/;
const URL_PATTERN = /^bolas:\/\/checkin\/([0-9a-fA-F]{32})\/?$/;

export const CHECKIN_ROTATE_MS = 25_000;

export function checkinUrlFor(token: string) {
  return `bolas://checkin/${token}`;
}

export function isCheckinToken(value: string) {
  return TOKEN_PATTERN.test(value);
}

// The token from a scanned check-in code, or null if it isn't one.
export function parseCheckinUrl(value: string): string | null {
  const match = URL_PATTERN.exec(value.trim());
  return match ? match[1].toLowerCase() : null;
}

export type CheckinInfo = {
  is_host: boolean;
  opens_at: string;
  closes_at: string;
  is_open: boolean;
  checked_in: boolean;
  // Host only.
  checkin_count: number | null;
  counts_as_hosted: boolean | null;
};

// Null for an event I can't see.
export async function fetchCheckinInfo(eventId: string): Promise<CheckinInfo | null> {
  return (await callRpc<CheckinInfo | null>('get_event_checkin_info', { p_event_id: eventId })) ?? null;
}

export type CheckinTokenResult =
  | { outcome: 'ok'; token: string; expires_at: string; closes_at: string; checkin_count: number }
  | { outcome: 'not_open'; opens_at: string }
  | { outcome: 'ended' | 'not_found' };

export async function createCheckinToken(eventId: string): Promise<CheckinTokenResult> {
  return callRpc<CheckinTokenResult>('create_event_checkin_token', { p_event_id: eventId });
}

export type CheckinOutcome =
  | 'checked_in'
  | 'already_checked_in'
  | 'invalid'
  | 'expired'
  | 'closed'
  | 'host'
  | 'unavailable'
  | 'location_required'
  | 'poor_location'
  | 'too_far';

export type CheckinResult = { outcome: CheckinOutcome; event_id?: string; event_title?: string };

export async function redeemCheckin(token: string, fix: ConnectFix | null): Promise<CheckinResult> {
  return callRpc<CheckinResult>('redeem_event_checkin', {
    p_token: token,
    p_lat: fix?.latitude ?? null,
    p_lng: fix?.longitude ?? null,
    p_accuracy_m: fix?.accuracy ?? null,
  });
}

export const CHECKIN_MESSAGE: Record<Exclude<CheckinOutcome, 'checked_in' | 'already_checked_in'>, string> = {
  invalid: "That's not a check-in code for an event you can join.",
  expired: 'That code expired. Scan the fresh one on the host’s screen.',
  closed: 'Check-in is only open from 15 minutes before the event until it ends.',
  host: "You're the host, so you don't need to check in.",
  unavailable: "Your account can't check in to events right now.",
  location_required: 'Turn on location so we can confirm you’re at the event.',
  poor_location: "Your location isn't precise enough yet. Step outside or wait a moment.",
  too_far: 'You need to be at the event to check in.',
};
