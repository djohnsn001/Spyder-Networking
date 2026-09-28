import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Circle, Marker } from 'react-native-maps';

import { BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { EVENT_CIRCLE_RADIUS_M, hasExactLocation } from '@/lib/events';
import type { EventSummary } from '@/lib/types';

const TILE_WIDTH = 44;
const MONTH_FONT_SIZE = 12;
const MONTH_LINE_HEIGHT = 16;

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
// so you can scan the map for "what's this week". Faded tiles (a host's
// hidden/removed event) swap the accent for a muted tone instead of going
// see-through, so the date stays readable.
function CalendarTile({ startsAt, faded }: { startsAt: string; faded: boolean }) {
  const theme = useTheme();
  const frameColor = faded ? theme.markerMuted : theme.accent;
  const start = new Date(startsAt);
  const month = start.toLocaleDateString(undefined, { month: 'short' }).toUpperCase();
  return (
    <View
      style={[styles.tile, { backgroundColor: theme.markerSurface, borderColor: frameColor }]}>
      <View style={[styles.tileHeader, { backgroundColor: frameColor }]}>
        <Text
          numberOfLines={1}
          style={[styles.monthText, { color: faded ? theme.onMarkerMuted : theme.onAccent }]}>
          {month}
        </Text>
      </View>
      <Text style={[styles.dayText, { color: theme.markerInk }]}>{start.getDate()}</Text>
    </View>
  );
}

// Two looks, depending on what the viewer is allowed to know:
// - Exact (you're the host, going, or an admin): the tile with a pointer
//   tail, anchored at the tail's tip on the real spot.
// - Approximate (everyone else): a 400 m circle around the fuzzed point with
//   the tile centered in it and no tail, so it doesn't read as a pin. The
//   real spot is always somewhere inside the circle.
// Hosts also see their own hidden/removed events, in a muted tone, so they
// can tap through to see why.
export function EventMarker({ event, onPress }: { event: EventSummary; onPress: () => void }) {
  const theme = useTheme();
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
        <View style={styles.wrapper}>
          <CalendarTile startsAt={event.starts_at} faded={faded} />
          <View
            style={[
              styles.tail,
              { borderTopColor: faded ? theme.markerMuted : theme.accent },
            ]}
          />
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
        fillColor={theme.eventAreaFill}
        strokeColor={theme.eventAreaStroke}
        strokeWidth={BorderWidth.thin}
        zIndex={5}
      />
      <Marker
        coordinate={center}
        anchor={{ x: 0.5, y: 0.5 }}
        zIndex={10}
        tracksViewChanges={tracksViewChanges}
        onPress={onPress}
        accessibilityLabel={`${label}, approximate area`}>
        <View style={styles.wrapper}>
          <CalendarTile startsAt={event.starts_at} faded={faded} />
        </View>
      </Marker>
    </>
  );
}

// The temporary pin shown while the Create event sheet is open.
export function DraftEventMarker({ coordinate }: { coordinate: { latitude: number; longitude: number } }) {
  const theme = useTheme();
  const tracksViewChanges = useStopTrackingAfterFirstPaint();

  return (
    <Marker
      coordinate={coordinate}
      anchor={{ x: 0.5, y: 1 }}
      zIndex={11}
      tracksViewChanges={tracksViewChanges}
      accessibilityLabel="New event location">
      <View style={styles.wrapper}>
        <View
          style={[
            styles.tile,
            styles.draftTile,
            { backgroundColor: theme.accent, borderColor: theme.markerOutline },
          ]}>
          <Text style={[styles.draftPlus, { color: theme.onAccent }]}>+</Text>
        </View>
        <View style={[styles.tail, { borderTopColor: theme.accent }]} />
      </View>
    </Marker>
  );
}

const styles = StyleSheet.create({
  wrapper: {
    alignItems: 'center',
  },
  tile: {
    width: TILE_WIDTH,
    borderRadius: Spacing.two,
    overflow: 'hidden',
    borderWidth: BorderWidth.thick,
    alignItems: 'center',
  },
  tileHeader: {
    alignSelf: 'stretch',
    paddingVertical: Spacing.half,
    alignItems: 'center',
  },
  monthText: {
    fontSize: MONTH_FONT_SIZE,
    lineHeight: MONTH_LINE_HEIGHT,
    fontWeight: '800',
    letterSpacing: 0.5,
  },
  dayText: {
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '700',
  },
  draftTile: {
    height: 38,
    justifyContent: 'center',
  },
  draftPlus: {
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
  },
});
