import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { LocationGate } from '@/components/connect/location-gate';
import { MatchCard } from '@/components/connect/match-card';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import {
  friendlyConnectError,
  LOCATION_MESSAGE,
  previewConnectToken,
  RATE_LIMITED_MESSAGE,
  redeemConnectToken,
  type InPersonMatch,
  type OtherProfile,
} from '@/lib/connect/api';
import { isConnectToken } from '@/lib/connect/parse-connect-url';
import { takePendingConnectToken } from '@/lib/connect/pending-link';
import { useConnectLocation } from '@/lib/connect/use-connect-location';

const RESULT_MESSAGE = {
  expired: 'That code expired. Ask them to show a fresh one.',
  used: 'That code was already used. Ask them to show a fresh one.',
  self: "That's your own code 🙂",
  invalid: "That link isn't a valid Bolas code.",
  rate_limited: RATE_LIMITED_MESSAGE,
  ...LOCATION_MESSAGE,
} as const;

function close() {
  if (router.canGoBack()) router.back();
  else router.replace('/');
}

// Opened from a bolas://connect/<token> link (e.g. the phone's own camera
// app). Only reachable signed in with a finished profile; otherwise the root
// layout replays the code here after login (see pending-link).
//
// A link can come from anywhere (a website, a text, a DM), so opening one
// must never connect by itself (security item H1). The screen first
// PREVIEWS the code, which shows whose it is without using it up, and only
// redeems when the person taps Connect. Connecting also sends this phone's
// location: the server only connects phones that are together (item H2).
export default function ConnectLinkScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const code = token?.toLowerCase() ?? '';
  const [other, setOther] = useState<OtherProfile | null>(null);
  const [isConnecting, setIsConnecting] = useState(false);
  const [match, setMatch] = useState<InPersonMatch | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const location = useConnectLocation({ active: true, watch: true });
  const { fix } = location;

  useEffect(() => {
    // This screen is handling the code, so the root layout mustn't replay it.
    takePendingConnectToken();
    setOther(null);
    setMatch(null);
    setMessage(null);
    if (!isConnectToken(code)) {
      setMessage(RESULT_MESSAGE.invalid);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const result = await previewConnectToken(code);
        if (cancelled) return;
        if (result.kind === 'ok') setOther(result.other);
        else setMessage(RESULT_MESSAGE[result.kind]);
      } catch (error) {
        if (!cancelled) setMessage(friendlyConnectError(error));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [code]);

  async function handleConnect() {
    setIsConnecting(true);
    try {
      const result = await redeemConnectToken(code, location.city, fix);
      if (result.kind === 'matched') setMatch(result.match);
      else {
        setOther(null);
        setMessage(RESULT_MESSAGE[result.kind]);
      }
    } catch (error) {
      setMessage(friendlyConnectError(error));
    } finally {
      setIsConnecting(false);
    }
  }

  const otherName = other?.full_name || other?.username || 'this person';
  // Connect needs a location fix; until then the button waits.
  const isWaitingForFix = !fix;

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
        {!other && !match && !message ? <ActivityIndicator color={AccentColor} /> : null}

        {other && !match ? (
          <>
            <Avatar uri={other.avatar_url} name={otherName} size={88} />
            <View style={styles.names}>
              <ThemedText type="subtitle" style={styles.center} accessibilityRole="header">
                Connect with {otherName}?
              </ThemedText>
              {other.full_name && other.username ? (
                <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
                  @{other.username}
                </ThemedText>
              ) : null}
            </View>
            <ThemedView type="backgroundElement" style={styles.note}>
              <ThemedText type="smallBold" style={styles.center}>
                Only connect with someone you&apos;re with right now.
              </ThemedText>
              <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
                People you meet in person can see your approximate area on the map when you share
                it. If someone sent you this link, tap Cancel.
              </ThemedText>
            </ThemedView>
            <Pressable
              onPress={handleConnect}
              disabled={isConnecting || isWaitingForFix}
              accessibilityRole="button"
              accessibilityLabel={`Connect with ${otherName}`}
              accessibilityState={{
                disabled: isConnecting || isWaitingForFix,
                busy: isConnecting || isWaitingForFix,
              }}
              style={({ pressed }) => [
                styles.primaryButton,
                (isConnecting || isWaitingForFix) && styles.disabled,
                pressed && styles.pressed,
              ]}>
              {isConnecting ? (
                <ActivityIndicator color="#fdfbf7" />
              ) : isWaitingForFix ? (
                <ThemedText type="smallBold" style={styles.primaryLabel}>
                  Finding your location…
                </ThemedText>
              ) : (
                <ThemedText type="smallBold" style={styles.primaryLabel}>
                  Connect
                </ThemedText>
              )}
            </Pressable>
            <Pressable
              onPress={close}
              disabled={isConnecting}
              hitSlop={Spacing.three}
              accessibilityRole="button"
              accessibilityLabel="Cancel">
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </>
        ) : null}

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
            <Pressable
              onPress={close}
              hitSlop={Spacing.three}
              accessibilityRole="button"
              accessibilityLabel="Close">
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
  names: {
    gap: Spacing.one,
  },
  center: {
    textAlign: 'center',
  },
  note: {
    alignSelf: 'stretch',
    gap: Spacing.one,
    padding: Spacing.three,
    borderRadius: Spacing.three,
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
