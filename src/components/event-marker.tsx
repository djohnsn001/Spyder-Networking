import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Circle, Marker } from 'react-native-maps';

import { AccentColor } from '@/constants/theme';
import { EVENT_CIRCLE_RADIUS_M, hasExactLocation } from '@/lib/events';
import type { EventSummary } from '@/lib/types';

const TILE_WIDTH = 42;
const CREAM = '#fdfbf7';
const INK = '#2a211c';
// AccentColor (#83655d) at low opacity: a soft "somewhere in here" area.
const CIRCLE_FILL = 'rgba(131, 101, 93, 0.16)';
const CIRCLE_STROKE = 'rgba(131, 101, 93, 0.55)';

// Custom marker views are re-rendered into a bitmap on every frame while
// tracksViewChanges is on (noticeably costly on Android with many pins).
// These tiles never change after first paint, so turn tracking off once
// they've had a moment to render. The map keys each marker by id +
// starts_at + status + exact/approx (eventMarkerKey), so an edited event,
// or one whose look changes, remounts and gets re-tracked.
function useStopTrackingAfterFirstPaint() {
  const [tracksViewChanges, setTracksViewChanges] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => setTracksViewChanges(false), 500);
    return () => clearTimeout(timer);
  }, []);
  return tracksViewChanges;
}

export function eventMarkerKey(event: EventSummary) {
  return `${event.id}-${event.starts_at}-${event.status}-${hasExactLocation(event) ? 'exact' : 'approx'}`;
}

// The calendar tile: square-ish (people are circles) and showing the date,
// so you can scan the map for "what's this week".
function CalendarTile({ startsAt }: { startsAt: string }) {
  const start = new Date(startsAt);
  const month = start.toLocaleDateString(undefined, { month: 'short' }).toUpperCase();
  return (
    <View style={styles.tile}>
      <View style={styles.tileHeader}>
        <Text style={styles.monthText}>{month}</Text>
      </View>
      <Text style={styles.dayText}>{start.getDate()}</Text>
    </View>
  );
}

// Two looks, depending on what the viewer is allowed to know:
// - Exact (you're the host, going, or an admin): the tile with a pointer
//   tail, anchored at the tail's tip on the real spot.
// - Approximate (everyone else): a 400 m circle around the fuzzed point with
//   the tile centered in it and no tail, so it doesn't read as a pin. The
//   real spot is always somewhere inside the circle.
// Hosts also see their own hidden/removed events, faded, so they can tap
// through to see why.
export function EventMarker({ event, onPress }: { event: EventSummary; onPress: () => void }) {
  const tracksViewChanges = useStopTrackingAfterFirstPaint();
  const faded = event.status !== 'active';
  const label = `Event: ${event.title}`;

  if (hasExactLocation(event)) {
    return (
      <Marker
        coordinate={{ latitude: event.exact_latitude, longitude: event.exact_longitude }}
        anchor={{ x: 0.5, y: 1 }}
        zIndex={10}
        tracksViewChanges={tracksViewChanges}
        onPress={onPress}
        accessibilityLabel={label}>
        <View style={[styles.wrapper, faded && styles.faded]}>
          <CalendarTile startsAt={event.starts_at} />
          <View style={styles.tail} />
        </View>
      </Marker>
    );
  }

  const center = { latitude: event.approx_latitude, longitude: event.approx_longitude };
  return (
    <>
      <Circle
        center={center}
        radius={EVENT_CIRCLE_RADIUS_M}
        fillColor={CIRCLE_FILL}
        strokeColor={CIRCLE_STROKE}
        strokeWidth={1}
        zIndex={5}
      />
      <Marker
        coordinate={center}
        anchor={{ x: 0.5, y: 0.5 }}
        zIndex={10}
        tracksViewChanges={tracksViewChanges}
        onPress={onPress}
        accessibilityLabel={`${label}, approximate area`}>
        <View style={[styles.wrapper, faded && styles.faded]}>
          <CalendarTile startsAt={event.starts_at} />
        </View>
      </Marker>
    </>
  );
}

// The temporary pin shown while the Create event sheet is open.
export function DraftEventMarker({ coordinate }: { coordinate: { latitude: number; longitude: number } }) {
  const tracksViewChanges = useStopTrackingAfterFirstPaint();

  return (
    <Marker
      coordinate={coordinate}
      anchor={{ x: 0.5, y: 1 }}
      zIndex={11}
      tracksViewChanges={tracksViewChanges}
      accessibilityLabel="New event location">
      <View style={styles.wrapper}>
        <View style={[styles.tile, styles.draftTile]}>
          <Text style={styles.draftPlus}>+</Text>
        </View>
        <View style={styles.tail} />
      </View>
    </Marker>
  );
}

const styles = StyleSheet.create({
  wrapper: {
    alignItems: 'center',
  },
  faded: {
    opacity: 0.5,
  },
  tile: {
    width: TILE_WIDTH,
    borderRadius: 8,
    overflow: 'hidden',
    backgroundColor: CREAM,
    borderWidth: 2,
    borderColor: AccentColor,
    alignItems: 'center',
  },
  tileHeader: {
    alignSelf: 'stretch',
    backgroundColor: AccentColor,
    paddingVertical: 1,
    alignItems: 'center',
  },
  monthText: {
    color: CREAM,
    fontSize: 10,
    lineHeight: 13,
    fontWeight: '700',
    letterSpacing: 0.5,
  },
  dayText: {
    color: INK,
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '700',
  },
  draftTile: {
    height: 38,
    justifyContent: 'center',
    backgroundColor: AccentColor,
    borderColor: CREAM,
  },
  draftPlus: {
    color: CREAM,
    fontSize: 24,
    lineHeight: 28,
    fontWeight: '700',
  },
  // A small downward triangle drawn with borders.
  tail: {
    width: 0,
    height: 0,
    marginTop: -1,
    borderLeftWidth: 7,
    borderRightWidth: 7,
    borderTopWidth: 9,
    borderLeftColor: 'transparent',
    borderRightColor: 'transparent',
    borderTopColor: AccentColor,
  },
});
