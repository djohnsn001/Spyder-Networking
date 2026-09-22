import * as Location from 'expo-location';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Platform,
  Pressable,
  StyleSheet,
  View,
  useWindowDimensions,
} from 'react-native';
import MapView, { Marker, Polyline, type Region } from 'react-native-maps';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ClusterListModal } from '@/components/cluster-list-modal';
import { DraftEventMarker, EventMarker } from '@/components/event-marker';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { fetchEventsInRegion } from '@/lib/events';
import {
  AVATAR_HALO_SIZE,
  AVATAR_SIZE,
  clusterConnections,
  FAN_OUT_MAX_LONGITUDE_DELTA,
  fanOutClusters,
  fetchConnectionEdges,
  fetchConnectionLocations,
  GROUP_MARKER_SIZE,
  regionToClusterDistance,
  resolveBubbleOverlaps,
  updateMyLocation,
  type LocationCluster,
} from '@/lib/map';
import { useThemePreference } from '@/lib/theme-preference';
import type { ConnectionEdge, ConnectionLocation, EventSummary } from '@/lib/types';

const BOISE_REGION = {
  latitude: 43.615,
  longitude: -116.202,
  latitudeDelta: 0.1,
  longitudeDelta: 0.1,
};

// Fine white threads, so the web reads as a delicate layer over the map
// rather than heavy route lines. Your own spokes (you → a connection) are a
// touch thicker and outlined, so they stand out from the mutual lines
// between two of your connections.
const SPOKE_LINE_WIDTH = 2;
const MUTUAL_LINE_WIDTH = 1.75;
const WEB_LINE_COLOR = '#FFFFFF';
// Spokes sit on a slightly wider dark outline ("casing"), the same trick
// map apps use for routes — it keeps them readable on light maps too.
const SPOKE_CASING_WIDTH = SPOKE_LINE_WIDTH + 2;
const SPOKE_CASING_COLOR = 'rgba(20,14,11,0.55)';

// How long the map has to sit still after a pan/zoom before events for the
// new area are fetched, so a long swipe triggers one request, not dozens.
const EVENT_FETCH_DEBOUNCE_MS = 400;

const FAB_SIZE = 52;

type LatLng = { latitude: number; longitude: number };

// A solo person's marker: their avatar with a soft translucent halo, never
// a sharp exact-looking pin. Sits exactly on the area's centroid, so the
// web's lines land squarely on it.
function IndividualAvatarMarker({
  member,
  coordinate,
  onPress,
}: {
  member: ConnectionLocation;
  coordinate: LatLng;
  onPress: () => void;
}) {
  const displayName = member.full_name || member.username || '';
  const haloSize = AVATAR_HALO_SIZE;

  return (
    <Marker
      coordinate={coordinate}
      anchor={{ x: 0.5, y: 0.5 }}
      onPress={onPress}
      accessibilityLabel={`View ${displayName || 'this person'}'s profile, approximate area`}>
      <View
        style={[
          styles.halo,
          { width: haloSize, height: haloSize, borderRadius: haloSize / 2 },
        ]}>
        <Avatar uri={member.avatar_url} name={displayName} size={AVATAR_SIZE} />
      </View>
    </Marker>
  );
}

// An area with more than one person collapses to a single dot showing the
// count, sitting exactly on the centroid — fanning individual avatars out
// around it left the web's lines pointing at an empty spot between them.
// Tapping it opens the full list.
function GroupMarker({
  coordinate,
  count,
  onPress,
}: {
  coordinate: LatLng;
  count: number;
  onPress: () => void;
}) {
  return (
    <Marker
      coordinate={coordinate}
      anchor={{ x: 0.5, y: 0.5 }}
      onPress={onPress}
      accessibilityLabel={`${count} builders in this area`}>
      <View style={styles.groupMarker}>
        <ThemedText type="smallBold" style={styles.groupMarkerText}>
          {count}
        </ThemedText>
      </View>
    </Marker>
  );
}

type PermissionState = 'checking' | 'granted' | 'denied';
type WebState = 'idle' | 'loading' | 'loaded' | 'error';

