import { router } from 'expo-router';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, MaxContentWidth, Spacing } from '@/constants/theme';

// Placeholder upsell until in-app purchase exists. Premium itself is
// profiles.is_premium, which only the server can set (20260930020000); the
// purchase flow will set it through a webhook. Nothing here unlocks anything.

const PERKS = [
  {
    title: 'Filter by Looking For tags',
    body: "Search Discover for exactly who's hiring, investing, or looking for a co-founder, combined with stage, interests and city.",
  },
];

export default function PremiumScreen() {
  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ScrollView contentContainerStyle={styles.scrollContent}>
          <ThemedView type="backgroundElement" style={styles.card}>
            <ThemedText type="subtitle" style={styles.centerText}>
              Bolas Premium
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              Coming soon.
            </ThemedText>

            <View style={styles.perks}>
              {PERKS.map((perk) => (
                <View key={perk.title} style={styles.perk}>
                  <ThemedText type="smallBold">{perk.title}</ThemedText>
                  <ThemedText type="small" themeColor="textSecondary">
                    {perk.body}
                  </ThemedText>
                </View>
              ))}
            </View>

            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              Everyone can still see Looking For tags on profiles and get &quot;Suggested for
              you&quot; matches in Discover for free.
            </ThemedText>

            <Pressable
              onPress={() => router.back()}
              accessibilityRole="button"
              accessibilityLabel="Close"
              style={({ pressed }) => [styles.button, pressed && styles.pressed]}>
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Got it
              </ThemedText>
            </Pressable>
          </ThemedView>
        </ScrollView>
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
  },
  scrollContent: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
  },
  card: {
    alignSelf: 'stretch',
    maxWidth: MaxContentWidth,
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    borderRadius: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
  perks: {
    gap: Spacing.three,
    marginVertical: Spacing.two,
  },
  perk: {
    gap: Spacing.one,
  },
  button: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    backgroundColor: AccentColor,
  },
  pressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
});
