import { Stack, router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  FlatList,
  Keyboard,
  Platform,
  Pressable,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, ErrorColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import { fetchMyConnections, getConnectionStatus } from '@/lib/connections';
import {
  fetchMessages,
  fetchOtherParticipant,
  markConversationRead,
  MAX_MESSAGE_LENGTH,
  sendMessage,
  subscribeToConversationMessages,
} from '@/lib/messages';
import { openReport, openSafetyMenu } from '@/lib/safety';
import { useUnreadMessages } from '@/lib/unread-messages';
import type { Message, Profile } from '@/lib/types';

const PAGE_SIZE = 30;
// Messages from the same sender within this long of each other render as
// one visual group: tighter spacing, timestamp shown once.
const GROUP_GAP_MS = 5 * 60 * 1000;

type ChatMessage = Message & { status?: 'sending' | 'failed' };

function formatMessageTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

// Manual keyboard tracking instead of KeyboardAvoidingView: that component
// measures its own on-screen position to know how much to pad, and that
// measurement is unreliable here because of the inverted FlatList (its
// layout is flipped via transform) combined with react-native-screens —
// a known rough combination. Reading the keyboard height directly and
// padding the input area ourselves sidesteps the measurement entirely.
//
// iOS specifically needs the "will" events, not "did": "did" only fires
// once the keyboard's own slide-up animation has already finished, so
// driving a plain state value off it always lags a beat behind and looks
// like a late snap. "will" fires as the animation starts and reports its
// duration, so an Animated.timing driven off it can move in step with the
// real keyboard instead of chasing it. Android doesn't reliably emit
// "will" events, so it falls back to "did" there.
function useKeyboardPadding(baseInset: number): Animated.Value {
  const padding = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    const showEventName = Platform.OS === 'ios' ? 'keyboardWillShow' : 'keyboardDidShow';
    const hideEventName = Platform.OS === 'ios' ? 'keyboardWillHide' : 'keyboardDidHide';

    const showSubscription = Keyboard.addListener(showEventName, (event) => {
      const targetHeight = Math.max(0, event.endCoordinates.height - baseInset);
      Animated.timing(padding, {
        toValue: targetHeight,
        duration: event.duration || 250,
        useNativeDriver: false,
      }).start();
    });
    const hideSubscription = Keyboard.addListener(hideEventName, (event) => {
      Animated.timing(padding, {
        toValue: 0,
        duration: event?.duration || 200,
        useNativeDriver: false,
      }).start();
    });

    return () => {
      showSubscription.remove();
      hideSubscription.remove();
    };
  }, [padding, baseInset]);

  return padding;
}

