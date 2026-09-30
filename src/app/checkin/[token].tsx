import * as Haptics from 'expo-haptics';
import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { LocationGate } from '@/components/connect/location-gate';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import { useBadgeToasts } from '@/lib/badge-toasts';
import { CHECKIN_MESSAGE, type CheckinResult, isCheckinToken, redeemCheckin } from '@/lib/checkin';
import { useConnectLocation } from '@/lib/connect/use-connect-location';
import { friendlyRpcError } from '@/lib/rpc';

function close() {
  if (router.canGoBack()) router.back();
  else router.replace('/');
}

// Opened by scanning an event's check-in code (in Bolas's scanner, or the
// phone's camera). Checking in sends this phone's location: the server only
// accepts it at the event. Asks first, like connect links (a link could
// have been sent from anywhere).
export default function CheckinScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const code = token?.toLowerCase() ?? '';
  const location = useConnectLocation({ active: true, watch: true });
  const { checkForNewBadges } = useBadgeToasts();
  const [isChecking, setIsChecking] = useState(false);
  const [result, setResult] = useState<CheckinResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const invalid = !isCheckinToken(code);

  async function handleCheckIn() {
    setError(null);
    setIsChecking(true);
    try {
      const next = await redeemCheckin(code, location.fix);
      setResult(next);
      if (next.outcome === 'checked_in') {
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
        // Showed Up / Regular (and the host's Host badge) are awarded on the
        // server just now.
        checkForNewBadges();
      } else if (next.outcome !== 'already_checked_in') {
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
      }
    } catch (err) {
      setError(friendlyRpcError(err));
    } finally {
      setIsChecking(false);
    }
  }

  if (!invalid && !result && location.status !== 'granted') {
    return (
      <ThemedView style={styles.container}>
        <SafeAreaView style={styles.safeArea}>
          <LocationGate location={location} title="Check in to this event" />
        </SafeAreaView>
      </ThemedView>
    );
  }

  const done = result?.outcome === 'checked_in' || result?.outcome === 'already_checked_in';
  const failure =
    invalid ? CHECKIN_MESSAGE.invalid
    : result && !done ? CHECKIN_MESSAGE[result.outcome as keyof typeof CHECKIN_MESSAGE]
    : null;

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        {done ? (
          <>
            <ThemedText style={styles.bigIcon}>✅</ThemedText>
            <ThemedText type="subtitle" style={styles.center} accessibilityRole="header">
              {result?.outcome === 'checked_in' ? "You're checked in" : "You're already checked in"}
            </ThemedText>
            {result?.event_title ? (
              <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
                {result.event_title}
              </ThemedText>
            ) : null}
            <Pressable
              onPress={close}
              accessibilityRole="button"
              style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
              <ThemedText type="smallBold" style={styles.primaryLabel}>
                Done
              </ThemedText>
            </Pressable>
          </>
        ) : failure ? (
          <>
            <ThemedText type="default" style={styles.center}>
              {failure}
            </ThemedText>
            {!invalid && result?.outcome !== 'host' && result?.outcome !== 'closed' ? (
              <Pressable
                onPress={() => router.replace('/connect?tab=scan')}
                accessibilityRole="button"
                style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
                <ThemedText type="smallBold" style={styles.primaryLabel}>
                  Scan again
                </ThemedText>
              </Pressable>
            ) : null}
            <Pressable onPress={close} accessibilityRole="button" hitSlop={Spacing.three}>
              <ThemedText type="smallBold" themeColor="textSecondary">
                Close
              </ThemedText>
            </Pressable>
          </>
        ) : (
          <>
            <ThemedText style={styles.bigIcon}>📍</ThemedText>
            <ThemedText type="subtitle" style={styles.center} accessibilityRole="header">
              Check in to this event?
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
              Only check in if you&apos;re at the event right now. It counts toward your Events
              attended.
            </ThemedText>
            <Pressable
              onPress={handleCheckIn}
              disabled={isChecking || !location.fix}
              accessibilityRole="button"
              accessibilityState={{ disabled: isChecking || !location.fix, busy: isChecking }}
              style={({ pressed }) => [
                styles.primaryButton,
                (isChecking || !location.fix) && styles.disabled,
                pressed && styles.pressed,
              ]}>
              {isChecking ? (
                <ActivityIndicator color="#fdfbf7" />
              ) : (
                <ThemedText type="smallBold" style={styles.primaryLabel}>
                  {location.fix ? 'Check in' : 'Finding your location…'}
                </ThemedText>
              )}
            </Pressable>
            {error ? (
              <ThemedText type="small" themeColor="error" style={styles.center}>
                {error}
              </ThemedText>
            ) : null}
            <Pressable onPress={close} accessibilityRole="button" hitSlop={Spacing.three}>
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </>
        )}
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
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
  },
  bigIcon: {
    fontSize: 48,
    lineHeight: 60,
  },
  center: {
    textAlign: 'center',
  },
  primaryButton: {
    alignSelf: 'stretch',
    minHeight: 48,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.four,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
  },
  primaryLabel: {
    color: '#fdfbf7',
  },
  disabled: {
    opacity: 0.6,
  },
  pressed: {
    opacity: 0.8,
  },
});
