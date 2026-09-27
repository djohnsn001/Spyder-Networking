import { supabase } from '@/lib/supabase';
import type { ConnectionLevel, ConnectionRow, ConnectionStatus, Profile } from '@/lib/types';

// All connection rows the current user is part of, either side.
export async function fetchMyConnections(userId: string): Promise<ConnectionRow[]> {
  const { data, error } = await supabase
    .from('connections')
    .select('*')
    .or(`requester_id.eq.${userId},addressee_id.eq.${userId}`);
  if (error) {
    console.error('Failed to load connections', error);
    return [];
  }
  return data ?? [];
}

// Works out where things stand between the current user and someone else,
// from a list already fetched with fetchMyConnections.
export function getConnectionStatus(
  connections: ConnectionRow[],
  myId: string,
  otherId: string,
): {
  status: ConnectionStatus;
  connectionId: string | null;
  level: ConnectionLevel | null;
  metAt: string | null;
  metCity: string | null;
} {
  const match = connections.find(
    (c) =>
      (c.requester_id === myId && c.addressee_id === otherId) ||
      (c.requester_id === otherId && c.addressee_id === myId),
  );
  if (!match) return { status: 'none', connectionId: null, level: null, metAt: null, metCity: null };
  const details = {
    connectionId: match.id,
    level: match.level,
    metAt: match.met_at,
    metCity: match.met_city,
  };
  if (match.status === 'accepted') return { status: 'accepted', ...details };
  return {
    status: match.requester_id === myId ? 'pending_sent' : 'pending_received',
    ...details,
  };
}

export async function sendConnectionRequest(myId: string, otherId: string) {
  const { error } = await supabase
    .from('connections')
    .insert({ requester_id: myId, addressee_id: otherId });
  if (error) throw error;
}

export async function acceptConnectionRequest(connectionId: string) {
  const { error } = await supabase
    .from('connections')
    .update({ status: 'accepted' })
    .eq('id', connectionId);
  if (error) throw error;
}

// Covers cancelling a pending request, declining one, and removing an
// accepted connection — all just a row delete.
export async function removeConnection(connectionId: string) {
  const { error } = await supabase.from('connections').delete().eq('id', connectionId);
  if (error) throw error;
}

export type PendingRequest = {
  connectionId: string;
  createdAt: string;
  requester: Profile;
};

// Requests other people have sent to the current user, still awaiting a
// response, newest first.
export async function fetchPendingRequests(userId: string): Promise<PendingRequest[]> {
  const { data: rows, error } = await supabase
    .from('connections')
    .select('id, requester_id, created_at')
    .eq('addressee_id', userId)
    .eq('status', 'pending')
    .order('created_at', { ascending: false });
  if (error) {
    console.error('Failed to load requests', error);
    return [];
  }
  if (!rows || rows.length === 0) return [];

  const { data: requesters, error: profilesError } = await supabase
    .from('profiles')
    .select('*')
    .in(
      'id',
      rows.map((row) => row.requester_id),
    );
  if (profilesError) {
    console.error('Failed to load requesters', profilesError);
    return [];
  }

  const requestersById = new Map(requesters?.map((profile) => [profile.id, profile]));
  return rows
    .map((row) => {
      const requester = requestersById.get(row.requester_id);
      return requester
        ? { connectionId: row.id, createdAt: row.created_at, requester }
        : null;
    })
    .filter((request): request is PendingRequest => request !== null);
}

// Profiles of everyone the current user is accepted-connected with.
export async function fetchConnectionProfiles(userId: string): Promise<Profile[]> {
  const { data: rows, error } = await supabase
    .from('connections')
    .select('requester_id, addressee_id')
    .eq('status', 'accepted')
    .or(`requester_id.eq.${userId},addressee_id.eq.${userId}`);
  if (error) {
    console.error('Failed to load connections', error);
    return [];
  }
  if (!rows || rows.length === 0) return [];

  const otherIds = rows.map((row) => (row.requester_id === userId ? row.addressee_id : row.requester_id));

  const { data: profiles, error: profilesError } = await supabase
    .from('profiles')
    .select('*')
    .in('id', otherIds);
  if (profilesError) {
    console.error('Failed to load connection profiles', profilesError);
    return [];
  }
  return profiles ?? [];
}

export type ConnectionWithProfile = {
  connectionId: string;
  level: ConnectionLevel;
  metAt: string | null;
  metCity: string | null;
  profile: Profile;
};

// Everyone the current user is accepted-connected with, plus the level and
// (for in-person connections) when/where they met. Newest meeting first.
export async function fetchConnectionsByLevel(userId: string): Promise<ConnectionWithProfile[]> {
  const { data: rows, error } = await supabase
    .from('connections')
    .select('id, requester_id, addressee_id, level, met_at, met_city')
    .eq('status', 'accepted')
    .or(`requester_id.eq.${userId},addressee_id.eq.${userId}`)
    .order('met_at', { ascending: false, nullsFirst: false });
  if (error) {
    console.error('Failed to load connections', error);
    return [];
  }
  if (!rows || rows.length === 0) return [];

  const otherIdFor = (row: { requester_id: string; addressee_id: string }) =>
    row.requester_id === userId ? row.addressee_id : row.requester_id;

  const { data: profiles, error: profilesError } = await supabase
    .from('profiles')
    .select('*')
    .in('id', rows.map(otherIdFor));
  if (profilesError) {
    console.error('Failed to load connection profiles', profilesError);
    return [];
  }

  const profilesById = new Map(profiles?.map((profile) => [profile.id, profile]));
  return rows
    .map((row) => {
      const profile = profilesById.get(otherIdFor(row));
      return profile
        ? {
            connectionId: row.id,
            level: row.level,
            metAt: row.met_at,
            metCity: row.met_city,
            profile,
          }
        : null;
    })
    .filter((item): item is ConnectionWithProfile => item !== null);
}

export async function fetchConnectionCount(userId: string): Promise<number> {
  const { data, error } = await supabase.rpc('get_connection_count', { target_user: userId });
  if (error) {
    console.error('Failed to load connection count', error);
    return 0;
  }
  return data ?? 0;
}

export async function fetchMutualCount(otherUserId: string): Promise<number> {
  const { data, error } = await supabase.rpc('get_mutuals', { other_user: otherUserId });
  if (error) {
    console.error('Failed to load mutuals', error);
    return 0;
  }
  return data?.length ?? 0;
}
