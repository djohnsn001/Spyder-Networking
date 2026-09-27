import { StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import { CONNECTION_LEVEL_LABEL, formatMet } from '@/lib/connect/labels';
import type { ConnectionLevel } from '@/lib/types';

// "Acquaintance", or "Map connection · Met Sep 27 · Boise".
export function LevelChip({
  level,
  metAt,
  metCity,
}: {
  level: ConnectionLevel;
  metAt?: string | null;
  metCity?: string | null;
}) {
  const met = level === 'in_person' ? formatMet(metAt ?? null, metCity ?? null) : null;

  if (level === 'in_person') {
    return (
      <View style={[styles.chip, styles.inPerson]}>
        <ThemedText type="small" style={styles.inPersonLabel}>
          {[CONNECTION_LEVEL_LABEL.in_person, met].filter(Boolean).join(' · ')}
        </ThemedText>
      </View>
    );
  }

  return (
    <ThemedView type="backgroundSelected" style={styles.chip}>
      <ThemedText type="small" themeColor="textSecondary">
        {CONNECTION_LEVEL_LABEL.acquaintance}
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  chip: {
    alignSelf: 'flex-start',
    paddingHorizontal: Spacing.two,
    paddingVertical: Spacing.half,
    borderRadius: Spacing.three,
  },
  inPerson: {
    backgroundColor: AccentColor,
  },
  inPersonLabel: {
    color: '#fdfbf7',
  },
});
