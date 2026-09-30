import { useCallback, useState } from 'react';
import { ActivityIndicator, Modal, Pressable, StyleSheet, View } from 'react-native';

import { BadgeChip } from '@/components/badge-chip';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import {
  type BadgeDefinition,
  badgeLabel,
  type EarnedBadge,
  FeaturedBadgeLimit,
  fetchBadgeDefinitions,
  fetchProfileBadges,
  formatEarnedDate,
  setFeaturedBadges,
} from '@/lib/badges';
import { friendlyRpcError } from '@/lib/rpc';

// A profile's badges plus the badge config. Screens call `reload` on focus
// (and after anything that might have changed them).
export function useProfileBadges(userId: string | undefined) {
  const [definitions, setDefinitions] = useState<Map<string, BadgeDefinition>>(new Map());
  const [badges, setBadges] = useState<EarnedBadge[]>([]);

  const reload = useCallback(async () => {
    if (!userId) return;
    try {
      const [defs, earned] = await Promise.all([fetchBadgeDefinitions(), fetchProfileBadges(userId)]);
      setDefinitions(defs);
      setBadges(earned);
    } catch (error) {
      if (__DEV__) console.warn('Failed to load badges', error);
    }
  }, [userId]);

  return { definitions, badges, reload };
}

function featuredOf(badges: EarnedBadge[]) {
  return badges
    .filter((badge) => badge.featured_rank != null)
    .sort((a, b) => (a.featured_rank ?? 0) - (b.featured_rank ?? 0));
}

// Up to 3 chosen badges, shown big near the top of the profile.
export function FeaturedBadges({
  definitions,
  badges,
  onPressBadge,
}: {
  definitions: Map<string, BadgeDefinition>;
  badges: EarnedBadge[];
  onPressBadge: (badge: EarnedBadge) => void;
}) {
  const featured = featuredOf(badges);
  if (featured.length === 0) return null;
  return (
    <View style={styles.featuredRow}>
      {featured.map((badge) => (
        <BadgeChip
          key={badge.badge_key}
          definition={definitions.get(badge.badge_key)}
          badge={badge}
          size="large"
          onPress={() => onPressBadge(badge)}
        />
      ))}
    </View>
  );
}

// Every badge, in config order, plus the detail sheet. On your own profile
// the sheet can also feature / unfeature a badge.
export function BadgesSection({
  definitions,
  badges,
  isOwn,
  selected,
  onSelect,
  onChanged,
}: {
  definitions: Map<string, BadgeDefinition>;
  badges: EarnedBadge[];
  isOwn: boolean;
  selected: EarnedBadge | null;
  onSelect: (badge: EarnedBadge | null) => void;
  onChanged: () => void;
}) {
  const ordered = [...badges].sort(
    (a, b) =>
      (definitions.get(a.badge_key)?.sort_order ?? 0) - (definitions.get(b.badge_key)?.sort_order ?? 0),
  );

  return (
    <>
      <View style={styles.section}>
        <View style={styles.sectionHeader}>
          <ThemedText type="smallBold">Badges</ThemedText>
          {isOwn && badges.length > 0 ? (
            <ThemedText type="small" themeColor="textSecondary">
              Tap one to feature it
            </ThemedText>
          ) : null}
        </View>
        {ordered.length === 0 ? (
          <ThemedText type="small" themeColor="textSecondary">
            {isOwn
              ? 'Meet people in person and check in to events to earn badges.'
              : 'No badges yet.'}
          </ThemedText>
        ) : (
          <View style={styles.grid}>
            {ordered.map((badge) => (
              <BadgeChip
                key={badge.badge_key}
                definition={definitions.get(badge.badge_key)}
                badge={badge}
                onPress={() => onSelect(badge)}
              />
            ))}
          </View>
        )}
      </View>

      <BadgeDetailSheet
        badge={selected}
        definition={selected ? definitions.get(selected.badge_key) : undefined}
        badges={badges}
        isOwn={isOwn}
        onClose={() => onSelect(null)}
        onChanged={onChanged}
      />
    </>
  );
}

