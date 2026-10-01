import { useKeepAwake } from 'expo-keep-awake';
import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, View } from 'react-native';
import QRCode from 'react-native-qrcode-svg';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import {
  CHECKIN_ROTATE_MS,
  checkinUrlFor,
  createCheckinToken,
  fetchCheckinInfo,
} from '@/lib/checkin';
import { friendlyRpcError } from '@/lib/rpc';

const QR_SIZE = 240;
const COUNT_POLL_MS = 5000;
// While check-in hasn't opened yet, ask again this often.
const NOT_OPEN_RETRY_MS = 15_000;

type State =
  | { kind: 'loading' }
  | { kind: 'showing'; token: string }
  | { kind: 'not_open'; opensAt: string }
  | { kind: 'ended' }
  | { kind: 'unavailable' }
  | { kind: 'error'; message: string };

function formatTime(iso: string) {
  return new Date(iso).toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

function StayAwake() {
  useKeepAwake();
  return null;
}

// Host only: the event's check-in code. Opens 15 minutes before the start
// and rotates every 25 s (each code works 30 s), so a photo of it stops
// working almost immediately; attendees also have to be at the event.
export default function EventCheckinCodeScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const [state, setState] = useState<State>({ kind: 'loading' });
  const [count, setCount] = useState<number | null>(null);
  const [countsAsHosted, setCountsAsHosted] = useState(false);
  // Fetch a code, then schedule the next one: every 25 s while showing,
  // every 15 s while waiting for the window to open or after an error.
  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const schedule = (ms: number) => {
      timer = setTimeout(() => void tick(), ms);
    };
    async function tick() {
      try {
        const result = await createCheckinToken(id);
        if (cancelled) return;
        if (result.outcome === 'ok') {
          setState({ kind: 'showing', token: result.token });
          setCount(result.checkin_count);
          schedule(CHECKIN_ROTATE_MS);
        } else if (result.outcome === 'not_open') {
          setState({ kind: 'not_open', opensAt: result.opens_at });
          schedule(NOT_OPEN_RETRY_MS);
        } else if (result.outcome === 'ended') {
          setState({ kind: 'ended' });
        } else {
          setState({ kind: 'unavailable' });
        }
      } catch (error) {
        if (cancelled) return;
        setState({ kind: 'error', message: friendlyRpcError(error) });
        schedule(NOT_OPEN_RETRY_MS);
      }
    }
    schedule(0);
    return () => {
      cancelled = true;
      if (timer) clearTimeout(timer);
    };
  }, [id]);

  // Live count of check-ins while the code is up.
  const isShowing = state.kind === 'showing';
  useEffect(() => {
    if (!isShowing || !id) return;
    const poll = setInterval(async () => {
      try {
        const info = await fetchCheckinInfo(id);
        if (info?.checkin_count != null) setCount(info.checkin_count);
        if (info?.counts_as_hosted) setCountsAsHosted(true);
      } catch {
        // The next poll tries again.
      }
    }, COUNT_POLL_MS);
    return () => clearInterval(poll);
  }, [isShowing, id]);

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ThemedText type="subtitle" style={styles.center} accessibilityRole="header">
          Event check-in
        </ThemedText>

        {state.kind === 'loading' ? <ActivityIndicator color={AccentColor} /> : null}

        {state.kind === 'showing' ? (
          <>
            <StayAwake />
            {/* Always black on white: some scanners can't read inverted codes. */}
            <View style={styles.qrCard}>
              <QRCode
                value={checkinUrlFor(state.token)}
                size={QR_SIZE}
                color="#000000"
                backgroundColor="#ffffff"
              />
            </View>
            <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
              Attendees scan this in Bolas (Connect → Scan) to check in.
            </ThemedText>
            <ThemedText type="smallBold" style={styles.center}>
              {count ?? 0} checked in
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
              {countsAsHosted
                ? 'This event counts toward your Events hosted.'
                : 'At 3 check-ins, this event counts toward your Events hosted.'}
            </ThemedText>
          </>
        ) : null}

        {state.kind === 'not_open' ? (
          <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
            Check-in opens at {formatTime(state.opensAt)}, 15 minutes before the start. Keep this
            screen open and the code will appear.
          </ThemedText>
        ) : null}

        {state.kind === 'ended' ? (
          <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
            This event has ended, so check-in is closed.
          </ThemedText>
        ) : null}

        {state.kind === 'unavailable' ? (
          <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
            Check-in isn&apos;t available for this event.
          </ThemedText>
        ) : null}

        {state.kind === 'error' ? (
          <ThemedText type="small" themeColor="error" style={styles.center}>
            {state.message}
          </ThemedText>
        ) : null}

        <Pressable
          onPress={() => router.back()}
          accessibilityRole="button"
          accessibilityLabel="Done"
          hitSlop={Spacing.three}>
          <ThemedText type="smallBold" themeColor="textSecondary">
            Done
          </ThemedText>
        </Pressable>
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
  qrCard: {
    backgroundColor: '#ffffff',
    padding: Spacing.three,
    borderRadius: Spacing.four,
  },
  center: {
    textAlign: 'center',
  },
});
