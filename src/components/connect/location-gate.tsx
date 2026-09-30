import { ActivityIndicator, Linking, Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { AccentColor, Spacing } from '@/constants/theme';
import type { ConnectLocation } from '@/lib/connect/use-connect-location';

// Shown on the Tap, My code and Scan tabs until location is allowed. Every
// way of connecting in person needs it: the server only connects two phones
// that are together (security item H2). Returns null once it's granted.
export function LocationGate({
  location,
  title,
}: {
  location: ConnectLocation;
  // What this tab does, e.g. "Show your code".
  title: string;
}) {
  if (location.status === 'granted') return null;

  if (location.status === 'checking') {
    return (
      <View style={styles.centered}>
        <ActivityIndicator color={AccentColor} />
      </View>
    );
  }

  const canAsk = location.status === 'undetermined' && location.canAskAgain;
  return (
    <View style={styles.centered}>
      <ThemedText type="smallBold" style={styles.center}>
        {canAsk ? title : 'Connecting needs your location'}
      </ThemedText>
      <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
        {canAsk
          ? "Bolas checks you're really with the person you're connecting with, using your location only while this screen is open. Only the city you met in is kept."
          : 'Bolas uses your location to check you and the other person are together. Turn it on in Settings to connect in person.'}
      </ThemedText>
      <Pressable
        onPress={() => (canAsk ? location.requestPermission() : Linking.openSettings())}
        accessibilityRole="button"
        accessibilityLabel={canAsk ? 'Turn on location' : 'Open Settings'}
        style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
        <ThemedText type="smallBold" style={styles.primaryLabel}>
          {canAsk ? 'Turn on location' : 'Open Settings'}
        </ThemedText>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  centered: {
    alignItems: 'center',
    gap: Spacing.three,
    paddingVertical: Spacing.five,
    maxWidth: 360,
  },
  center: {
    textAlign: 'center',
  },
  primaryButton: {
    minHeight: 44,
    justifyContent: 'center',
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