export default function MapScreen() {
  const { session } = useAuth();
  const myId = session?.user.id;

  const [permissionState, setPermissionState] = useState<PermissionState>('checking');
  const [myPosition, setMyPosition] = useState<{ latitude: number; longitude: number } | null>(
    null,
  );
  const [webState, setWebState] = useState<WebState>('idle');
  const [connections, setConnections] = useState<ConnectionLocation[]>([]);
  const [edges, setEdges] = useState<ConnectionEdge[]>([]);
  const [selectedCluster, setSelectedCluster] = useState<LocationCluster | null>(null);
  const [longitudeDelta, setLongitudeDelta] = useState(BOISE_REGION.longitudeDelta);
  const lastRegionUpdateRef = useRef(0);
  const [events, setEvents] = useState<EventSummary[]>([]);
  const [draftPin, setDraftPin] = useState<LatLng | null>(null);
  // The latest settled region — used for the "+" button (map center) and
  // for refetching events when the tab regains focus.
  const regionRef = useRef<Region>(BOISE_REGION);
  const eventFetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const eventRequestIdRef = useRef(0);

  // Apple Maps can follow the app's own light/dark choice; Google Maps on
  // Android has no built-in dark style, so it's always light there.
  const { resolvedScheme } = useThemePreference();
  const insets = useSafeAreaInsets();
  const mapScheme = Platform.OS === 'ios' ? resolvedScheme : 'light';

  // Recluster continuously while the user pinches/pans, not just once they
  // let go — throttled so a fast gesture doesn't trigger dozens of
  // reclusters per second, but still frequent enough to feel live rather
  // than a single jump at the end.
  const handleRegionChange = useCallback((region: Region) => {
    const now = Date.now();
    if (now - lastRegionUpdateRef.current < 80) return;
    lastRegionUpdateRef.current = now;
    setLongitudeDelta(region.longitudeDelta);
  }, []);

  const loadEvents = useCallback(async (region: Region) => {
    // Tag each request so a slow earlier response can't overwrite a newer one.
    const requestId = ++eventRequestIdRef.current;
    try {
      const data = await fetchEventsInRegion(region);
      if (requestId === eventRequestIdRef.current) setEvents(data);
    } catch (error) {
      // Keep whatever pins are already showing; the next pan retries.
      console.error('Failed to load map events', error);
    }
  }, []);

  const handleRegionChangeComplete = useCallback(
    (region: Region) => {
      lastRegionUpdateRef.current = Date.now();
      setLongitudeDelta(region.longitudeDelta);
      regionRef.current = region;

      if (eventFetchTimerRef.current) clearTimeout(eventFetchTimerRef.current);
      eventFetchTimerRef.current = setTimeout(() => {
        void loadEvents(region);
      }, EVENT_FETCH_DEBOUNCE_MS);
    },
    [loadEvents],
  );

  useEffect(
    () => () => {
      if (eventFetchTimerRef.current) clearTimeout(eventFetchTimerRef.current);
    },
    [],
  );

  // Runs on first open and every time an event sheet closes (the map
  // regains focus): clear the temporary pin and pick up any event that was
  // just created, edited, or deleted.
  useFocusEffect(
    useCallback(() => {
      setDraftPin(null);
      void loadEvents(regionRef.current);
    }, [loadEvents]),
  );

  const openCreateEvent = useCallback((coordinate: LatLng) => {
    setDraftPin(coordinate);
    router.push({
      pathname: '/event/new',
      params: { latitude: String(coordinate.latitude), longitude: String(coordinate.longitude) },
    });
  }, []);

  const loadWeb = useCallback(async () => {
    setWebState('loading');
    try {
      const [connectionsData, edgesData] = await Promise.all([
        fetchConnectionLocations(),
        fetchConnectionEdges(),
      ]);
      setConnections(connectionsData);
      setEdges(edgesData);
      setWebState('loaded');
    } catch (error) {
      console.error('Failed to load Web Map data', error);
      setWebState('error');
    }
  }, []);

  // Only foreground permission — we never request background location.
  useFocusEffect(
    useCallback(() => {
      let cancelled = false;

      (async () => {
        const { status } = await Location.requestForegroundPermissionsAsync();
        if (cancelled) return;

        if (status !== Location.PermissionStatus.GRANTED) {
          setPermissionState('denied');
          return;
        }
        setPermissionState('granted');

        const position = await Location.getCurrentPositionAsync({});
        if (cancelled) return;
        setMyPosition({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        });

        try {
          await updateMyLocation(position.coords.latitude, position.coords.longitude);
        } catch (error) {
          console.error('Failed to save location', error);
        }

        if (cancelled) return;
        void loadWeb();
      })();

      return () => {
        cancelled = true;
      };
    }, [loadWeb]),
  );

  // The map already shows me via showsUserLocation, so don't double it up
  // with a marker from my own row in get_connection_locations().
  const otherConnections = useMemo(
    () => connections.filter((c) => c.id !== myId),
    [connections, myId],
  );

  const clusterDistance = useMemo(() => regionToClusterDistance(longitudeDelta), [longitudeDelta]);

  const groupedClusters = useMemo(
    () => clusterConnections(otherConnections, clusterDistance),
    [otherConnections, clusterDistance],
  );

  // The map fills the screen width, so this approximates how many degrees
  // of longitude one screen point covers at the current zoom — used to
  // merge any bubbles that would otherwise visually overlap, even if
  // they're far enough apart in real distance to count as separate areas.
  const { width: windowWidth } = useWindowDimensions();
  const degreesPerPoint = longitudeDelta / windowWidth;

  // Zoomed in far enough, any group that's still left can't split on its
  // own (its people share a saved spot), so lay them out side by side.
  const clusters = useMemo(() => {
    const resolved = resolveBubbleOverlaps(groupedClusters, degreesPerPoint);
    return longitudeDelta <= FAN_OUT_MAX_LONGITUDE_DELTA
      ? fanOutClusters(resolved, degreesPerPoint)
      : resolved;
  }, [groupedClusters, degreesPerPoint, longitudeDelta]);

  // Every connection's id points at the cluster (area bubble) it landed in,
  // so spokes and mutual lines connect bubble-to-bubble, never to a single
  // person's exact coordinates.
  const clusterByMemberId = useMemo(() => {
    const map = new Map<string, LocationCluster>();
    for (const cluster of clusters) {
      for (const member of cluster.members) {
        map.set(member.id, cluster);
      }
    }
    return map;
  }, [clusters]);

  const mutualLines = useMemo(() => {
    const seenPairs = new Set<string>();
    const lines: { key: string; coordinates: { latitude: number; longitude: number }[] }[] = [];

    for (const edge of edges) {
      const clusterA = clusterByMemberId.get(edge.user_a);
      const clusterB = clusterByMemberId.get(edge.user_b);
      if (!clusterA || !clusterB || clusterA.key === clusterB.key) continue;

      const pairKey = [clusterA.key, clusterB.key].sort().join('|');
      if (seenPairs.has(pairKey)) continue;
      seenPairs.add(pairKey);

      lines.push({ key: pairKey, coordinates: [clusterA.centroid, clusterB.centroid] });
    }

    return lines;
  }, [edges, clusterByMemberId]);

  // Your spokes plus the mutual lines, in one list so the casing pass and
  // the white-line pass draw exactly the same set.
  const webLines = useMemo(() => {
    const spokes = myPosition
      ? clusters.map((cluster) => ({
          key: `spoke-${cluster.key}`,
          kind: 'spoke' as const,
          coordinates: [myPosition, cluster.centroid],
        }))
      : [];
    const mutuals = mutualLines.map((line) => ({
      key: `edge-${line.key}`,
      kind: 'mutual' as const,
      coordinates: line.coordinates,
    }));
    return [...spokes, ...mutuals];
  }, [myPosition, clusters, mutualLines]);

  if (permissionState === 'denied') {
    return (
      <ThemedView style={styles.container}>
        <SafeAreaView style={styles.safeArea}>
          <ThemedText type="subtitle" style={styles.centerText}>
            Turn on location
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
            Bolas needs your approximate location to show you on the Web Map and help you find
            nearby builders. You can turn it on any time in Settings.
          </ThemedText>
          <Pressable
            onPress={() => Linking.openSettings()}
            accessibilityRole="button"
            accessibilityLabel="Open Settings">
            <ThemedView type="backgroundSelected" style={styles.button}>
              <ThemedText type="smallBold" themeColor="text">
                Open Settings
              </ThemedText>
            </ThemedView>
          </Pressable>
        </SafeAreaView>
      </ThemedView>
    );
  }

  return (
    <ThemedView style={styles.container}>
      <MapView
        style={styles.map}
        initialRegion={BOISE_REGION}
        onRegionChange={handleRegionChange}
        onRegionChangeComplete={handleRegionChangeComplete}
        onLongPress={(event) => openCreateEvent(event.nativeEvent.coordinate)}
        userInterfaceStyle={mapScheme}
        // Apple Maps puts its compass (shown while the map is rotated) in the
        // top-right corner — nudge it down below the "+" button.
        compassOffset={{ x: 0, y: FAB_SIZE + Spacing.two }}
        showsUserLocation={permissionState === 'granted'}>
        {/* Spoke outlines first, then every white line on top, so where two
            lines cross an outline never cuts across a white line. */}
        {webLines
          .filter((line) => line.kind === 'spoke')
          .map((line) => (
            <Polyline
              key={`casing-${line.key}`}
              coordinates={line.coordinates}
              strokeColor={SPOKE_CASING_COLOR}
              strokeWidth={SPOKE_CASING_WIDTH}
              zIndex={1}
            />
          ))}
        {webLines.map((line) => (
          <Polyline
            key={`line-${line.key}`}
            coordinates={line.coordinates}
            strokeColor={WEB_LINE_COLOR}
            strokeWidth={line.kind === 'spoke' ? SPOKE_LINE_WIDTH : MUTUAL_LINE_WIDTH}
            zIndex={2}
          />
        ))}

        {clusters.map((cluster) =>
          cluster.members.length === 1 ? (
            <IndividualAvatarMarker
              key={cluster.key}
              member={cluster.members[0]}
              coordinate={cluster.centroid}
              onPress={() => router.push(`/user/${cluster.members[0].id}`)}
            />
          ) : (
            <GroupMarker
              key={cluster.key}
              coordinate={cluster.centroid}
              count={cluster.members.length}
              onPress={() => setSelectedCluster(cluster)}
            />
          ),
        )}

        {/* Drawn after the people markers so events sit on top. */}
        {events.map((event) => (
          <EventMarker
            key={`${event.id}-${event.starts_at}`}
            event={event}
            onPress={() => router.push(`/event/${event.id}`)}
          />
        ))}

        {draftPin ? <DraftEventMarker coordinate={draftPin} /> : null}
      </MapView>

      <Pressable
        onPress={() =>
          openCreateEvent({
            latitude: regionRef.current.latitude,
            longitude: regionRef.current.longitude,
          })
        }
        accessibilityRole="button"
        accessibilityLabel="Create an event at the center of the map"
        accessibilityHint="Or long-press anywhere on the map to pick a spot"
        style={({ pressed }) => [
          styles.fab,
          { top: insets.top + Spacing.two },
          pressed && styles.fabPressed,
        ]}>
        <ThemedText style={styles.fabLabel}>+</ThemedText>
      </Pressable>

      {webState === 'loading' ? (
        <ThemedView type="backgroundElement" style={styles.banner}>
          <ActivityIndicator />
          <ThemedText type="small">Loading your connections…</ThemedText>
        </ThemedView>
      ) : null}

      {webState === 'error' ? (
        <ThemedView type="backgroundElement" style={styles.banner}>
          <ThemedText type="small" themeColor="textSecondary">
            Couldn't load your connections.
          </ThemedText>
          <Pressable onPress={loadWeb} accessibilityRole="button" accessibilityLabel="Retry">
            <ThemedText type="smallBold">Retry</ThemedText>
          </Pressable>
        </ThemedView>
      ) : null}

      {webState === 'loaded' && otherConnections.length === 0 ? (
        <ThemedView type="backgroundElement" style={styles.banner}>
          <ThemedText type="small" themeColor="textSecondary">
            No connections yet — add some from Discover to see them here.
          </ThemedText>
        </ThemedView>
      ) : null}

      <ClusterListModal
        visible={selectedCluster !== null}
        members={selectedCluster?.members ?? []}
        onClose={() => setSelectedCluster(null)}
        onSelect={(id) => {
          setSelectedCluster(null);
          router.push(`/user/${id}`);
        }}
      />
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  map: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingBottom: BottomTabInset + Spacing.three,
    maxWidth: MaxContentWidth,
  },
  centerText: {
    textAlign: 'center',
  },
  button: {
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
  },
  banner: {
    position: 'absolute',
    left: Spacing.four,
    right: Spacing.four,
    bottom: BottomTabInset + Spacing.three,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.two,
    paddingVertical: Spacing.three,
    paddingHorizontal: Spacing.three,
    borderRadius: Spacing.three,
    alignSelf: 'center',
    maxWidth: MaxContentWidth,
  },
  halo: {
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(250,245,236,0.25)',
    borderWidth: 1,
    borderColor: 'rgba(250,245,236,0.6)',
  },
  groupMarker: {
    width: GROUP_MARKER_SIZE,
    height: GROUP_MARKER_SIZE,
    borderRadius: GROUP_MARKER_SIZE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: AccentColor,
    borderWidth: 2,
    borderColor: '#faf5ec',
  },
  groupMarkerText: {
    color: '#fdfbf7',
  },
  // Top-right, clear of the tab bar; `top` is set inline from the safe-area
  // inset so it sits just below the status bar / notch.
  fab: {
    position: 'absolute',
    right: Spacing.four,
    width: FAB_SIZE,
    height: FAB_SIZE,
    borderRadius: FAB_SIZE / 2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: AccentColor,
    borderWidth: 2,
    borderColor: '#faf5ec',
    shadowColor: '#000',
    shadowOpacity: 0.25,
    shadowRadius: 6,
    shadowOffset: { width: 0, height: 2 },
    elevation: 4,
  },
  fabPressed: {
    opacity: 0.85,
  },
  fabLabel: {
    color: '#fdfbf7',
    fontSize: 28,
    lineHeight: 32,
    fontWeight: 600,
  },
});
