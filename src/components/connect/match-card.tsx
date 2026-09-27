import * as Haptics from 'expo-haptics';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Modal, Pressable, StyleSheet, View } from 'react-native';
import Animated, {
  Easing,
  useAnimatedProps,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import Svg, { Circle } from 'react-native-svg';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, ErrorColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import {
  friendlyConnectError,
  undoInPersonConnection,
  type InPersonMatch,
} from '@/lib/connect/api';
import { CONNECTION_LEVEL_LABEL_IN_SENTENCE } from '@/lib/connect/labels';
import { getOrStartDirectConversation } from '@/lib/messages';

// The server allows 30 s (undo_until) to cover lag; the UI offers 10.
const UNDO_SECONDS = 10;
const RING_SIZE = 28;
const RING_STROKE = 3;
const RING_RADIUS = (RING_SIZE - RING_STROKE) / 2;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS;

const AnimatedCircle = Animated.createAnimatedComponent(Circle);

type UndoState = 'available' | 'undoing' | 'undone' | 'too_late' | 'expired';

// Shown on both phones after an in-person connect (QR or bump).
export function MatchCard({
  match,
  onDone,
}: {
  match: InPersonMatch;
  onDone: () => void;
}) {
  const { profile: me } = useAuth();
  const theme = useTheme();
  const other = match.other;
  const otherName = other.full_name || other.username || 'them';
  const handle = other.username ? `@${other.username}` : otherName;
  const myName = me?.full_name || me?.username || '';
  const canUndo = match.outcome !== 'already_connected';

  const [undoState, setUndoState] = useState<UndoState>(canUndo ? 'available' : 'expired');
  const [secondsLeft, setSecondsLeft] = useState(UNDO_SECONDS);
  const [error, setError] = useState<string | null>(null);
  const [isStartingChat, setIsStartingChat] = useState(false);

  const strand = useSharedValue(0);
  const ring = useSharedValue(1);

  useEffect(() => {
    void Haptics.notificationAsync(
      match.outcome === 'already_connected'
        ? Haptics.NotificationFeedbackType.Warning
        : Haptics.NotificationFeedbackType.Success,
    );
    strand.value = withTiming(1, { duration: 600, easing: Easing.out(Easing.cubic) });
    if (canUndo) {
      ring.value = withTiming(0, { duration: UNDO_SECONDS * 1000, easing: Easing.linear });
    }
  }, [match, canUndo, strand, ring]);

  useEffect(() => {
    if (undoState !== 'available') return;
    const interval = setInterval(() => setSecondsLeft((s) => Math.max(0, s - 1)), 1000);
    return () => clearInterval(interval);
  }, [undoState]);

  useEffect(() => {
    if (secondsLeft === 0 && undoState === 'available') setUndoState('expired');
  }, [secondsLeft, undoState]);

  const strandStyle = useAnimatedStyle(() => ({ transform: [{ scaleX: strand.value }] }));
  const ringProps = useAnimatedProps(() => ({
    strokeDashoffset: RING_CIRCUMFERENCE * (1 - ring.value),
  }));

  async function handleUndo() {
    setUndoState('undoing');
    setError(null);
    try {
      const result = await undoInPersonConnection(match.connectionId);
      if (result === 'undone') {
        void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
        setUndoState('undone');
      } else {
        setUndoState('too_late');
      }
    } catch (e) {
      setError(friendlyConnectError(e));
      setUndoState('available');
    }
  }

  // The card lives inside a modal screen: close that screen, then open the
  // target. (A deep-linked cold start has nothing to go back to.)
  function leaveTo(path: `/user/${string}` | `/chat/${string}`) {
    if (router.canGoBack()) router.back();
    else router.replace('/');
    router.push(path);
  }

  async function handleMessage() {
    setIsStartingChat(true);
    setError(null);
    try {
      const conversationId = await getOrStartDirectConversation(other.id);
      leaveTo(`/chat/${conversationId}`);
    } catch (e) {
      if (__DEV__) console.warn('[connect] start chat failed', e);
      setError('Could not start a conversation. Try again.');
    } finally {
      setIsStartingChat(false);
    }
  }

  const undone = undoState === 'undone';
  const title = undone
    ? 'Undone'
    : match.outcome === 'already_connected'
      ? `You're already connected with ${handle}.`
      : match.outcome === 'upgraded'
        ? `You were acquaintances. Now you've met!`
        : `You met ${handle}`;
  const subtitle = undone
    ? match.outcome === 'upgraded'
      ? `Back to how things were with ${handle}.`
      : `You're not connected with ${handle}.`
    : [
        `You're now ${CONNECTION_LEVEL_LABEL_IN_SENTENCE.in_person}`,
        match.metCity ? `Met in ${match.metCity}` : null,
      ]
        .filter(Boolean)
        .join(' · ');

  return (
    <Modal visible transparent animationType="fade" onRequestClose={onDone}>
      <View style={styles.backdrop}>
        <ThemedView type="backgroundElement" style={styles.card}>
          <View style={styles.avatars}>
            <Avatar uri={me?.avatar_url ?? null} name={myName} size={64} />
            <View style={styles.strandTrack}>
              <Animated.View
                style={[
                  styles.strand,
                  { backgroundColor: undone ? theme.backgroundSelected : AccentColor },
                  strandStyle,
                ]}
              />
            </View>
            <Avatar uri={other.avatar_url} name={otherName} size={64} />
          </View>

          <ThemedText type="smallBold" style={styles.title}>
            {title}
          </ThemedText>
          {!undone && match.outcome !== 'already_connected' && other.full_name ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
              {other.full_name}
              {other.username ? ` · @${other.username}` : ''}
            </ThemedText>
          ) : null}
          <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
            {subtitle}
          </ThemedText>

          {undoState === 'available' || undoState === 'undoing' ? (
            <Pressable
              onPress={handleUndo}
              disabled={undoState === 'undoing'}
              accessibilityRole="button"
              accessibilityLabel={`Undo, ${secondsLeft} seconds left`}
              style={({ pressed }) => [styles.undoButton, pressed && styles.pressed]}>
              {undoState === 'undoing' ? (
                <ActivityIndicator color={AccentColor} />
              ) : (
                <Svg width={RING_SIZE} height={RING_SIZE}>
                  <Circle
                    cx={RING_SIZE / 2}
                    cy={RING_SIZE / 2}
                    r={RING_RADIUS}
                    stroke={theme.backgroundSelected}
                    strokeWidth={RING_STROKE}
                    fill="none"
                  />
                  <AnimatedCircle
                    cx={RING_SIZE / 2}
                    cy={RING_SIZE / 2}
                    r={RING_RADIUS}
                    stroke={AccentColor}
                    strokeWidth={RING_STROKE}
                    fill="none"
                    strokeDasharray={RING_CIRCUMFERENCE}
                    animatedProps={ringProps}
                    strokeLinecap="round"
                    // Start the ring at 12 o'clock.
                    transform={`rotate(-90 ${RING_SIZE / 2} ${RING_SIZE / 2})`}
                  />
                </Svg>
              )}
              <ThemedText type="smallBold" style={{ color: AccentColor }}>
                Undo
              </ThemedText>
            </Pressable>
          ) : null}

          {undoState === 'too_late' ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
              Too late to undo. You can remove them from their profile.
            </ThemedText>
          ) : null}

          {error ? (
            <ThemedText type="small" style={[styles.center, { color: ErrorColor }]}>
              {error}
            </ThemedText>
          ) : null}

          {!undone ? (
            <View style={styles.actions}>
              <Pressable
                onPress={() => leaveTo(`/user/${other.id}`)}
                accessibilityRole="button"
                accessibilityLabel={`View ${otherName}'s profile`}
                style={({ pressed }) => [styles.secondaryButton, pressed && styles.pressed]}>
                <ThemedText type="smallBold">View profile</ThemedText>
              </Pressable>
              <Pressable
                onPress={handleMessage}
                disabled={isStartingChat}
                accessibilityRole="button"
                accessibilityLabel={`Message ${otherName}`}
                style={({ pressed }) => [styles.secondaryButton, pressed && styles.pressed]}>
                {isStartingChat ? (
                  <ActivityIndicator color={AccentColor} />
                ) : (
                  <ThemedText type="smallBold">Message</ThemedText>
                )}
              </Pressable>
            </View>
          ) : null}

          <Pressable
            onPress={onDone}
            accessibilityRole="button"
            accessibilityLabel="Done"
            style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
            <ThemedText type="smallBold" style={styles.primaryLabel}>
              Done
            </ThemedText>
          </Pressable>
        </ThemedView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    padding: Spacing.four,
  },
  card: {
    width: '100%',
    maxWidth: 380,
    alignItems: 'center',
    gap: Spacing.two,
    padding: Spacing.four,
    borderRadius: Spacing.four,
  },
  avatars: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: Spacing.two,
  },
  strandTrack: {
    width: 56,
    height: 3,
    marginHorizontal: Spacing.two,
  },
  strand: {
    flex: 1,
    borderRadius: 2,
  },
  title: {
    fontSize: 18,
    lineHeight: 24,
    textAlign: 'center',
  },
  center: {
    textAlign: 'center',
  },
  undoButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.three,
    marginTop: Spacing.one,
  },
  actions: {
    flexDirection: 'row',
    gap: Spacing.two,
    marginTop: Spacing.two,
    alignSelf: 'stretch',
  },
  secondaryButton: {
    flex: 1,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: 'rgba(131,101,93,0.35)',
  },
  primaryButton: {
    alignSelf: 'stretch',
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: AccentColor,
  },
  primaryLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
});
