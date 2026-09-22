import { supabase } from '@/lib/supabase';
import type { EventSummary, EventVisibility } from '@/lib/types';

// Kept in sync with the check constraints in the create_events migration —
// these give friendly messages, the database is the real guard.
export const EVENT_TITLE_LIMIT = 60;
export const EVENT_DESCRIPTION_LIMIT = 500;
export const EVENT_LOCATION_NAME_LIMIT = 100;

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

export type EventInputErrors = Partial<
  Record<'title' | 'description' | 'locationName' | 'startsAt' | 'endsAt', string>
>;

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
  }

  if (input.endsAt && input.endsAt.getTime() <= input.startsAt.getTime()) {
    errors.endsAt = 'End time must be after the start time.';
  }

  return errors;
}

function toRow(input: EventInput) {
  return {
    title: input.title.trim(),
    description: input.description.trim() || null,
    location_name: input.locationName.trim() || null,
    starts_at: input.startsAt.toISOString(),
    ends_at: input.endsAt ? input.endsAt.toISOString() : null,
    visibility: input.visibility,
  };
}

// Upcoming (not yet ended) events inside the visible map region. RLS on
// events decides which ones come back — connections-only events from
// people you're not connected to are simply never returned.
export async function fetchEventsInRegion(region: MapRegion): Promise<EventSummary[]> {
  const latPad = (region.latitudeDelta * (1 + REGION_PADDING)) / 2;
  const lngPad = (region.longitudeDelta * (1 + REGION_PADDING)) / 2;

  const { data, error } = await supabase
    .from('event_summaries')
    .select('*')
    .gte('latitude', Math.max(region.latitude - latPad, -90))
    .lte('latitude', Math.min(region.latitude + latPad, 90))
    .gte('longitude', Math.max(region.longitude - lngPad, -180))
    .lte('longitude', Math.min(region.longitude + lngPad, 180))
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

// The creator's attendee row is added by a database trigger, not here.
export async function createEvent(
  creatorId: string,
  location: { latitude: number; longitude: number },
  input: EventInput,
): Promise<string> {
  const { data, error } = await supabase
    .from('events')
    .insert({
      ...toRow(input),
      creator_id: creatorId,
      latitude: location.latitude,
      longitude: location.longitude,
    })
    .select('id')
    .single();
  if (error) throw error;
  return data.id;
}

// Location is intentionally not editable in v1 — to move an event, delete
// it and drop a new pin.
export async function updateEvent(eventId: string, input: EventInput) {
  const { error } = await supabase.from('events').update(toRow(input)).eq('id', eventId);
  if (error) throw error;
}

export async function deleteEvent(eventId: string) {
  const { error } = await supabase.from('events').delete().eq('id', eventId);
  if (error) throw error;
}

export async function setGoing(eventId: string, userId: string, going: boolean) {
  if (going) {
    // upsert so double-tapping "Going" can't fail on the unique key.
    const { error } = await supabase
      .from('event_attendees')
      .upsert({ event_id: eventId, user_id: userId }, { ignoreDuplicates: true });
    if (error) throw error;
  } else {
    const { error } = await supabase
      .from('event_attendees')
      .delete()
      .eq('event_id', eventId)
      .eq('user_id', userId);
    if (error) throw error;
  }
}

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
