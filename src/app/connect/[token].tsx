import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { LocationGate } from '@/components/connect/location-gate';
import { MatchCard } from '@/components/connect/match-card';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import {
  friendlyConnectError,
  LOCATION_MESSAGE,
  redeemConnectToken,
  type InPersonMatch,
} from '@/lib/connect/api';
import { isConnectToken } from '@/lib/connect/parse-connect-url';
import { takePendingConnectToken } from '@/lib/connect/pending-link';
import { useConnectLocation } from '@/lib/connect/use-connect-location';

const RESULT_MESSAGE = {
  expired: 'That code expired. Ask them to show a fresh one.',
  used: 'That code was already used. Ask them to show a fresh one.',
  self: "That's your own code 🙂",
  invalid: "That link isn't a valid Bolas code.",
  ...LOCATION_MESSAGE,
} as const;

function close() {
  if (router.canGoBack()) router.back();
  else router.replace('/');
}

// Opened from a bolas://connect/<token> link (e.g. the phone's own camera
// app). Only reachable signed in with a finished profile; otherwise the root
// layout replays the code here after login (see pending-link).
export default function ConnectLinkScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const [match, setMatch] = useState<InPersonMatch | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  // The server only connects phones that are together (security item H2),
  // so this waits for a location fix before redeeming.
  const location = useConnectLocation({ active: true, watch: true });
  const { fix } = location;
  const redeemedRef = useRef<string | null>(null);

  useEffect(() => {
    // This screen is handling the code, so the root layout mustn't replay it.
    takePendingConnectToken();
  }, []);

  useEffect(() => {
    const code = token?.toLowerCase() ?? '';
    if (!isConnectToken(code)) {
      setMessage(RESULT_MESSAGE.invalid);
      return;
    }
    if (!fix || redeemedRef.current === code) return;
    redeemedRef.current = code;
    let cancelled = false;
    (async () => {
      try {
        const result = await redeemConnectToken(code, location.city, fix);
        if (cancelled) return;
        if (result.kind === 'matched') setMatch(result.match);
        else setMessage(RESULT_MESSAGE[result.kind]);
      } catch (error) {
        if (!cancelled) setMessage(friendlyConnectError(error));
      }
    })();
    return () => {
      cancelled = true;
    };
    // Redeem once, with the first fix; later fixes mustn't redeem again.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token, fix]);

  if (location.status !== 'granted' && !message && !match) {
    return (
      <ThemedView style={styles.container}>
        <SafeAreaView style={styles.safeArea}>
          <LocationGate location={location} title="Connect with this code" />
        </SafeAreaView>
      </ThemedView>
    );
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        {!match && !message ? <ActivityIndicator color={AccentColor} /> : null}
        {message ? (
          <>
            <ThemedText type="default" style={styles.center}>
              {message}
            </ThemedText>
            <Pressable
              onPress={() => router.replace('/connect?tab=scan')}
              accessibilityRole="button"
              accessibilityLabel="Open scanner"
              style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
              <ThemedText type="smallBold" style={styles.primaryLabel}>
                Open scanner
              </ThemedText>
            </Pressable>
            <Pressable onPress={close} accessibilityRole="button" accessibilityLabel="Close">
              <ThemedText type="smallBold" themeColor="textSecondary">
                Close
              </ThemedText>
            </Pressable>
          </>
        ) : null}
      </SafeAreaView>
      {match ? <MatchCard match={match} onDone={close} /> : null}
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
  center: {
    textAlign: 'center',
  },
  primaryButton: {
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.four,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
  },
  primaryLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
});
