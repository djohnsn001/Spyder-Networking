import { StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { formatTagsUpdatedAgo, getLookingForLabel, normalizeLookingFor } from '@/lib/looking-for';

type LookingForTagsProps = {
  tags: readonly string[] | null | undefined;
  updatedAt: string | null | undefined;
  // Profile pages center everything; cards are left-aligned.
  align?: 'center' | 'start';
  // Cards skip the "Looking for" heading and keep it to one line.
  compact?: boolean;
};

// A person's Looking For tags with a subtle "updated X ago". Navy pills, so
// they read differently from interests (neutral pills). Renders nothing
// with no tags.
export function LookingForTags({ tags, updatedAt, align = 'center', compact = false }: LookingForTagsProps) {
  const keys = normalizeLookingFor(tags);
  if (keys.length === 0) return null;
  const updated = formatTagsUpdatedAgo(updatedAt);
  const centered = align === 'center';

  return (
    <View style={[styles.container, centered ? styles.centered : styles.start]}>
      {!compact ? (
        <ThemedText type="smallBold" themeColor="textSecondary">
          Looking for
        </ThemedText>
      ) : null}
      <View style={[styles.pillRow, centered && styles.pillRowCentered]}>
        {keys.map((key) => (
          <ThemedView
            key={key}
            type="secondaryAccentSoft"
            style={[styles.pill, compact && styles.pillCompact]}>
            <ThemedText type="small" themeColor="secondaryAccent">
              {getLookingForLabel(key)}
            </ThemedText>
          </ThemedView>
        ))}
      </View>
      {updated ? (
        <ThemedText type="small" themeColor="textSecondary" style={styles.updated}>
          {updated}
        </ThemedText>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: Spacing.one,
  },
  centered: {
    alignItems: 'center',
    alignSelf: 'stretch',
  },
  start: {
    alignItems: 'flex-start',
  },
  pillRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.one,
  },
  pillRowCentered: {
    justifyContent: 'center',
  },
  pill: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.one,
    borderRadius: Spacing.five,
  },
  pillCompact: {
    paddingHorizontal: Spacing.two,
    paddingVertical: 2,
  },
  updated: {
    fontSize: 12,
    lineHeight: 16,
  },
});
