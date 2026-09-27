import { useState } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';

import { ConfirmDialog } from '@/components/confirm-dialog';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import { CONNECTION_LEVEL_LABEL } from '@/lib/connect/labels';
import type { ConnectionLevel, ConnectionStatus } from '@/lib/types';

export function ConnectButton({
  status,
  level,
  onPress,
  onUnconnect,
  onAccept,
  onDecline,
  pending,
}: {
  status: ConnectionStatus;
  // Shown instead of "Connected" once accepted.
  level?: ConnectionLevel | null;
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
          accessibilityLabel={`${level ? CONNECTION_LEVEL_LABEL[level] : 'Connected'}. Tap to unconnect`}>
          <ThemedView type="backgroundSelected" style={styles.button}>
            <ThemedText type="smallBold" themeColor="textSecondary">
              {level ? CONNECTION_LEVEL_LABEL[level] : 'Connected'}
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
  const addLabel = `Add as ${CONNECTION_LEVEL_LABEL.acquaintance}`;

  return (
    <Pressable
      onPress={onPress}
      disabled={pending}
      accessibilityRole="button"
      accessibilityLabel={isPendingSent ? 'Cancel request' : addLabel}
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
        {isPendingSent ? 'Requested' : addLabel}
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
    color: '#fdfbf7',
  },
});