function BadgeDetailSheet({
  badge,
  definition,
  badges,
  isOwn,
  onClose,
  onChanged,
}: {
  badge: EarnedBadge | null;
  definition: BadgeDefinition | undefined;
  badges: EarnedBadge[];
  isOwn: boolean;
  onClose: () => void;
  onChanged: () => void;
}) {
  const theme = useTheme();
  const [isSaving, setIsSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const featuredKeys = featuredOf(badges).map((b) => b.badge_key);
  const isFeatured = badge ? featuredKeys.includes(badge.badge_key) : false;
  const atLimit = !isFeatured && featuredKeys.length >= FeaturedBadgeLimit;

  async function toggleFeatured() {
    if (!badge) return;
    setError(null);
    setIsSaving(true);
    try {
      const next = isFeatured
        ? featuredKeys.filter((key) => key !== badge.badge_key)
        : [...featuredKeys, badge.badge_key];
      const outcome = await setFeaturedBadges(next);
      if (outcome !== 'ok') {
        setError(`You can feature up to ${FeaturedBadgeLimit} badges.`);
        return;
      }
      onChanged();
      onClose();
    } catch (err) {
      setError(friendlyRpcError(err));
    } finally {
      setIsSaving(false);
    }
  }

  return (
    <Modal visible={badge != null} transparent animationType="slide" onRequestClose={onClose}>
      <View style={[styles.backdrop, { backgroundColor: theme.scrim }]}>
        <Pressable style={styles.dismissArea} onPress={onClose} accessibilityLabel="Close badge" />
        {badge ? (
          <ThemedView type="overlay" style={[styles.sheet, { borderColor: theme.overlayBorder }]}>
            <ThemedText style={styles.bigIcon}>{definition?.icon ?? '🏅'}</ThemedText>
            <ThemedText type="subtitle" style={styles.center} accessibilityRole="header">
              {badgeLabel(definition, badge)}
            </ThemedText>
            {definition?.description ? (
              <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
                {definition.description}
              </ThemedText>
            ) : null}
            <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
              Earned {formatEarnedDate(badge.awarded_at)}
            </ThemedText>

            {isOwn ? (
              <>
                <Pressable
                  onPress={toggleFeatured}
                  disabled={isSaving || atLimit}
                  accessibilityRole="button"
                  accessibilityState={{ disabled: isSaving || atLimit }}
                  style={({ pressed }) => [
                    styles.button,
                    { backgroundColor: isFeatured ? theme.backgroundSelected : theme.accent },
                    (isSaving || atLimit) && styles.disabled,
                    pressed && styles.pressed,
                  ]}>
                  {isSaving ? (
                    <ActivityIndicator color={isFeatured ? theme.text : theme.onAccent} />
                  ) : (
                    <ThemedText
                      type="smallBold"
                      style={{ color: isFeatured ? theme.text : theme.onAccent }}>
                      {isFeatured ? 'Remove from profile top' : 'Feature at the top of my profile'}
                    </ThemedText>
                  )}
                </Pressable>
                {atLimit ? (
                  <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
                    You&apos;re featuring {FeaturedBadgeLimit} already. Remove one first.
                  </ThemedText>
                ) : null}
                {error ? (
                  <ThemedText type="small" themeColor="error" style={styles.center}>
                    {error}
                  </ThemedText>
                ) : null}
              </>
            ) : null}

            <Pressable onPress={onClose} accessibilityRole="button" hitSlop={Spacing.two}>
              <ThemedText type="smallBold" themeColor="textSecondary">
                Close
              </ThemedText>
            </Pressable>
          </ThemedView>
        ) : null}
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  featuredRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'center',
    gap: Spacing.two,
  },
  section: {
    alignSelf: 'stretch',
    gap: Spacing.two,
  },
  sectionHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  grid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.two,
  },
  backdrop: {
    flex: 1,
    justifyContent: 'flex-end',
  },
  dismissArea: {
    flex: 1,
  },
  sheet: {
    width: '100%',
    maxWidth: 600,
    alignSelf: 'center',
    alignItems: 'center',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingTop: Spacing.five,
    paddingBottom: Spacing.five,
    borderTopLeftRadius: Spacing.four,
    borderTopRightRadius: Spacing.four,
    borderWidth: BorderWidth.thin,
    borderBottomWidth: 0,
  },
  bigIcon: {
    fontSize: 48,
    lineHeight: 60,
  },
  center: {
    textAlign: 'center',
  },
  button: {
    alignSelf: 'stretch',
    minHeight: 48,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
  },
  disabled: {
    opacity: 0.6,
  },
  pressed: {
    opacity: 0.8,
  },
});
