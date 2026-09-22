import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { FlatList, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { fetchConversations, subscribeToInboxMessages, type ConversationSummary } from '@/lib/messages';
import { useUnreadMessages } from '@/lib/unread-messages';

function formatRelativeTime(iso: string): string {
  const diffMinutes = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (diffMinutes < 1) return 'now';
  if (diffMinutes < 60) return `${diffMinutes}m`;
  const diffHours = Math.round(diffMinutes / 60);
  if (diffHours < 24) return `${diffHours}h`;
  const diffDays = Math.round(diffHours / 24);
  if (diffDays < 7) return `${diffDays}d`;
  return `${Math.round(diffDays / 7)}w`;
}

export default function MessagesScreen() {
  const { session } = useAuth();
  const myId = session?.user.id;
  const { refreshUnreadCount } = useUnreadMessages();

  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const load = useCallback(async () => {
    if (!myId) return;
    setIsLoading(true);
    setConversations(await fetchConversations(myId));
    setIsLoading(false);
  }, [myId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  useEffect(() => {
    if (!myId) return;
    const unsubscribe = subscribeToInboxMessages(() => {
      void load();
      void refreshUnreadCount();
    });
    return unsubscribe;
  }, [myId, load, refreshUnreadCount]);

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.content}>
          <View style={styles.headerRow}>
            <ThemedText type="subtitle">Messages</ThemedText>
            <Pressable
              onPress={() => router.push('/new-message')}
              accessibilityRole="button"
              accessibilityLabel="New message"
              style={({ pressed }) => [styles.newButton, pressed && styles.buttonPressed]}>
              <ThemedText type="smallBold" themeColor="textSecondary">
                New
              </ThemedText>
            </Pressable>
          </View>

          <FlatList
            data={conversations}
            keyExtractor={(item) => item.conversationId}
            contentContainerStyle={styles.listContent}
            refreshing={isLoading}
            onRefresh={load}
            ListEmptyComponent={
              !isLoading ? (
                <View style={styles.emptyState}>
                  <ThemedText type="default" style={styles.centerText}>
                    No conversations yet.
                  </ThemedText>
                  <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                    Connect with people in Discover, then start a conversation from their profile.
                  </ThemedText>
                  <Pressable
                    onPress={() => router.push('/discover')}
                    accessibilityRole="button"
                    accessibilityLabel="Go to Discover">
                    <ThemedText type="linkPrimary">Go to Discover</ThemedText>
                  </Pressable>
                </View>
              ) : null
            }
            renderItem={({ item }) => {
              const displayName = item.otherUser.full_name || item.otherUser.username || '';
              const hasUnread = item.unreadCount > 0;
              const previewPrefix = item.lastMessage?.senderId === myId ? 'You: ' : '';
              const previewText = item.lastMessage
                ? `${previewPrefix}${item.lastMessage.body}`
                : 'Say hello 👋';

              return (
                <Pressable
                  onPress={() => router.push(`/chat/${item.conversationId}`)}
                  accessibilityRole="button"
                  accessibilityLabel={`Open conversation with ${displayName}`}
                  style={({ pressed }) => pressed && styles.cardPressed}>
                  <ThemedView type="backgroundElement" style={styles.card}>
                    <Avatar uri={item.otherUser.avatar_url} name={displayName} size={48} />

                    <View style={styles.cardBody}>
                      <View style={styles.cardTopRow}>
                        <ThemedText
                          type={hasUnread ? 'smallBold' : 'small'}
                          numberOfLines={1}
                          style={styles.nameText}>
                          {displayName}
                        </ThemedText>
                        <ThemedText type="small" themeColor="textSecondary">
                          {formatRelativeTime(item.lastActivityAt)}
                        </ThemedText>
                      </View>

                      <View style={styles.cardBottomRow}>
                        <ThemedText
                          type={hasUnread ? 'smallBold' : 'small'}
                          themeColor={hasUnread ? 'text' : 'textSecondary'}
                          numberOfLines={1}
                          style={styles.previewText}>
                          {previewText}
                        </ThemedText>
                        {hasUnread ? <View style={styles.unreadDot} /> : null}
                      </View>
                    </View>
                  </ThemedView>
                </Pressable>
              );
            }}
          />
        </View>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
  },
  content: {
    flex: 1,
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    paddingHorizontal: Spacing.four,
  },
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: Spacing.three,
    marginBottom: Spacing.three,
  },
  newButton: {
    paddingVertical: Spacing.one,
    paddingHorizontal: Spacing.two,
  },
  buttonPressed: {
    opacity: 0.8,
  },
  listContent: {
    gap: Spacing.three,
    paddingBottom: BottomTabInset + Spacing.four,
    flexGrow: 1,
  },
  emptyState: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.two,
    paddingHorizontal: Spacing.four,
    marginTop: Spacing.six,
  },
  centerText: {
    textAlign: 'center',
  },
  cardPressed: {
    opacity: 0.85,
  },
  card: {
    flexDirection: 'row',
    gap: Spacing.three,
    padding: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
  },
  cardBody: {
    flex: 1,
    gap: Spacing.half,
  },
  cardTopRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    gap: Spacing.two,
  },
  nameText: {
    flexShrink: 1,
  },
  cardBottomRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: Spacing.two,
  },
  previewText: {
    flex: 1,
  },
  unreadDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: AccentColor,
  },
});
