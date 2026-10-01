import { Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { badgeLabel, type BadgeDefinition, type EarnedBadge } from '@/lib/badges';

type BadgeChipProps = {
  definition: BadgeDefinition | undefined;
  badge: EarnedBadge;
  // Featured badges at the top of a profile are drawn larger.
  size?: 'small' | 'large';
  onPress?: () => void;
};

// One badge. The look comes from its style in the badge config:
//   founder      clay fill with a ring: the most prestigious
//   early_member navy tint
//   supporter    outlined, understated: supporting the app, not a rank
//   milestone    neutral
export function BadgeChip({ definition, badge, size = 'small', onPress }: BadgeChipProps) {
  const theme = useTheme();
  const style = definition?.style ?? 'milestone';
  const large = size === 'large';

  const colors = {
    founder: { background: theme.accent, border: theme.text, text: theme.onAccent },
    early_member: { background: theme.secondaryAccentSoft, border: theme.secondaryAccentSoft, text: theme.secondaryAccent },
    supporter: { background: 'transparent', border: theme.accentText, text: theme.accentText },
    milestone: { background: theme.backgroundSelected, border: theme.backgroundSelected, text: theme.text },
  }[style];

  const label = badgeLabel(definition, badge);

  return (
    <Pressable
      onPress={onPress}
      disabled={!onPress}
      accessibilityRole={onPress ? 'button' : 'text'}
      accessibilityLabel={`${label} badge`}
      style={({ pressed }) => [pressed && styles.pressed]}>
      <View
        style={[
          styles.chip,
          large && styles.chipLarge,
          style === 'founder' && styles.founder,
          { backgroundColor: colors.background, borderColor: colors.border },
        ]}>
        <ThemedText type="small" style={large ? styles.iconLarge : styles.icon}>
          {definition?.icon ?? '🏅'}
        </ThemedText>
        <ThemedText
          type={style === 'founder' || large ? 'smallBold' : 'small'}
          style={[{ color: colors.text }, large && styles.labelLarge]}>
          {label}
        </ThemedText>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.one,
    paddingHorizontal: Spacing.two,
    paddingVertical: 4,
    borderRadius: Spacing.five,
    borderWidth: 1,
  },
  chipLarge: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.one,
  },
  founder: {
    borderWidth: 2,
  },
  icon: {
    fontSize: 13,
    lineHeight: 18,
  },
  iconLarge: {
    fontSize: 16,
    lineHeight: 22,
  },
  labelLarge: {
    fontSize: 15,
  },
  pressed: {
    opacity: 0.8,
  },
});
