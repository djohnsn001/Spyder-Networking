import { Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { Spacing } from '@/constants/theme';
import type { ProfileStats } from '@/lib/badges';

type ProfileStatsRowProps = {
  stats: ProfileStats | null;
  // Tapping the in-person count (e.g. to open your connections).
  onPressInPerson?: () => void;
};

// spoken: what a screen reader says after the number (the short labels need
// context out loud).
type Cell = { key: string; value: number; label: string; spoken: string };

// The Instagram-style numbers row: three equal stats, evenly centered.
// Acquaintances only exist on your own profile (the server sends null for
// anyone else's) and get a smaller line underneath. Labels shrink to fit on
// a narrow phone.
export function ProfileStatsRow({ stats, onPressInPerson }: ProfileStatsRowProps) {
  if (!stats) return null;

  const cells: Cell[] = [
    // "Ties": people you've met in person (the lines on the Web Map).
    {
      key: 'in_person',
      value: stats.in_person_connections,
      label: 'Ties',
      spoken: 'ties, people met in person',
    },
    { key: 'attended', value: stats.events_attended, label: 'Attended', spoken: 'events attended' },
    { key: 'hosted', value: stats.events_hosted, label: 'Hosted', spoken: 'events hosted' },
  ];

  return (
    <View style={styles.container}>
      <View style={styles.row}>
        {cells.map((cell) => {
          const pressable = cell.key === 'in_person' && !!onPressInPerson;
          return (
            <Pressable
              key={cell.key}
              onPress={pressable ? onPressInPerson : undefined}
              disabled={!pressable}
              accessibilityRole={pressable ? 'button' : 'text'}
              accessibilityLabel={`${cell.value} ${cell.spoken}`}
              style={({ pressed }) => [styles.cell, pressed && styles.pressed]}>
              <ThemedText style={styles.value}>{cell.value}</ThemedText>
              <ThemedText
                type="small"
                themeColor="textSecondary"
                style={styles.label}
                numberOfLines={2}
                adjustsFontSizeToFit
                minimumFontScale={0.75}>
                {cell.label}
              </ThemedText>
            </Pressable>
          );
        })}
      </View>

      {stats.acquaintances != null ? (
        <ThemedText
          type="small"
          themeColor="textSecondary"
          style={styles.acquaintances}
          numberOfLines={1}
          adjustsFontSizeToFit
          minimumFontScale={0.8}
          accessibilityLabel={`${stats.acquaintances} acquaintances, visible only to you`}>
          {stats.acquaintances} {stats.acquaintances === 1 ? 'acquaintance' : 'acquaintances'} · Only
          you can see this
        </ThemedText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignSelf: 'stretch',
    alignItems: 'center',
    gap: Spacing.one,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    alignSelf: 'stretch',
    gap: Spacing.two,
  },
  cell: {
    flex: 1,
    minWidth: 0,
    alignItems: 'center',
  },
  value: {
    fontSize: 20,
    lineHeight: 26,
    fontWeight: 600,
  },
  label: {
    fontSize: 12,
    lineHeight: 16,
    textAlign: 'center',
  },
  acquaintances: {
    fontSize: 12,
    lineHeight: 16,
    textAlign: 'center',
  },
  pressed: {
    opacity: 0.8,
  },
});
