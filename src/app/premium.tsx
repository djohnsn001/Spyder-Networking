import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import { fetchSupporterSpotsRemaining } from '@/lib/badges';

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
  const theme = useTheme();
  const { profile } = useAuth();
  // Lifetime Supporter spots left (capped server-side). Null while loading.
  const [spotsLeft, setSpotsLeft] = useState<number | null>(null);

  useEffect(() => {
    fetchSupporterSpotsRemaining().then(setSpotsLeft, () => setSpotsLeft(null));
  }, []);

  const isSupporter = profile?.lifetime_premium ?? false;
  const soldOut = spotsLeft === 0;

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

            {/* Lifetime Supporter: capped, and hidden-in-effect once sold out
                (the server refuses more). No purchase flow yet. */}
            <ThemedView type="backgroundSelected" style={styles.supporterCard}>
              <ThemedText type="smallBold">💛 Lifetime Supporter</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                Premium for life, plus a numbered Supporter badge. Spots are limited and
                won&apos;t come back once they&apos;re gone.
              </ThemedText>
              {isSupporter ? (
                <ThemedText type="smallBold" style={{ color: theme.accentText }}>
                  You&apos;re a Supporter. Thank you!
                </ThemedText>
              ) : spotsLeft != null ? (
                <ThemedText type="smallBold" style={{ color: soldOut ? theme.textSecondary : theme.accentText }}>
                  {soldOut ? 'Sold out' : `${spotsLeft} spot${spotsLeft === 1 ? '' : 's'} left`}
                </ThemedText>
              ) : null}
              {!isSupporter ? (
                <View
                  accessibilityRole="button"
                  accessibilityState={{ disabled: true }}
                  style={[styles.lifetimeButton, { borderColor: theme.accentText }, styles.disabled]}>
                  <ThemedText type="smallBold" style={{ color: theme.accentText }}>
                    {soldOut ? 'Sold out' : 'Lifetime · Coming soon'}
                  </ThemedText>
                </View>
              ) : null}
            </ThemedView>

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
  supporterCard: {
    gap: Spacing.two,
    padding: Spacing.three,
    borderRadius: Spacing.three,
  },
  lifetimeButton: {
    alignItems: 'center',
    paddingVertical: Spacing.two,
    borderRadius: Spacing.three,
    borderWidth: 1,
  },
  disabled: {
    opacity: 0.6,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
});
