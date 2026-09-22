import * as Location from 'expo-location';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  Pressable,
  StyleSheet,
  View,
  useWindowDimensions,
} from 'react-native';
import MapView, { Marker, Polyline, type Region } from 'react-native-maps';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ClusterListModal } from '@/components/cluster-list-modal';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  AVATAR_SIZE,
  clusterConnections,
  fetchConnectionEdges,
  fetchConnectionLocations,
  GROUP_MARKER_SIZE,
  regionToClusterDistance,
  resolveBubbleOverlaps,
  updateMyLocation,
  type LocationCluster,
} from '@/lib/map';
import type { ConnectionEdge, ConnectionLocation } from '@/lib/types';

const BOISE_REGION = {
  latitude: 43.615,
  longitude: -116.202,
  latitudeDelta: 0.1,
  longitudeDelta: 0.1,
};

// Pure white and thick, so the real connections between people read as a
// web drawn over the map rather than thin route lines.
const WEB_LINE_COLOR = '#FAF5EC';
const WEB_LINE_WIDTH = 3.5;

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
  const haloSize = AVATAR_SIZE + 16;

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

  const clusters = useMemo(
    () => resolveBubbleOverlaps(groupedClusters, degreesPerPoint),
    [groupedClusters, degreesPerPoint],
  );

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
        onRegionChangeComplete={(region) => {
          lastRegionUpdateRef.current = Date.now();
          setLongitudeDelta(region.longitudeDelta);
        }}
        showsUserLocation={permissionState === 'granted'}>
        {myPosition &&
          clusters.map((cluster) => (
            <Polyline
              key={`spoke-${cluster.key}`}
              coordinates={[myPosition, cluster.centroid]}
              strokeColor={WEB_LINE_COLOR}
              strokeWidth={WEB_LINE_WIDTH}
            />
          ))}

        {mutualLines.map((line) => (
          <Polyline
            key={`edge-${line.key}`}
            coordinates={line.coordinates}
            strokeColor={WEB_LINE_COLOR}
            strokeWidth={WEB_LINE_WIDTH}
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
      </MapView>

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
});
