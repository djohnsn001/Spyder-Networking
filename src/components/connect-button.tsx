import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { ConfirmDialog } from '@/components/confirm-dialog';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import type { ConnectionStatus } from '@/lib/types';

export function ConnectButton({
  status,
  onPress,
  onUnconnect,
  onAccept,
  onDecline,
  pending,
}: {
  status: ConnectionStatus;
  onPress: () => void;
  onUnconnect?: () => void;
  onAccept?: () => void;
  onDecline?: () => void;
  pending: boolean;
}) {
  const [confirmingUnconnect, setConfirmingUnconnect] = useState(false);

  if (status === 'accepted') {
    return (
      <>
        <Pressable
          onPress={() => onUnconnect && setConfirmingUnconnect(true)}
          disabled={pending || !onUnconnect}
          accessibilityRole="button"
          accessibilityLabel="Connected. Tap to unconnect">
          <ThemedView type="backgroundSelected" style={styles.button}>
            <ThemedText type="smallBold" themeColor="textSecondary">
              Connected
            </ThemedText>
          </ThemedView>
        </Pressable>
        <ConfirmDialog
          visible={confirmingUnconnect}
          title="Remove this connection?"
          message="You'll need to send a new request to reconnect."
          confirmLabel="Unconnect"
          danger
          onCancel={() => setConfirmingUnconnect(false)}
          onConfirm={() => {
            setConfirmingUnconnect(false);
            onUnconnect?.();
          }}
        />
      </>
    );
  }

  if (status === 'pending_received') {
    if (!onAccept || !onDecline) {
      return (
        <ThemedView type="backgroundSelected" style={styles.button}>
          <ThemedText type="smallBold" themeColor="textSecondary">
            Wants to connect
          </ThemedText>
        </ThemedView>
      );
    }
    return (
      <View style={styles.receivedRow}>
        <Pressable
          onPress={onAccept}
          disabled={pending}
          accessibilityRole="button"
          accessibilityLabel="Accept request"
          style={({ pressed }) => [
            styles.smallButton,
            { backgroundColor: AccentColor, opacity: pending ? 0.6 : 1 },
            pressed && styles.buttonPressed,
          ]}>
          <ThemedText type="smallBold" style={styles.buttonLabelWhite}>
            Accept
          </ThemedText>
        </Pressable>
        <Pressable
          onPress={onDecline}
          disabled={pending}
          accessibilityRole="button"
          accessibilityLabel="Decline request"
          style={({ pressed }) => [
            styles.smallButton,
            styles.declineButton,
            { opacity: pending ? 0.6 : 1 },
            pressed && styles.buttonPressed,
          ]}>
          <ThemedText type="smallBold" themeColor="textSecondary">
            Decline
          </ThemedText>
        </Pressable>
      </View>
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
  receivedRow: {
    marginTop: Spacing.two,
    flexDirection: 'row',
    gap: Spacing.two,
  },
  smallButton: {
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  declineButton: {
    backgroundColor: 'transparent',
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabelWhite: {
    color: '#ffffff',
  },
});
