import { Linking, Platform, Pressable, StyleSheet, View } from 'react-native';
import MapView, { Circle, Marker } from 'react-native-maps';

import { ThemedText } from '@/components/themed-text';
import { AccentColor, Spacing } from '@/constants/theme';
import { EVENT_CIRCLE_RADIUS_M, hasExactLocation } from '@/lib/events';
import { DARK_MAP_STYLE, LIGHT_MAP_STYLE } from '@/lib/map-style';
import { useThemePreference } from '@/lib/theme-preference';
import type { EventSummary } from '@/lib/types';

// Fixed height: this lives in a fitToContents sheet, which has no height of
// its own for anything to flex into.
const MINI_MAP_HEIGHT = 140;
// Enough to show the whole 400 m circle with a margin (~1.2 km tall).
const MINI_MAP_DELTA = 0.011;

const CIRCLE_FILL = 'rgba(131, 101, 93, 0.16)';
const CIRCLE_STROKE = 'rgba(131, 101, 93, 0.55)';

// iOS opens Apple Maps, Android whatever handles geo: links (usually Google
// Maps). Falls back to Google Maps on the web if neither works.
async function openInMaps(latitude: number, longitude: number, label: string) {
  const query = encodeURIComponent(label);
  const url = Platform.select({
    ios: `https://maps.apple.com/?ll=${latitude},${longitude}&q=${query}`,
    default: `geo:${latitude},${longitude}?q=${latitude},${longitude}(${query})`,
  });
  try {
    await Linking.openURL(url);
  } catch {
    await Linking.openURL(
      `https://www.google.com/maps/search/?api=1&query=${latitude},${longitude}`,
    ).catch(() => {});
  }
}

// The detail sheet's location block.
// - Not going: the general area (the same circle as the map) and a nudge
//   that the exact spot unlocks on Going.
// - Going / host / admin: the place name, the exact pin, and Open in Maps.
export function EventLocation({ event }: { event: EventSummary }) {
  const { resolvedScheme } = useThemePreference();
  const exact = hasExactLocation(event);
  const center = exact
    ? { latitude: event.exact_latitude, longitude: event.exact_longitude }
    : { latitude: event.approx_latitude, longitude: event.approx_longitude };

  return (
    <View style={styles.container}>
      {exact ? (
        event.location_name ? (
          <ThemedText type="default">📍 {event.location_name}</ThemedText>
        ) : null
      ) : (
        <ThemedText type="small" themeColor="textSecondary">
          📍 Exact spot shows when you tap Going
        </ThemedText>
      )}

      {/* A picture, not a map to play with: all gestures off, and touches
          pass through so the sheet can still be dragged. */}
      <View style={styles.mapFrame} pointerEvents="none">
        <MapView
          // Remount when the center changes (e.g. after tapping Going) —
          // initialRegion is only read once.
          key={`${center.latitude},${center.longitude}`}
          style={styles.map}
          initialRegion={{ ...center, latitudeDelta: MINI_MAP_DELTA, longitudeDelta: MINI_MAP_DELTA }}
          scrollEnabled={false}
          zoomEnabled={false}
          pitchEnabled={false}
          rotateEnabled={false}
          toolbarEnabled={false}
          liteMode={Platform.OS === 'android'}
          userInterfaceStyle={resolvedScheme}
          mapType={Platform.OS === 'ios' ? 'mutedStandard' : 'standard'}
          customMapStyle={
            Platform.OS === 'android'
              ? resolvedScheme === 'dark'
                ? DARK_MAP_STYLE
                : LIGHT_MAP_STYLE
              : undefined
          }
          showsPointsOfInterests={false}
          accessibilityLabel={exact ? 'Map of the exact spot' : 'Map of the general area'}>
          {exact ? (
            <Marker coordinate={center} pinColor={AccentColor} />
          ) : (
            <Circle
              center={center}
              radius={EVENT_CIRCLE_RADIUS_M}
              fillColor={CIRCLE_FILL}
              strokeColor={CIRCLE_STROKE}
              strokeWidth={1}
            />
          )}
        </MapView>
      </View>

      {exact ? (
        <Pressable
          onPress={() =>
            openInMaps(center.latitude, center.longitude, event.location_name || event.title)
          }
          accessibilityRole="button"
          accessibilityLabel="Open in Maps"
          style={({ pressed }) => [styles.mapsButton, pressed && styles.pressed]}>
          <ThemedText type="smallBold" style={styles.mapsButtonLabel}>
            Open in Maps
          </ThemedText>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: Spacing.two,
  },
  mapFrame: {
    height: MINI_MAP_HEIGHT,
    borderRadius: Spacing.three,
    overflow: 'hidden',
  },
  map: {
    height: MINI_MAP_HEIGHT,
  },
  mapsButton: {
    alignSelf: 'flex-start',
    paddingVertical: Spacing.one,
  },
  mapsButtonLabel: {
    color: AccentColor,
  },
  pressed: {
    opacity: 0.7,
  },
});
