import { supabase } from '@/lib/supabase';
import type { ConnectionEdge, ConnectionLocation } from '@/lib/types';

export type LocationCluster = {
  key: string;
  centroid: { latitude: number; longitude: number };
  members: ConnectionLocation[];
};

function degreeDistance(
  a: { latitude: number; longitude: number },
  b: { latitude: number; longitude: number },
): number {
  const dLat = a.latitude - b.latitude;
  const dLng = a.longitude - b.longitude;
  return Math.sqrt(dLat * dLat + dLng * dLng);
}

function combineClusters(a: LocationCluster, b: LocationCluster): LocationCluster {
  const members = [...a.members, ...b.members];
  return {
    key: members
      .map((m) => m.id)
      .sort()
      .join(','),
    members,
    centroid: {
      latitude: members.reduce((sum, m) => sum + m.lat, 0) / members.length,
      longitude: members.reduce((sum, m) => sum + m.lng, 0) / members.length,
    },
  };
}

// Repeatedly merges the two nearest nodes (by shouldMerge) until nothing
// left qualifies. Used both for grouping raw connections into clusters and,
// separately, for merging clusters whose bubbles would visually overlap —
// same "keep combining until stable" shape, different merge rule.
function mergeUntilStable<T>(
  nodes: T[],
  shouldMerge: (a: T, b: T) => boolean,
  combine: (a: T, b: T) => T,
): T[] {
  let result = nodes;
  let mergedAny = true;

  while (mergedAny) {
    mergedAny = false;

    findMerge: for (let i = 0; i < result.length; i++) {
      for (let j = i + 1; j < result.length; j++) {
        if (shouldMerge(result[i], result[j])) {
          const merged = combine(result[i], result[j]);
          result = [
            ...result.slice(0, i),
            merged,
            ...result.slice(i + 1, j),
            ...result.slice(j + 1),
          ];
          mergedAny = true;
          break findMerge;
        }
      }
    }
  }

  return result;
}

// Groups connections whose (already-fuzzed) coordinates are within
// distanceDegrees of each other, repeatedly, so unlike a fixed grid, two
// nearby points can never end up split just because they happened to fall
// on opposite sides of a cell boundary. distanceDegrees is expected to
// scale with zoom (see regionToClusterDistance) so bubbles can merge
// further as you zoom out.
export function clusterConnections(
  connections: ConnectionLocation[],
  distanceDegrees: number,
): LocationCluster[] {
  const initial: LocationCluster[] = connections.map((connection) => ({
    key: connection.id,
    centroid: { latitude: connection.lat, longitude: connection.lng },
    members: [connection],
  }));

  return mergeUntilStable(
    initial,
    (a, b) => degreeDistance(a.centroid, b.centroid) <= distanceDegrees,
    combineClusters,
  );
}

// Extra breathing room (in screen points) kept between two bubbles even
// when they're not merged. Kept small on purpose — the bigger this is, the
// sooner zooming out forces areas to merge, which was collapsing the web
// down to one or two blobs well before you'd zoomed out very far at all.
const MIN_BUBBLE_GAP_POINTS = 0;

// Runs after clusterConnections. Two areas can be far enough apart in real
// distance to stay separate, yet still close enough on today's screen
// (especially zoomed out) that their markers would visually collide — this
// merges those too, using each marker's actual on-screen radius and the
// current degrees-per-point, so markers never overlap no matter the zoom
// level.
export function resolveBubbleOverlaps(
  clusters: LocationCluster[],
  degreesPerPoint: number,
): LocationCluster[] {
  return mergeUntilStable(
    clusters,
    (a, b) => {
      const radiusA = getMarkerFootprint(a.members.length) / 2;
      const radiusB = getMarkerFootprint(b.members.length) / 2;
      const minDistanceDegrees = (radiusA + radiusB + MIN_BUBBLE_GAP_POINTS) * degreesPerPoint;
      return degreeDistance(a.centroid, b.centroid) < minDistanceDegrees;
    },
    combineClusters,
  );
}

// Turns the map's visible region into a cluster distance, so separate areas
// can merge further as you zoom out. longitudeDelta is how many degrees of
// longitude are visible edge-to-edge, i.e. it shrinks as you zoom in.
//
// The floor is deliberately city-sized, not a few hundred meters: zooming
// in must never be able to split a group down to something that reads as
// one person's exact spot. resolveBubbleOverlaps separately guarantees
// bubbles never visually crowd together — this floor is what guarantees
// grouping never gets finer than "somewhere in this city," no matter how
// far in you zoom.
// Small on purpose: this only controls merging *beyond* the city floor
// below, i.e. combining separate cities together, which should take a lot
// of zooming out — the web staying spread out into distinct areas is more
// important than aggressively consolidating them.
const CLUSTER_ZOOM_FACTOR = 0.03;
const MIN_CLUSTER_DISTANCE_DEGREES = 0.05; // ~5.5km — roughly a city's footprint

export function regionToClusterDistance(longitudeDelta: number): number {
  return Math.max(longitudeDelta * CLUSTER_ZOOM_FACTOR, MIN_CLUSTER_DISTANCE_DEGREES);
}

// Every area is drawn as one fixed-size dot sitting exactly on its
// centroid — a solo person's avatar, or a count for a group — so the web's
// lines always land squarely on the marker instead of pointing at an empty
// spot next to fanned-out avatars. Same size either way, so
// resolveBubbleOverlaps has one constant footprint to reason about.
export const AVATAR_SIZE = 40;
export const GROUP_MARKER_SIZE = 40;

function getMarkerFootprint(memberCount: number): number {
  return memberCount <= 1 ? AVATAR_SIZE : GROUP_MARKER_SIZE;
}

// Rounds to ~1km happen server-side inside update_my_location — the raw
// GPS fix is only ever used locally to call it, never stored as-is.
export async function updateMyLocation(lat: number, lng: number) {
  const { error } = await supabase.rpc('update_my_location', { lat, lng });
  if (error) throw error;
}

// Pins for the Web Map: the caller's accepted connections who have location
// sharing on, plus the caller's own pin if their own sharing is on.
export async function fetchConnectionLocations(): Promise<ConnectionLocation[]> {
  const { data, error } = await supabase.rpc('get_connection_locations');
  if (error) throw error;
  return data ?? [];
}

// Pairs of the caller's connections who are also connected to each other —
// the lines to draw between mutuals, separate from the caller's own spokes.
export async function fetchConnectionEdges(): Promise<ConnectionEdge[]> {
  const { data, error } = await supabase.rpc('get_connection_edges');
  if (error) throw error;
  return data ?? [];
}
