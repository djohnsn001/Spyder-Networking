import * as Haptics from 'expo-haptics';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, View } from 'react-native';
import Animated, {
  Easing,
  cancelAnimation,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';

import { LocationGate } from '@/components/connect/location-gate';
import { ThemedText } from '@/components/themed-text';
import { AccentColor, Spacing } from '@/constants/theme';
import {
  friendlyConnectError,
  getBumpResult,
  RATE_LIMITED_MESSAGE,
  submitBump,
  type BumpResult,
  type InPersonMatch,
} from '@/lib/connect/api';
import { FALLBACK_ACCURACY_M, type ConnectLocation } from '@/lib/connect/use-connect-location';
import { useBumpDetector } from '@/lib/connect/use-bump-detector';

// After a 'waiting' result, poll this often for up to this long. The server
// gives up on a lone bump after 3 s (get_bump_result).
const POLL_MS = 400;
const POLL_FOR_MS = 3500;

const NO_MATCH_MESSAGE = "Didn't catch that. Tap again at the same time.";

type Phase = 'ready' | 'matching';
type Notice = { text: string; offerCode: boolean };

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function TapPanel({
  active,
  location,
  onMatched,
  onUseCode,
}: {
  active: boolean;
  location: ConnectLocation;
  onMatched: (match: InPersonMatch) => void;
  onUseCode: () => void;
}) {
  const [phase, setPhase] = useState<Phase>('ready');
  const [notice, setNotice] = useState<Notice | null>(null);
  const activeRef = useRef(active);
  useEffect(() => {
    activeRef.current = active;
  }, [active]);

  const { coords, accuracy, city } = location;
  const hasFix = coords !== null;

  const handleBump = useCallback(async () => {
    if (phase !== 'ready' || !coords) return;
    setPhase('matching');
    setNotice(null);
    void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);

    try {
      // Location was prefetched while the tab was open: never wait for GPS here.
      let result: BumpResult = await submitBump(
        coords.latitude,
        coords.longitude,
        accuracy ?? FALLBACK_ACCURACY_M,
        city,
      );

      if (result.kind === 'waiting') {
        const bumpId = result.bumpId;
        const deadline = Date.now() + POLL_FOR_MS;
        while (result.kind === 'waiting' && Date.now() < deadline && activeRef.current) {
          await wait(POLL_MS);
          result = await getBumpResult(bumpId);
        }
      }

      switch (result.kind) {
        case 'matched':
          onMatched(result.match);
          break;
        case 'ambiguous':
          setNotice({
            text: 'Lots of people tapping nearby. Use your code instead.',
            offerCode: true,
          });
          break;
        case 'poor_location':
          setNotice({ text: "Can't get a good location. Try My code.", offerCode: true });
          break;
        case 'rate_limited':
          setNotice({ text: RATE_LIMITED_MESSAGE, offerCode: false });
          break;
        default:
          // 'waiting' past the deadline, 'no_match', 'not_found'.
          setNotice({ text: NO_MATCH_MESSAGE, offerCode: false });
      }
      if (result.kind !== 'matched') {
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
      }
    } catch (error) {
      setNotice({ text: friendlyConnectError(error), offerCode: false });
    } finally {
      setPhase('ready');
    }
  }, [phase, coords, accuracy, city, onMatched]);

  const granted = location.status === 'granted';
  const { available, debug } = useBumpDetector({
    armed: active && granted && hasFix && phase === 'ready',
    onBump: handleBump,
  });

  // Gentle "ready" pulse.
  const pulse = useSharedValue(1);
  const pulsing = active && granted && hasFix && phase === 'ready';
  useEffect(() => {
    if (pulsing) {
      pulse.value = withRepeat(
        withTiming(1.12, { duration: 900, easing: Easing.inOut(Easing.quad) }),
        -1,
        true,
      );
    } else {
      cancelAnimation(pulse);
      pulse.value = withTiming(1);
    }
  }, [pulsing, pulse]);
  const pulseStyle = useAnimatedStyle(() => ({ transform: [{ scale: pulse.value }] }));

  if (!granted) {
    return <LocationGate location={location} title="Tap phones to connect" />;
  }

  return (
    <View style={styles.container}>
      <Animated.View style={[styles.pulse, pulseStyle]}>
        {phase === 'matching' ? (
          <ActivityIndicator color="#fdfbf7" size="large" />
        ) : (
          <ThemedText style={styles.pulseIcon}>📱</ThemedText>
        )}
      </Animated.View>

      <ThemedText type="smallBold" style={styles.center}>
        {phase === 'matching'
          ? 'Matching…'
          : hasFix
            ? 'Hold your phones and tap them together'
            : 'Finding your location…'}
      </ThemedText>
      <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
        Both of you need Bolas open on this tab.
      </ThemedText>

      {available === false ? (
        <ThemedText type="small" themeColor="error" style={styles.center}>
          This phone can&apos;t detect taps. Use your QR code instead.
        </ThemedText>
      ) : null}

      {notice ? (
        <View style={styles.notice}>
          <ThemedText type="small" style={styles.center}>
            {notice.text}
          </ThemedText>
          {notice.offerCode ? (
            <Pressable onPress={onUseCode} accessibilityRole="button" accessibilityLabel="Show my code">
              <ThemedText type="smallBold" style={styles.accent}>
                Show my code
              </ThemedText>
            </Pressable>
          ) : null}
        </View>
      ) : null}

      {__DEV__ ? (
        <View style={styles.debug}>
          <ThemedText type="code" themeColor="textSecondary">
            {`delta ${debug.delta.toFixed(2)}g  jerk ${debug.jerk.toFixed(2)}g\n` +
              `peak ${debug.peakDelta.toFixed(2)}g  triggers ${debug.triggers}\n` +
              `fix ${hasFix ? `±${Math.round(accuracy ?? 0)}m` : 'none'}  city ${city ?? '—'}`}
          </ThemedText>
          <Pressable
            onPress={handleBump}
            disabled={!hasFix || phase !== 'ready'}
            accessibilityRole="button"
            accessibilityLabel="Simulate bump"
            style={({ pressed }) => [styles.debugButton, pressed && styles.pressed]}>
            <ThemedText type="smallBold" themeColor="textSecondary">
              Simulate bump (dev)
            </ThemedText>
          </Pressable>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: Spacing.three,
  },
  centered: {
    alignItems: 'center',
    gap: Spacing.two,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
  },
  center: {
    textAlign: 'center',
  },
  pulse: {
    width: 140,
    height: 140,
    borderRadius: 70,
    backgroundColor: AccentColor,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.three,
  },
  pulseIcon: {
    fontSize: 56,
    lineHeight: 64,
  },
  notice: {
    alignItems: 'center',
    gap: Spacing.one,
  },
  accent: {
    color: AccentColor,
  },
  primaryButton: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.four,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
  },
  primaryLabel: {
    color: '#fdfbf7',
  },
  debug: {
    marginTop: Spacing.four,
    alignItems: 'center',
    gap: Spacing.two,
    padding: Spacing.three,
    borderRadius: Spacing.three,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: 'rgba(131,101,93,0.5)',
  },
  debugButton: {
    paddingVertical: Spacing.one,
    paddingHorizontal: Spacing.three,
  },
  pressed: {
    opacity: 0.8,
  },
});
