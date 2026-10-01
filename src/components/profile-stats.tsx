import { Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { Spacing } from '@/constants/theme';
import type { ProfileStats } from '@/lib/badges';

type ProfileStatsRowProps = {
  stats: ProfileStats | null;
  // Tapping the in-person count (e.g. to open your connections).
  onPressInPerson?: () => void;
};

type Cell = { key: string; value: number; label: string; accessibilityLabel: string; note?: string };

// The Instagram-style numbers row. In-person connections come first and
// biggest; acquaintances only appear on your own profile (the server sends
// null for anyone else's). Cells share the width equally and labels shrink
// to fit, so four stats still fit on a narrow phone.
export function ProfileStatsRow({ stats, onPressInPerson }: ProfileStatsRowProps) {
  if (!stats) return null;

  const cells: Cell[] = [
    {
      key: 'attended',
      value: stats.events_attended,
      label: 'Events attended',
      accessibilityLabel: `${stats.events_attended} events attended`,
    },
    {
      key: 'hosted',
      value: stats.events_hosted,
      label: 'Events hosted',
      accessibilityLabel: `${stats.events_hosted} events hosted`,
    },
  ];
  if (stats.acquaintances != null) {
    cells.push({
      key: 'acquaintances',
      value: stats.acquaintances,
      label: 'Acquaintances',
      note: 'Only you',
      accessibilityLabel: `${stats.acquaintances} acquaintances, visible only to you`,
    });
  }

  return (
    <View style={styles.row}>
      <Pressable
        onPress={onPressInPerson}
        disabled={!onPressInPerson}
        accessibilityRole={onPressInPerson ? 'button' : 'text'}
        accessibilityLabel={`${stats.in_person_connections} in-person connections`}
        style={({ pressed }) => [styles.cell, styles.primaryCell, pressed && styles.pressed]}>
        <ThemedText style={styles.primaryValue}>{stats.in_person_connections}</ThemedText>
        <ThemedText
          type="small"
          themeColor="textSecondary"
          style={styles.label}
          numberOfLines={2}
          adjustsFontSizeToFit
          minimumFontScale={0.8}>
          In-person connections
        </ThemedText>
      </Pressable>

      {cells.map((cell) => (
        <View key={cell.key} style={styles.cell} accessible accessibilityLabel={cell.accessibilityLabel}>
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
          {cell.note ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.note}>
              {cell.note}
            </ThemedText>
          ) : null}
        </View>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
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
    // Lines up the smaller numbers with the big one's baseline area.
    paddingTop: 6,
  },
  primaryCell: {
    // A little more room for the most prominent stat.
    flex: 1.3,
    paddingTop: 0,
  },
  primaryValue: {
    fontSize: 30,
    lineHeight: 36,
    fontWeight: 700,
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
  note: {
    fontSize: 10,
    lineHeight: 14,
  },
  pressed: {
    opacity: 0.8,
  },
});
