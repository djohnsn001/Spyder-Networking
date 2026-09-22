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

// Turns the map's visible region into a cluster distance, so nearby people
// group together when zoomed out and split apart as you zoom in.
// longitudeDelta is how many degrees of longitude are visible edge-to-edge,
// i.e. it shrinks as you zoom in — and so does the grouping distance, with
// no floor, so any group eventually splits if you zoom in far enough.
//
// Privacy still holds without a floor: update_my_location() rounds every
// saved location to ~1.1km server-side, so zooming all the way in only
// ever shows that rounded spot, never anyone's real position.
//
// 0.15 means "group people who are within 15% of the screen's width of
// each other": at the default Boise zoom that keeps close neighbors
// grouped, and they split once you zoom in about 2x.
const CLUSTER_ZOOM_FACTOR = 0.15;

export function regionToClusterDistance(longitudeDelta: number): number {
  return longitudeDelta * CLUSTER_ZOOM_FACTOR;
}

// Once zoomed in this far (the screen showing ~0.05° of longitude, a few km
// across), every group that's still left is people whose saved spots are
// identical or nearly so — they'd never split on their own, so
// fanOutClusters lays them out side by side instead.
export const FAN_OUT_MAX_LONGITUDE_DELTA = 0.05;

// Space between fanned-out halos, in screen points.
const FAN_OUT_GAP_POINTS = 4;

// Replaces each remaining group with its members' own avatars, arranged in
// a small ring around the group's spot (two people sit left and right of
// it). Offsets are in screen points, converted to degrees for the current
// zoom, so the avatars always sit just touching-distance apart on screen.
// Purely visual — the offsets aren't anyone's real position.
export function fanOutClusters(
  clusters: LocationCluster[],
  degreesPerPoint: number,
): LocationCluster[] {
  return clusters.flatMap((cluster) => {
    const count = cluster.members.length;
    if (count <= 1) return [cluster];

    const spacingPoints = AVATAR_HALO_SIZE + FAN_OUT_GAP_POINTS;
    // Radius of a ring whose neighboring points are spacingPoints apart.
    const radiusPoints = spacingPoints / (2 * Math.sin(Math.PI / count));
    // On the (Mercator) map a degree of latitude is taller on screen than a
    // degree of longitude, by 1/cos(latitude).
    const lngPerPoint = degreesPerPoint;
    const latPerPoint = degreesPerPoint * Math.cos((cluster.centroid.latitude * Math.PI) / 180);

    // Sorted so each person keeps the same slot between renders.
    const members = [...cluster.members].sort((a, b) => a.id.localeCompare(b.id));
    return members.map((member, index) => {
      // Start on the left and go around, so a pair sits side by side.
      const angle = Math.PI + (2 * Math.PI * index) / count;
      return {
        key: member.id,
        members: [member],
        centroid: {
          latitude: cluster.centroid.latitude + Math.sin(angle) * radiusPoints * latPerPoint,
          longitude: cluster.centroid.longitude + Math.cos(angle) * radiusPoints * lngPerPoint,
        },
      };
    });
  });
}

// Every area is drawn as one fixed-size dot sitting exactly on its
// centroid — a solo person's avatar, or a count for a group — so the web's
// lines always land squarely on the marker. (fanOutClusters moves each
// fanned person's centroid, so their lines follow them too.) Same size
// either way, so resolveBubbleOverlaps has one constant footprint to
// reason about.
export const AVATAR_SIZE = 34;
export const GROUP_MARKER_SIZE = 34;
// The soft translucent ring drawn around each solo avatar.
export const AVATAR_HALO_SIZE = AVATAR_SIZE + 16;

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
