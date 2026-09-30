import { Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { Spacing } from '@/constants/theme';
import type { ProfileStats } from '@/lib/badges';

type ProfileStatsRowProps = {
  stats: ProfileStats | null;
  // Tapping the in-person count (e.g. to open your connections).
  onPressInPerson?: () => void;
};

// The Instagram-style numbers row. In-person connections come first and
// biggest; acquaintances only appear on your own profile (the server sends
// null for anyone else's).
export function ProfileStatsRow({ stats, onPressInPerson }: ProfileStatsRowProps) {
  if (!stats) return null;

  const cells: { key: string; value: number; label: string; note?: string }[] = [
    { key: 'attended', value: stats.events_attended, label: 'Events\nattended' },
    { key: 'hosted', value: stats.events_hosted, label: 'Events\nhosted' },
  ];
  if (stats.acquaintances != null) {
    cells.push({ key: 'acq', value: stats.acquaintances, label: 'Acquain-\ntances', note: 'Only you' });
  }

  return (
    <View style={styles.row}>
      <Pressable
        onPress={onPressInPerson}
        disabled={!onPressInPerson}
        accessibilityRole={onPressInPerson ? 'button' : 'text'}
        accessibilityLabel={`${stats.in_person_connections} in-person connections`}
        style={({ pressed }) => [styles.primaryCell, pressed && styles.pressed]}>
        <ThemedText style={styles.primaryValue}>{stats.in_person_connections}</ThemedText>
        <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
          In-person{'\n'}connections
        </ThemedText>
      </Pressable>

      {cells.map((cell) => (
        <View
          key={cell.key}
          style={styles.cell}
          accessible
          accessibilityLabel={`${cell.value} ${cell.label.replace('\n', ' ').replace('-', '')}${cell.note ? ', visible only to you' : ''}`}>
          <ThemedText style={styles.value}>{cell.value}</ThemedText>
          <ThemedText type="small" themeColor="textSecondary" style={[styles.center, styles.label]}>
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
    justifyContent: 'center',
    alignSelf: 'stretch',
    gap: Spacing.three,
  },
  primaryCell: {
    alignItems: 'center',
    minWidth: 88,
  },
  primaryValue: {
    fontSize: 30,
    lineHeight: 36,
    fontWeight: 700,
  },
  cell: {
    alignItems: 'center',
    minWidth: 64,
    paddingTop: 6,
  },
  value: {
    fontSize: 20,
    lineHeight: 26,
    fontWeight: 600,
  },
  label: {
    fontSize: 12,
    lineHeight: 16,
  },
  note: {
    fontSize: 10,
    lineHeight: 14,
  },
  center: {
    textAlign: 'center',
  },
  pressed: {
    opacity: 0.8,
  },
});
