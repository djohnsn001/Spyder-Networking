import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { AppState, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { MatchCard } from '@/components/connect/match-card';
import { MyCodePanel } from '@/components/connect/my-code-panel';
import { ScanPanel } from '@/components/connect/scan-panel';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { MaxContentWidth, Spacing } from '@/constants/theme';
import type { InPersonMatch } from '@/lib/connect/api';
import { useConnectLocation } from '@/lib/connect/use-connect-location';

type Tab = 'tap' | 'code' | 'scan';

const TABS: { key: Tab; label: string }[] = [
  { key: 'tap', label: 'Tap' },
  { key: 'code', label: 'My code' },
  { key: 'scan', label: 'Scan' },
];

function isTab(value: unknown): value is Tab {
  return value === 'tap' || value === 'code' || value === 'scan';
}

export default function ConnectScreen() {
  const params = useLocalSearchParams<{ tab?: string }>();
  const [tab, setTab] = useState<Tab>(isTab(params.tab) ? params.tab : 'code');
  const [match, setMatch] = useState<InPersonMatch | null>(null);

  // Camera, location and polling only run while this screen is on top and
  // the app is in the foreground.
  const [isFocused, setIsFocused] = useState(false);
  const [isForeground, setIsForeground] = useState(AppState.currentState === 'active');
  useFocusEffect(
    useCallback(() => {
      setIsFocused(true);
      return () => setIsFocused(false);
    }, []),
  );
  useEffect(() => {
    const subscription = AppState.addEventListener('change', (state) =>
      setIsForeground(state === 'active'),
    );
    return () => subscription.remove();
  }, []);
  const isLive = isFocused && isForeground;

  const location = useConnectLocation({ active: isLive, watch: tab === 'tap' });

  const handleMatched = useCallback((next: InPersonMatch) => setMatch(next), []);

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.header}>
          <ThemedText type="smallBold" style={styles.headerTitle}>
            Connect in person
          </ThemedText>
          <Pressable
            onPress={() => router.back()}
            accessibilityRole="button"
            accessibilityLabel="Close"
            hitSlop={12}
            style={({ pressed }) => pressed && styles.pressed}>
            <ThemedText type="smallBold" themeColor="textSecondary">
              Close
            </ThemedText>
          </Pressable>
        </View>

        <ThemedView type="backgroundElement" style={styles.segmented}>
          {TABS.map(({ key, label }) => {
            const selected = key === tab;
            return (
              <Pressable
                key={key}
                onPress={() => setTab(key)}
                accessibilityRole="tab"
                accessibilityState={{ selected }}
                accessibilityLabel={label}
                style={styles.segment}>
                <ThemedView
                  type={selected ? 'backgroundSelected' : 'backgroundElement'}
                  style={styles.segmentInner}>
                  <ThemedText
                    type="smallBold"
                    themeColor={selected ? 'text' : 'textSecondary'}>
                    {label}
                  </ThemedText>
                </ThemedView>
              </Pressable>
            );
          })}
        </ThemedView>

        <ScrollView contentContainerStyle={styles.body}>
          {tab === 'tap' ? (
            <View style={styles.tapPlaceholder}>
              <ThemedText type="smallBold" style={styles.center}>
                Tapping phones is almost ready
              </ThemedText>
              <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
                For now, show your code or scan theirs.
              </ThemedText>
            </View>
          ) : null}
          {tab === 'code' ? (
            <MyCodePanel active={isLive && !match} onMatched={handleMatched} />
          ) : null}
          {tab === 'scan' ? (
            <ScanPanel active={isLive && !match} city={location.city} onMatched={handleMatched} />
          ) : null}
        </ScrollView>
      </SafeAreaView>

      {match ? <MatchCard match={match} onDone={() => setMatch(null)} /> : null}
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
    width: '100%',
    maxWidth: MaxContentWidth,
    alignSelf: 'center',
    paddingHorizontal: Spacing.four,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: Spacing.three,
  },
  headerTitle: {
    fontSize: 18,
    lineHeight: 24,
  },
  segmented: {
    flexDirection: 'row',
    padding: Spacing.one,
    borderRadius: Spacing.four,
    gap: Spacing.one,
  },
  segment: {
    flex: 1,
  },
  segmentInner: {
    paddingVertical: Spacing.two,
    borderRadius: Spacing.three,
    alignItems: 'center',
  },
  body: {
    paddingVertical: Spacing.five,
    alignItems: 'center',
  },
  tapPlaceholder: {
    alignItems: 'center',
    gap: Spacing.two,
    paddingVertical: Spacing.five,
  },
  center: {
    textAlign: 'center',
  },
  pressed: {
    opacity: 0.7,
  },
});
