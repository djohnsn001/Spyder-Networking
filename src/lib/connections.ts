import { supabase } from '@/lib/supabase';
import type { ConnectionRow, ConnectionStatus, Profile } from '@/lib/types';

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
): { status: ConnectionStatus; connectionId: string | null } {
  const match = connections.find(
    (c) =>
      (c.requester_id === myId && c.addressee_id === otherId) ||
      (c.requester_id === otherId && c.addressee_id === myId),
  );
  if (!match) return { status: 'none', connectionId: null };
  if (match.status === 'accepted') return { status: 'accepted', connectionId: match.id };
  return {
    status: match.requester_id === myId ? 'pending_sent' : 'pending_received',
    connectionId: match.id,
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

export async function fetchMutualCount(otherUserId: string): Promise<number> {
  const { data, error } = await supabase.rpc('get_mutuals', { other_user: otherUserId });
  if (error) {
    console.error('Failed to load mutuals', error);
    return 0;
  }
  return data?.length ?? 0;
}