export default function ChatScreen() {
  const { conversationId } = useLocalSearchParams<{ conversationId: string }>();
  const { session } = useAuth();
  const myId = session?.user.id;
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const keyboardPadding = useKeyboardPadding(insets.bottom);
  const { refreshUnreadCount } = useUnreadMessages();

  const [otherUser, setOtherUser] = useState<Profile | null>(null);
  const [isConnected, setIsConnected] = useState(true);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [draft, setDraft] = useState('');

  const isFocusedRef = useRef(false);

  const load = useCallback(async () => {
    if (!myId || !conversationId) return;
    setIsLoading(true);
    const [other, initialMessages, myConnections] = await Promise.all([
      fetchOtherParticipant(conversationId, myId),
      fetchMessages(conversationId, { limit: PAGE_SIZE }),
      fetchMyConnections(myId),
    ]);
    setOtherUser(other);
    setMessages(initialMessages);
    setHasMore(initialMessages.length === PAGE_SIZE);
    if (other) {
      setIsConnected(getConnectionStatus(myConnections, myId, other.id).status === 'accepted');
    }
    setIsLoading(false);

    await markConversationRead(conversationId, myId);
    void refreshUnreadCount();
  }, [conversationId, myId, refreshUnreadCount]);

  useFocusEffect(
    useCallback(() => {
      isFocusedRef.current = true;
      void load();
      return () => {
        isFocusedRef.current = false;
      };
    }, [load]),
  );

  useFocusEffect(
    useCallback(() => {
      if (!myId || !conversationId) return;
      const unsubscribe = subscribeToConversationMessages(conversationId, (message) => {
        setMessages((current) => {
          if (current.some((m) => m.id === message.id)) return current;
          return [message, ...current];
        });
        if (message.sender_id !== myId && isFocusedRef.current) {
          void markConversationRead(conversationId, myId);
          void refreshUnreadCount();
        }
      });
      return unsubscribe;
    }, [conversationId, myId, refreshUnreadCount]),
  );

  async function loadMore() {
    if (isLoadingMore || !hasMore || messages.length === 0 || !conversationId) return;
    setIsLoadingMore(true);
    const oldest = messages[messages.length - 1];
    const older = await fetchMessages(conversationId, {
      beforeCreatedAt: oldest.created_at,
      limit: PAGE_SIZE,
    });
    setMessages((current) => [...current, ...older]);
    setHasMore(older.length === PAGE_SIZE);
    setIsLoadingMore(false);
  }

  async function handleSend() {
    const trimmed = draft.trim();
    if (!trimmed || !myId || !conversationId) return;
    setDraft('');

    const tempId = `temp-${Date.now()}-${Math.random()}`;
    const optimisticMessage: ChatMessage = {
      id: tempId,
      conversation_id: conversationId,
      sender_id: myId,
      body: trimmed,
      created_at: new Date().toISOString(),
      status: 'sending',
    };
    setMessages((current) => [optimisticMessage, ...current]);
    await sendAndReconcile(tempId, conversationId, myId, trimmed);
  }

  async function handleRetry(message: ChatMessage) {
    if (!myId || !conversationId) return;
    setMessages((current) => current.map((m) => (m.id === message.id ? { ...m, status: 'sending' } : m)));
    await sendAndReconcile(message.id, conversationId, myId, message.body);
  }

  // Replaces the temp/failed entry with the real row once the insert
  // resolves. The realtime subscription above is also listening on this
  // same conversation, so it's possible (if the realtime event beats this
  // response back) that `sent`'s id is already in the list by the time we
  // get here — filtering it out before re-adding avoids a duplicate bubble
  // either way, regardless of which one arrives first.
  async function sendAndReconcile(tempId: string, targetConversationId: string, senderId: string, body: string) {
    try {
      const sent = await sendMessage(targetConversationId, senderId, body);
      setMessages((current) => {
        const withoutTempOrDupe = current.filter((m) => m.id !== tempId && m.id !== sent.id);
        return [sent, ...withoutTempOrDupe];
      });
    } catch (error) {
      console.error('Failed to send message', error);
      setMessages((current) => current.map((m) => (m.id === tempId ? { ...m, status: 'failed' } : m)));
    }
  }

  const displayName = otherUser?.full_name || otherUser?.username || '';
  const canSend = draft.trim().length > 0 && isConnected;

  // Long-press (or the screen-reader action) on one of their messages.
  function handleReportMessage(message: ChatMessage) {
    if (!otherUser || message.sender_id === myId || message.id.startsWith('temp-')) return;
    Alert.alert('Report this message?', undefined, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Report',
        style: 'destructive',
        onPress: () =>
          openReport(otherUser.id, 'message', { contextId: message.id, name: displayName }),
      },
    ]);
  }

  return (
    <ThemedView style={styles.container}>
      <Stack.Screen
        options={{
          headerTitle: () =>
            otherUser ? (
              <Pressable
                onPress={() => router.push(`/user/${otherUser.id}`)}
                accessibilityRole="button"
                accessibilityLabel={`View ${displayName}'s profile`}
                style={styles.headerTitle}>
                <Avatar uri={otherUser.avatar_url} name={displayName} size={28} />
                <ThemedText type="smallBold" numberOfLines={1}>
                  {displayName}
                </ThemedText>
              </Pressable>
            ) : null,
          headerRight: () =>
            otherUser ? (
              <Pressable
                onPress={() => openSafetyMenu(displayName || 'this person', otherUser.id, 'message')}
                hitSlop={Spacing.three}
                accessibilityRole="button"
                accessibilityLabel={`More options for ${displayName || 'this person'}`}
                accessibilityHint="Report or block">
                <ThemedText type="subtitle" themeColor="textSecondary">
                  ⋯
                </ThemedText>
              </Pressable>
            ) : null,
        }}
      />

      <SafeAreaView style={styles.safeArea} edges={['bottom']}>
        {isLoading ? (
          <ActivityIndicator style={styles.loading} />
        ) : !otherUser ? (
          <View style={styles.centeredMessage}>
            <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
              This conversation isn&apos;t available.
            </ThemedText>
          </View>
        ) : messages.length === 0 ? (
          <View style={styles.centeredMessage}>
            <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
              No messages yet — say hello 👋
            </ThemedText>
          </View>
        ) : (
          <FlatList
            data={messages}
            keyExtractor={(item) => item.id}
            inverted
            contentContainerStyle={styles.listContent}
            onEndReached={loadMore}
            onEndReachedThreshold={0.4}
            ListFooterComponent={isLoadingMore ? <ActivityIndicator style={styles.loadingMore} /> : null}
            renderItem={({ item, index }) => {
              const isMine = item.sender_id === myId;
              const previous = messages[index + 1]; // older, renders above (inverted)
              const next = messages[index - 1]; // newer, renders below (inverted)

              const sameGroupAsAbove =
                previous &&
                previous.sender_id === item.sender_id &&
                new Date(item.created_at).getTime() - new Date(previous.created_at).getTime() <
                  GROUP_GAP_MS;
              const sameGroupBelow =
                next &&
                next.sender_id === item.sender_id &&
                new Date(next.created_at).getTime() - new Date(item.created_at).getTime() <
                  GROUP_GAP_MS;

              return (
                <View
                  style={[
                    styles.bubbleRow,
                    isMine ? styles.bubbleRowMine : styles.bubbleRowTheirs,
                    { marginTop: sameGroupAsAbove ? Spacing.half : Spacing.two },
                  ]}>
                  {isMine ? (
                    <View style={[styles.bubble, styles.bubbleMine]}>
                      <ThemedText style={styles.bubbleTextMine}>{item.body}</ThemedText>
                    </View>
                  ) : (
                    <Pressable
                      onLongPress={() => handleReportMessage(item)}
                      delayLongPress={400}
                      accessibilityActions={[{ name: 'report', label: 'Report message' }]}
                      onAccessibilityAction={(event) => {
                        if (event.nativeEvent.actionName === 'report') handleReportMessage(item);
                      }}>
                      <ThemedView type="backgroundElement" style={styles.bubble}>
                        <ThemedText>{item.body}</ThemedText>
                      </ThemedView>
                    </Pressable>
                  )}

                  {!sameGroupBelow ? (
                    <ThemedText
                      type="small"
                      themeColor="textSecondary"
                      style={isMine ? styles.timestampMine : styles.timestampTheirs}>
                      {formatMessageTime(item.created_at)}
                    </ThemedText>
                  ) : null}

                  {item.status === 'failed' ? (
                    <Pressable
                      onPress={() => handleRetry(item)}
                      accessibilityRole="button"
                      accessibilityLabel="Retry sending this message"
                      style={isMine ? styles.timestampMine : styles.timestampTheirs}>
                      <ThemedText type="small" style={styles.failedText}>
                        Failed to send · Tap to retry
                      </ThemedText>
                    </Pressable>
                  ) : null}
                </View>
              );
            }}
          />
        )}

        <Animated.View style={{ paddingBottom: keyboardPadding }}>
          {isConnected ? (
            <View style={styles.inputRow}>
              <TextInput
                value={draft}
                onChangeText={setDraft}
                placeholder="Message..."
                placeholderTextColor={theme.textSecondary}
                multiline
                maxLength={MAX_MESSAGE_LENGTH}
                style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
              />
              <Pressable
                onPress={handleSend}
                disabled={!canSend}
                accessibilityRole="button"
                accessibilityLabel="Send message"
                style={({ pressed }) => [
                  styles.sendButton,
                  { backgroundColor: canSend ? AccentColor : theme.backgroundSelected },
                  pressed && canSend && styles.buttonPressed,
                ]}>
                <ThemedText
                  type="smallBold"
                  themeColor={canSend ? undefined : 'textSecondary'}
                  style={canSend ? styles.sendLabelActive : undefined}>
                  Send
                </ThemedText>
              </Pressable>
            </View>
          ) : (
            <ThemedView type="backgroundElement" style={styles.disconnectedNotice}>
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                You&apos;re no longer connected with {displayName || 'this person'}. You can still see
                your message history, but can&apos;t send new messages.
              </ThemedText>
            </ThemedView>
          )}
        </Animated.View>
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
  loading: {
    flex: 1,
  },
  loadingMore: {
    marginVertical: Spacing.three,
  },
  centeredMessage: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: Spacing.four,
  },
  headerTitle: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
  },
  listContent: {
    gap: 0,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.three,
  },
  bubbleRow: {
    maxWidth: '80%',
  },
  bubbleRowMine: {
    alignSelf: 'flex-end',
    alignItems: 'flex-end',
  },
  bubbleRowTheirs: {
    alignSelf: 'flex-start',
    alignItems: 'flex-start',
  },
  bubble: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.four,
  },
  bubbleMine: {
    backgroundColor: AccentColor,
  },
  bubbleTextMine: {
    color: '#fdfbf7',
  },
  timestampMine: {
    marginTop: Spacing.half,
    marginRight: Spacing.one,
  },
  timestampTheirs: {
    marginTop: Spacing.half,
    marginLeft: Spacing.one,
  },
  failedText: {
    color: ErrorColor,
  },
  inputRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: Spacing.two,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.three,
  },
  input: {
    flex: 1,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.four,
    fontSize: 16,
    maxHeight: 120,
  },
  sendButton: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  sendLabelActive: {
    color: '#fdfbf7',
  },
  buttonPressed: {
    opacity: 0.85,
  },
  disconnectedNotice: {
    marginHorizontal: Spacing.four,
    marginBottom: Spacing.three,
    padding: Spacing.three,
    borderRadius: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
});
