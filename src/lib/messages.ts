import type { RealtimePostgresInsertPayload } from '@supabase/supabase-js';

import { supabase } from '@/lib/supabase';
import type { Message, Profile } from '@/lib/types';

export const MAX_MESSAGE_LENGTH = 2000;

// Supabase treats a channel name as a single shared object — calling
// .channel() twice with the same name hands back the same (already
// subscribed) channel, and subscribing twice or adding listeners after the
// fact throws. Suffixing with a counter gives every subscribeTo* call its
// own channel, even when two callers both want "the inbox" or "the same
// conversation" at once.
let channelSequence = 0;

export type ConversationSummary = {
  conversationId: string;
  otherUser: Profile;
  lastMessage: { body: string; senderId: string; createdAt: string } | null;
  lastActivityAt: string;
  unreadCount: number;
};

// Everything the inbox needs, most recently active first. Follows the same
// "fetch rows, then batch-fetch what they reference" shape as
// fetchConnectionProfiles/fetchPendingRequests rather than a single joined
// query, for the same reason: it's plain Supabase client calls, no
// PostgREST relationship naming to get right.
export async function fetchConversations(userId: string): Promise<ConversationSummary[]> {
  const { data: conversations, error } = await supabase
    .from('conversations')
    .select('*')
    .eq('is_group', false)
    .order('last_message_at', { ascending: false });
  if (error) {
    console.error('Failed to load conversations', error);
    return [];
  }
  if (!conversations || conversations.length === 0) return [];

  const otherUserIds = conversations
    .map((c) => (c.user_a_id === userId ? c.user_b_id : c.user_a_id))
    .filter((id): id is string => id !== null);

  const lastMessageIds = conversations
    .map((c) => c.last_message_id)
    .filter((id): id is string => id !== null);

  const [profilesResult, messagesResult, unreadResult] = await Promise.all([
    supabase.from('profiles').select('*').in('id', otherUserIds),
    lastMessageIds.length > 0
      ? supabase.from('messages').select('id, body, sender_id, created_at').in('id', lastMessageIds)
      : Promise.resolve({ data: [], error: null }),
    supabase.rpc('get_unread_counts'),
  ]);

  if (profilesResult.error) {
    console.error('Failed to load conversation profiles', profilesResult.error);
    return [];
  }
  if (messagesResult.error) {
    console.error('Failed to load last messages', messagesResult.error);
  }
  if (unreadResult.error) {
    console.error('Failed to load unread counts', unreadResult.error);
  }

  const profilesById = new Map((profilesResult.data ?? []).map((profile) => [profile.id, profile]));
  const lastMessagesById = new Map((messagesResult.data ?? []).map((message) => [message.id, message]));
  const unreadByConversation = new Map(
    (unreadResult.data ?? []).map((row: { conversation_id: string; unread_count: number }) => [
      row.conversation_id,
      row.unread_count,
    ]),
  );

  return conversations
    .map((conversation) => {
      const otherId = conversation.user_a_id === userId ? conversation.user_b_id : conversation.user_a_id;
      const otherUser = otherId ? profilesById.get(otherId) : undefined;
      if (!otherUser) return null;

      const lastMessageRow = conversation.last_message_id
        ? lastMessagesById.get(conversation.last_message_id)
        : undefined;

      return {
        conversationId: conversation.id,
        otherUser,
        lastMessage: lastMessageRow
          ? {
              body: lastMessageRow.body,
              senderId: lastMessageRow.sender_id,
              createdAt: lastMessageRow.created_at,
            }
          : null,
        lastActivityAt: conversation.last_message_at,
        unreadCount: unreadByConversation.get(conversation.id) ?? 0,
      };
    })
    .filter((summary): summary is ConversationSummary => summary !== null);
}

