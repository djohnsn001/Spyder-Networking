import { callRpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';
import type { EventAttendee, EventStatus, EventSummary, EventVisibility } from '@/lib/types';

// Kept in sync with _event_rules() and _event_invalid_field() in the
// event_trust migration. The form checks these for fast feedback; the
// server (create_event / update_event) is the real guard.
export const EVENT_TITLE_LIMIT = 60;
export const EVENT_DESCRIPTION_LIMIT = 500;
export const EVENT_LOCATION_NAME_LIMIT = 100;
export const EVENT_MAX_DAYS_AHEAD = 90;
export const EVENT_MAX_DURATION_HOURS = 24;
// _event_rules().circle_radius_m. The fuzzed point is at most 350 m from the
// real spot, so a 400 m circle always contains it.
export const EVENT_CIRCLE_RADIUS_M = 400;

// Zoomed all the way out the visible region could cover a whole country;
// capping keeps one fetch from pulling every event in the database.
const MAX_EVENTS_PER_FETCH = 200;

// Fetch a bit beyond the visible edges so small pans don't pop pins in
// and out while the next fetch is in flight.
const REGION_PADDING = 0.25;

type MapRegion = {
  latitude: number;
  longitude: number;
  latitudeDelta: number;
  longitudeDelta: number;
};

export type EventInput = {
  title: string;
  description: string;
  locationName: string;
  startsAt: Date;
  endsAt: Date | null;
  visibility: EventVisibility;
};

export type EventInputField = 'title' | 'description' | 'locationName' | 'startsAt' | 'endsAt';
export type EventInputErrors = Partial<Record<EventInputField, string>>;

const DAY_MS = 24 * 60 * 60 * 1000;
const HOUR_MS = 60 * 60 * 1000;

// Shared by the create and edit forms. requireFutureStart is only on for
// creating — editing an event that's already underway shouldn't be blocked
// just because its start time has passed.
export function validateEventInput(
  input: EventInput,
  { requireFutureStart }: { requireFutureStart: boolean },
): EventInputErrors {
  const errors: EventInputErrors = {};
  const title = input.title.trim();

  if (title.length === 0) {
    errors.title = 'Give your event a title.';
  } else if (title.length > EVENT_TITLE_LIMIT) {
    errors.title = `Title must be ${EVENT_TITLE_LIMIT} characters or fewer.`;
  }

  if (input.description.trim().length > EVENT_DESCRIPTION_LIMIT) {
    errors.description = `Description must be ${EVENT_DESCRIPTION_LIMIT} characters or fewer.`;
  }

  if (input.locationName.trim().length > EVENT_LOCATION_NAME_LIMIT) {
    errors.locationName = `Location name must be ${EVENT_LOCATION_NAME_LIMIT} characters or fewer.`;
  }

  // A minute of grace so "right now" picked in the form still counts.
  if (requireFutureStart && input.startsAt.getTime() < Date.now() - 60_000) {
    errors.startsAt = 'Start time must be in the future.';
  } else if (input.startsAt.getTime() > Date.now() + EVENT_MAX_DAYS_AHEAD * DAY_MS) {
    errors.startsAt = `Events can be at most ${EVENT_MAX_DAYS_AHEAD} days out.`;
  }

  if (input.endsAt && input.endsAt.getTime() <= input.startsAt.getTime()) {
    errors.endsAt = 'End time must be after the start time.';
  } else if (
    input.endsAt &&
    input.endsAt.getTime() - input.startsAt.getTime() > EVENT_MAX_DURATION_HOURS * HOUR_MS
  ) {
    errors.endsAt = `Events can last at most ${EVENT_MAX_DURATION_HOURS} hours.`;
  }

  return errors;
}

// ---------------------------------------------------------------------------
// Hosting status
// ---------------------------------------------------------------------------

export type HostingLockReason = 'suspended' | 'no_profile' | 'new_account' | 'needs_in_person';

export type HostingStatus = {
  canHost: boolean;
  canHostPublic: boolean;
  reason: HostingLockReason | null;
  accountAgeDays: number;
  inPersonCount: number;
  neededInPerson: number;
  neededAgeDays: number;
  activeEvents: number;
  maxActiveEvents: number;
  isAdmin: boolean;
};

function toHostingStatus(raw: Record<string, any>): HostingStatus {
  return {
    canHost: raw.can_host === true,
    canHostPublic: raw.can_host_public === true,
    reason: raw.reason ?? null,
    accountAgeDays: raw.account_age_days ?? 0,
    inPersonCount: raw.in_person_count ?? 0,
    neededInPerson: raw.needed_in_person ?? 3,
    neededAgeDays: raw.needed_age_days ?? 7,
    activeEvents: raw.active_events ?? 0,
    maxActiveEvents: raw.max_active_events ?? 3,
    isAdmin: raw.is_admin === true,
  };
}

export async function getMyHostingStatus(): Promise<HostingStatus> {
  return toHostingStatus(await callRpc('get_my_hosting_status'));
}

// "🔒 Public events unlock when your account is 7 days old (2 days to go)
// and you've met 3 people in person (1/3)." Null once public is unlocked.
export function publicLockHint(status: HostingStatus): string | null {
  if (status.canHostPublic) return null;
  const parts: string[] = [];
  const daysLeft = Math.max(status.neededAgeDays - status.accountAgeDays, 0);
  if (daysLeft > 0) {
    parts.push(
      `your account is ${status.neededAgeDays} days old (${daysLeft} ${daysLeft === 1 ? 'day' : 'days'} to go)`,
    );
  }
  if (status.inPersonCount < status.neededInPerson) {
    parts.push(
      `you've met ${status.neededInPerson} people in person (${status.inPersonCount}/${status.neededInPerson})`,
    );
  }
  if (parts.length === 0) return '🔒 Public events are locked on your account.';
  return `🔒 Public events unlock when ${parts.join(' and ')}.`;
}

// ---------------------------------------------------------------------------
// Create / update (RPC only — clients can't write to events directly)
// ---------------------------------------------------------------------------

export type SaveEventResult =
  | { kind: 'saved' }
  | { kind: 'invalid'; field: EventInputField | 'location' | 'visibility' }
  | { kind: 'public_locked'; hosting: HostingStatus }
  | { kind: 'not_allowed'; reason: HostingLockReason | null }
  | { kind: 'too_many_active'; limit: number }
  | { kind: 'rate_limited' | 'blocked_content' | 'not_found' | 'event_removed' };

const SERVER_FIELD: Record<string, EventInputField | 'location' | 'visibility'> = {
  title: 'title',
  description: 'description',
  location_name: 'locationName',
  starts_at: 'startsAt',
  ends_at: 'endsAt',
  location: 'location',
  visibility: 'visibility',
};

function toSaveResult(raw: Record<string, any>): SaveEventResult {
  switch (raw?.outcome) {
    case 'created':
    case 'updated':
      return { kind: 'saved' };
    case 'invalid':
      return { kind: 'invalid', field: SERVER_FIELD[raw.field] ?? 'title' };
    case 'public_locked':
      return { kind: 'public_locked', hosting: toHostingStatus(raw) };
    case 'not_allowed':
      return { kind: 'not_allowed', reason: raw.reason ?? null };
    case 'too_many_active':
      return { kind: 'too_many_active', limit: raw.limit ?? 3 };
    case 'rate_limited':
    case 'blocked_content':
    case 'not_found':
    case 'event_removed':
      return { kind: raw.outcome };
    default:
      throw new Error(`Unexpected event save outcome: ${JSON.stringify(raw)}`);
  }
}

// The one place user-facing copy for a failed save lives.
export function saveEventErrorMessage(result: Exclude<SaveEventResult, { kind: 'saved' }>): string {
  switch (result.kind) {
    case 'public_locked':
      return (
        publicLockHint(result.hosting) ??
        `Public events unlock after you've met ${result.hosting.neededInPerson} people in person.`
      );
    case 'too_many_active':
      return `You can have up to ${result.limit} upcoming events.`;
    case 'blocked_content':
      return "Something in your title or description isn't allowed. Selling and money-making pitches aren't allowed.";
    case 'rate_limited':
      return 'Slow down a sec and try again later.';
    case 'not_allowed':
      return result.reason === 'suspended'
        ? 'Hosting is paused on your account.'
        : 'Finish setting up your profile before hosting events.';
    case 'not_found':
      return 'This event no longer exists.';
    case 'event_removed':
      return "This event was removed, so it can't be edited.";
    case 'invalid':
      switch (result.field) {
        case 'startsAt':
          return `Pick a start time in the future, at most ${EVENT_MAX_DAYS_AHEAD} days out.`;
        case 'endsAt':
          return `End time must be after the start, and at most ${EVENT_MAX_DURATION_HOURS} hours later.`;
        case 'location':
          return 'That spot looks off. Close this and drop the pin again.';
        default:
          return 'Check the highlighted field and try again.';
      }
  }
}

export async function createEvent(
  location: { latitude: number; longitude: number },
  input: EventInput,
): Promise<SaveEventResult> {
  const raw = await callRpc('create_event', {
    p_title: input.title.trim(),
    p_description: input.description.trim() || null,
    p_location_name: input.locationName.trim() || null,
    p_latitude: location.latitude,
    p_longitude: location.longitude,
    p_starts_at: input.startsAt.toISOString(),
    p_ends_at: input.endsAt ? input.endsAt.toISOString() : null,
    p_visibility: input.visibility,
  });
  return toSaveResult(raw);
}

// The location (pin and place name) can never change after creating — to
// move an event, delete it and drop a new pin. input.locationName is ignored.
export async function updateEvent(eventId: string, input: EventInput): Promise<SaveEventResult> {
  const raw = await callRpc('update_event', {
    p_event_id: eventId,
    p_title: input.title.trim(),
    p_description: input.description.trim() || null,
    p_starts_at: input.startsAt.toISOString(),
    p_ends_at: input.endsAt ? input.endsAt.toISOString() : null,
    p_visibility: input.visibility,
  });
  return toSaveResult(raw);
}

// ---------------------------------------------------------------------------
// Reading events
// ---------------------------------------------------------------------------

// Upcoming (not yet ended) events inside the visible map region, by their
// approximate spot. RLS decides which ones come back — connections-only
// events from people you're not connected to, and hidden/removed events
// (unless they're yours), are simply never returned.
export async function fetchEventsInRegion(region: MapRegion): Promise<EventSummary[]> {
  const latPad = (region.latitudeDelta * (1 + REGION_PADDING)) / 2;
  const lngPad = (region.longitudeDelta * (1 + REGION_PADDING)) / 2;

  const { data, error } = await supabase
    .from('event_summaries')
    .select('*')
    .gte('approx_latitude', Math.max(region.latitude - latPad, -90))
    .lte('approx_latitude', Math.min(region.latitude + latPad, 90))
    .gte('approx_longitude', Math.max(region.longitude - lngPad, -180))
    .lte('approx_longitude', Math.min(region.longitude + lngPad, 180))
    .gt('effective_ends_at', new Date().toISOString())
    .order('starts_at', { ascending: true })
    .limit(MAX_EVENTS_PER_FETCH);
  if (error) throw error;
  return data ?? [];
}

// null when the event doesn't exist or the caller isn't allowed to see it
// (RLS makes those look the same, on purpose).
export async function fetchEvent(eventId: string): Promise<EventSummary | null> {
  const { data, error } = await supabase
    .from('event_summaries')
    .select('*')
    .eq('id', eventId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// True when the caller may see the exact spot (host, going, or admin).
export function hasExactLocation(
  event: EventSummary,
): event is EventSummary & { exact_latitude: number; exact_longitude: number } {
  return event.exact_latitude != null && event.exact_longitude != null;
}

// The host sees everyone; others see themselves plus their connections.
export async function getEventAttendees(eventId: string): Promise<EventAttendee[]> {
  return (await callRpc<EventAttendee[]>('get_event_attendees', { p_event_id: eventId })) ?? [];
}

// ---------------------------------------------------------------------------
// Delete / RSVP
// ---------------------------------------------------------------------------

// Hosts can only delete an active event; one under review or removed stays
// until an admin deals with it (the delete just matches no rows).
export async function deleteEvent(eventId: string) {
  const { error } = await supabase.from('events').delete().eq('id', eventId);
  if (error) throw error;
}

// 'unavailable' = the event ended, or was hidden/removed, since it loaded.
export type SetGoingResult = 'ok' | 'rate_limited' | 'unavailable';

export async function setGoing(
  eventId: string,
  userId: string,
  going: boolean,
): Promise<SetGoingResult> {
  if (going) {
    // upsert so double-tapping "Going" can't fail on the unique key.
    const { error } = await supabase
      .from('event_attendees')
      .upsert({ event_id: eventId, user_id: userId }, { ignoreDuplicates: true });
    if (error) {
      if (error.message?.includes('rsvp_rate_limited')) return 'rate_limited';
      // 42501 = the RSVP policy said no.
      if (error.code === '42501') return 'unavailable';
      throw error;
    }
  } else {
    const { error } = await supabase
      .from('event_attendees')
      .delete()
      .eq('event_id', eventId)
      .eq('user_id', userId);
    if (error) throw error;
  }
  return 'ok';
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

export type ReportReason =
  | 'spam'
  | 'selling_or_scam'
  | 'unsafe_location'
  | 'harassment'
  | 'inappropriate'
  | 'fake'
  | 'other';

export const REPORT_REASONS: { value: ReportReason; label: string }[] = [
  { value: 'spam', label: 'Spam' },
  { value: 'selling_or_scam', label: 'Selling or a scam' },
  { value: 'unsafe_location', label: 'Unsafe or private location' },
  { value: 'harassment', label: 'Harassment or hate' },
  { value: 'inappropriate', label: 'Inappropriate' },
  { value: 'fake', label: "Fake or not a real event" },
  { value: 'other', label: 'Something else' },
];

export const REPORT_DETAILS_LIMIT = 500;

export type ReportResult = 'reported' | 'already_reported' | 'rate_limited' | 'unavailable';

// 'reported' and 'already_reported' both get "Thanks, we'll take a look":
// the reporter is never told whether their report hid the event.
export async function reportEvent(
  eventId: string,
  reason: ReportReason,
  details: string,
): Promise<ReportResult> {
  const raw = await callRpc('report_event', {
    p_event_id: eventId,
    p_reason: reason,
    p_details: details.trim() || null,
  });
  switch (raw?.outcome) {
    case 'reported':
    case 'already_reported':
    case 'rate_limited':
      return raw.outcome;
    default:
      // self / not_found / invalid: nothing the reporter can fix.
      return 'unavailable';
  }
}

// ---------------------------------------------------------------------------
// Admin (every RPC refuses non-admins, and admins without a two-step code;
// the admin screen checks first via getMyAdminStatus in lib/mfa)
// ---------------------------------------------------------------------------

export type FlaggedReport = {
  reason: ReportReason;
  details: string | null;
  reporter_username: string | null;
  // False for reports from accounts too new to count toward auto-hide.
  counts: boolean;
  created_at: string;
};

export type FlaggedEvent = {
  event_id: string;
  title: string;
  description: string | null;
  status: EventStatus;
  visibility: EventVisibility;
  starts_at: string;
  ends_at: string | null;
  created_at: string;
  going_count: number;
  creator_id: string;
  creator_username: string | null;
  creator_full_name: string | null;
  host_status: 'approved' | 'suspended' | null;
  latitude: number | null;
  longitude: number | null;
  location_name: string | null;
  open_reports: number;
  counted_reports: number;
  reports_by_reason: Partial<Record<ReportReason, number>>;
  latest_report_at: string | null;
  recent_reports: FlaggedReport[];
};

export async function adminListFlaggedEvents(): Promise<FlaggedEvent[]> {
  return (await callRpc<FlaggedEvent[]>('admin_list_flagged_events')) ?? [];
}

export async function adminSetEventStatus(
  eventId: string,
  status: 'active' | 'removed',
  note?: string,
): Promise<void> {
  const raw = await callRpc('admin_set_event_status', {
    p_event_id: eventId,
    p_status: status,
    p_note: note?.trim() || null,
  });
  if (raw?.outcome !== 'updated') throw new Error(`admin_set_event_status: ${JSON.stringify(raw)}`);
}

export type AdminHostStatus = 'approved' | 'suspended' | null;

export async function adminSetHostStatus(
  userId: string,
  status: AdminHostStatus,
  note?: string,
): Promise<{ eventsRemoved: number }> {
  const raw = await callRpc('admin_set_host_status', {
    p_user_id: userId,
    p_status: status,
    p_note: note?.trim() || null,
  });
  if (raw?.outcome !== 'updated') throw new Error(`admin_set_host_status: ${JSON.stringify(raw)}`);
  return { eventsRemoved: raw.events_removed ?? 0 };
}

export type AdminUser = {
  userId: string;
  username: string | null;
  fullName: string | null;
  avatarUrl: string | null;
  hostStatus: AdminHostStatus;
  hostNote: string | null;
  hosting: HostingStatus;
};

export async function adminFindUser(username: string): Promise<AdminUser[]> {
  const rows = (await callRpc<Record<string, any>[]>('admin_find_user', { p_username: username })) ?? [];
  return rows.map((row) => ({
    userId: row.user_id,
    username: row.username,
    fullName: row.full_name,
    avatarUrl: row.avatar_url,
    hostStatus: row.host_status ?? null,
    hostNote: row.host_note ?? null,
    hosting: toHostingStatus(row.hosting ?? {}),
  }));
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

// "Sat, Oct 4 · 6:00 PM – 8:00 PM", dropping the second date when the
// event starts and ends on the same day.
export function formatEventTime(startsAt: string, endsAt: string | null): string {
  const start = new Date(startsAt);
  const day = start.toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
  const startTime = start.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (!endsAt) return `${day} · ${startTime}`;

  const end = new Date(endsAt);
  const endTime = end.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  if (end.toDateString() === start.toDateString()) {
    return `${day} · ${startTime} – ${endTime}`;
  }
  const endDay = end.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return `${day} · ${startTime} – ${endDay}, ${endTime}`;
}
