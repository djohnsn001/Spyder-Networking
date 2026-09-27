import { useEffect } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import QRCode from 'react-native-qrcode-svg';
import Animated, {
  Easing,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { AccentColor, ErrorColor, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import type { InPersonMatch } from '@/lib/connect/api';
import { connectUrlFor } from '@/lib/connect/parse-connect-url';
import { useRotatingToken } from '@/lib/connect/use-rotating-token';

const QR_SIZE = 220;

export function MyCodePanel({
  active,
  onMatched,
}: {
  active: boolean;
  onMatched: (match: InPersonMatch) => void;
}) {
  const { profile } = useAuth();
  const { token, rotatesAt, error } = useRotatingToken({ active, onMatched });
  const name = profile?.full_name || profile?.username || '';

  // Countdown bar: full when a new code appears, empty when it rotates.
  const progress = useSharedValue(1);
  useEffect(() => {
    if (!rotatesAt) return;
    progress.value = 1;
    progress.value = withTiming(0, {
      duration: Math.max(0, rotatesAt - Date.now()),
      easing: Easing.linear,
    });
  }, [rotatesAt, progress]);
  const barStyle = useAnimatedStyle(() => ({ width: `${progress.value * 100}%` }));

  return (
    <View style={styles.container}>
      {/* Always black on white: some scanners can't read inverted codes. */}
      <View style={styles.qrCard}>
        {token ? (
          <QRCode value={connectUrlFor(token)} size={QR_SIZE} color="#000000" backgroundColor="#ffffff" />
        ) : (
          <View style={styles.qrPlaceholder}>
            <ActivityIndicator color={AccentColor} />
          </View>
        )}
        <View style={styles.barTrack}>
          <Animated.View style={[styles.bar, barStyle]} />
        </View>
      </View>

      <View style={styles.identity}>
        <Avatar uri={profile?.avatar_url ?? null} name={name} size={40} />
        <View>
          <ThemedText type="smallBold">{name}</ThemedText>
          {profile?.username ? (
            <ThemedText type="small" themeColor="textSecondary">
              @{profile.username}
            </ThemedText>
          ) : null}
        </View>
      </View>

      <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
        Have them scan this in Bolas
      </ThemedText>

      {error ? (
        <ThemedText type="small" style={[styles.center, { color: ErrorColor }]}>
          {error}
        </ThemedText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: Spacing.three,
  },
  qrCard: {
    backgroundColor: '#ffffff',
    padding: Spacing.three,
    borderRadius: Spacing.four,
    gap: Spacing.three,
    alignItems: 'center',
  },
  qrPlaceholder: {
    width: QR_SIZE,
    height: QR_SIZE,
    alignItems: 'center',
    justifyContent: 'center',
  },
  barTrack: {
    width: QR_SIZE,
    height: 3,
    backgroundColor: '#ece4d6',
    borderRadius: 2,
    overflow: 'hidden',
  },
  bar: {
    height: 3,
    backgroundColor: AccentColor,
  },
  identity: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
  },
  center: {
    textAlign: 'center',
  },
});
