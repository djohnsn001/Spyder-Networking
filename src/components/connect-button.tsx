import { Pressable, StyleSheet } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import type { ConnectionStatus } from '@/lib/types';

export function ConnectButton({
  status,
  onPress,
  pending,
}: {
  status: ConnectionStatus;
  onPress: () => void;
  pending: boolean;
}) {
  if (status === 'accepted') {
    return (
      <ThemedView type="backgroundSelected" style={styles.button}>
        <ThemedText type="smallBold" themeColor="textSecondary">
          Connected
        </ThemedText>
      </ThemedView>
    );
  }

  if (status === 'pending_received') {
    return (
      <ThemedView type="backgroundSelected" style={styles.button}>
        <ThemedText type="smallBold" themeColor="textSecondary">
          Wants to connect
        </ThemedText>
      </ThemedView>
    );
  }

  const isPendingSent = status === 'pending_sent';

  return (
    <Pressable
      onPress={onPress}
      disabled={pending}
      accessibilityRole="button"
      accessibilityLabel={isPendingSent ? 'Cancel request' : 'Connect'}
      style={({ pressed }) => [
        styles.button,
        {
          backgroundColor: isPendingSent ? 'transparent' : AccentColor,
          borderWidth: isPendingSent ? 1 : 0,
          borderColor: AccentColor,
          opacity: pending ? 0.6 : 1,
        },
        pressed && styles.buttonPressed,
      ]}>
      <ThemedText
        type="smallBold"
        style={isPendingSent ? { color: AccentColor } : styles.buttonLabelWhite}>
        {isPendingSent ? 'Requested' : 'Connect'}
      </ThemedText>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabelWhite: {
    color: '#ffffff',
  },
});
