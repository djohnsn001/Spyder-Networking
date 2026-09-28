import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { Marker } from 'react-native-maps';

import { AccentColor } from '@/constants/theme';
import { hasExactLocation } from '@/lib/events';
import type { EventSummary } from '@/lib/types';

const TILE_WIDTH = 42;
const CREAM = '#fdfbf7';
const INK = '#2a211c';

// Custom marker views are re-rendered into a bitmap on every frame while
// tracksViewChanges is on (noticeably costly on Android with many pins).
// These tiles never change after first paint, so turn tracking off once
// they've had a moment to render. The map keys each marker by id +
// starts_at, so an edited event remounts and gets re-tracked.
function useStopTrackingAfterFirstPaint() {
  const [tracksViewChanges, setTracksViewChanges] = useState(true);
  useEffect(() => {
    const timer = setTimeout(() => setTracksViewChanges(false), 500);
    return () => clearTimeout(timer);
  }, []);
  return tracksViewChanges;
}

// A calendar tile with a pointer tail: square-ish (people are circles),
// anchored at the tail's tip (people float centered over an area), and
// showing the date so you can scan the map for "what's this week".
export function EventMarker({ event, onPress }: { event: EventSummary; onPress: () => void }) {
  const tracksViewChanges = useStopTrackingAfterFirstPaint();
  const start = new Date(event.starts_at);
  const month = start.toLocaleDateString(undefined, { month: 'short' }).toUpperCase();
  const day = start.getDate();

  return (
    <Marker
      coordinate={
        hasExactLocation(event)
          ? { latitude: event.exact_latitude, longitude: event.exact_longitude }
          : { latitude: event.approx_latitude, longitude: event.approx_longitude }
      }
      anchor={{ x: 0.5, y: 1 }}
      zIndex={10}
      tracksViewChanges={tracksViewChanges}
      onPress={onPress}
      accessibilityLabel={`Event: ${event.title}`}>
      <View style={styles.wrapper}>
        <View style={styles.tile}>
          <View style={styles.tileHeader}>
            <Text style={styles.monthText}>{month}</Text>
          </View>
          <Text style={styles.dayText}>{day}</Text>
        </View>
        <View style={styles.tail} />
      </View>
    </Marker>
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
