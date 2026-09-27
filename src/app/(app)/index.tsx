import { router } from 'expo-router';
import { Pressable, StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';

export default function HomeScreen() {
  const { session, profile } = useAuth();
  const name = profile?.full_name || profile?.username || session?.user.email || '';

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ThemedText type="subtitle" style={styles.centerText}>
          Welcome, {name}
        </ThemedText>
        <Pressable
          onPress={() => router.push('/connect')}
          accessibilityRole="button"
          accessibilityLabel="Connect in person"
          style={({ pressed }) => [styles.connectButton, pressed && styles.pressed]}>
          <ThemedText type="smallBold" style={styles.connectLabel}>
            Connect in person
          </ThemedText>
        </Pressable>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    flexDirection: 'row',
  },
  safeArea: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
    paddingBottom: BottomTabInset + Spacing.three,
    maxWidth: MaxContentWidth,
  },
  centerText: {
    textAlign: 'center',
  },
  connectButton: {
    marginTop: Spacing.four,
    paddingVertical: Spacing.three,
    paddingHorizontal: Spacing.five,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
  },
  connectLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
});