// Finds or creates the 1:1 conversation with other_user, enforcing the
// accepted-connection rule server-side. Throws (rather than logging and
// returning a fallback) because there's no sane default conversation id to
// hand back on failure — the caller needs to know it didn't work.
export async function getOrStartDirectConversation(otherUserId: string): Promise<string> {
  const { data, error } = await supabase.rpc('get_or_create_direct_conversation', {
    other_user: otherUserId,
  });
  if (error) throw error;
  return data;
}

// Newest-first, paginated with a "before" cursor rather than offset — pass
// the oldest createdAt currently loaded to fetch the next page up.
// Deliberately returned newest-first (matching the messages_conversation_created_idx
// order) rather than reversed here, so the chat screen can render it with
// an inverted FlatList, the normal RN pattern for "newest at the bottom."
export async function fetchMessages(
  conversationId: string,
  options: { beforeCreatedAt?: string; limit?: number } = {},
): Promise<Message[]> {
  const { beforeCreatedAt, limit = 30 } = options;
  let query = supabase
    .from('messages')
    .select('*')
    .eq('conversation_id', conversationId)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (beforeCreatedAt) {
    query = query.lt('created_at', beforeCreatedAt);
  }
  const { data, error } = await query;
  if (error) {
    console.error('Failed to load messages', error);
    return [];
  }
  return data ?? [];
}

// Checked client-side too (not just the database's check constraint) so a
// bad message never makes a round trip just to be rejected.
export async function sendMessage(
  conversationId: string,
  senderId: string,
  body: string,
): Promise<Message> {
  const trimmed = body.trim();
  if (!trimmed) {
    throw new Error('Message cannot be empty.');
  }
  if (trimmed.length > MAX_MESSAGE_LENGTH) {
    throw new Error(`Messages can't be longer than ${MAX_MESSAGE_LENGTH} characters.`);
  }

  const { data, error } = await supabase
    .from('messages')
    .insert({ conversation_id: conversationId, sender_id: senderId, body: trimmed })
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function markConversationRead(conversationId: string, userId: string): Promise<void> {
  const { error } = await supabase
    .from('conversation_participants')
    .update({ last_read_at: new Date().toISOString() })
    .eq('conversation_id', conversationId)
    .eq('user_id', userId);
  if (error) throw error;
}

// Feeds the nav tab badge. Always for the current session's user (the
// get_total_unread_count function takes no argument), so no userId param.
export async function getTotalUnreadCount(): Promise<number> {
  const { data, error } = await supabase.rpc('get_total_unread_count');
  if (error) {
    console.error('Failed to load unread count', error);
    return 0;
  }
  return data ?? 0;
}

// Live updates for one open chat screen. supabase-js keeps the realtime
// connection's auth token in sync with the current session automatically,
// so this only ever receives inserts the "Members can view messages"
// policy would let this user SELECT anyway — same access rule, no
// separate realtime-specific check needed.
export function subscribeToConversationMessages(
  conversationId: string,
  onInsert: (message: Message) => void,
): () => void {
  const channel = supabase
    .channel(`messages:conversation:${conversationId}:${channelSequence++}`)
    .on(
      'postgres_changes',
      {
        event: 'INSERT',
        schema: 'public',
        table: 'messages',
        filter: `conversation_id=eq.${conversationId}`,
      },
      (payload: RealtimePostgresInsertPayload<Message>) => onInsert(payload.new),
    )
    .subscribe();

  return () => {
    supabase.removeChannel(channel);
  };
}

// Live updates for the inbox: no filter, because the inbox cares about new
// messages across *every* conversation the user is in, not just one. RLS
// still scopes delivery to those conversations — this never receives a
// message from a conversation the caller isn't a member of.
export function subscribeToInboxMessages(onInsert: (message: Message) => void): () => void {
  const channel = supabase
    .channel(`messages:inbox:${channelSequence++}`)
    .on(
      'postgres_changes',
      { event: 'INSERT', schema: 'public', table: 'messages' },
      (payload: RealtimePostgresInsertPayload<Message>) => onInsert(payload.new),
    )
    .subscribe();

  return () => {
    supabase.removeChannel(channel);
  };
}
