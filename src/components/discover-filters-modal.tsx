import { useState } from 'react';
import { Modal, Pressable, ScrollView, StyleSheet, TextInput, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { BusinessStages, CityLimit, InterestOptions } from '@/lib/profile-options';
import { countActiveFilters, type DiscoverFilters, EMPTY_DISCOVER_FILTERS } from '@/lib/profiles';

type DiscoverFiltersModalProps = {
  visible: boolean;
  filters: DiscoverFilters;
  onClose: () => void;
  onApply: (filters: DiscoverFilters) => void;
};

function toggle<T>(list: T[], item: T) {
  return list.includes(item) ? list.filter((value) => value !== item) : [...list, item];
}

// Edits a draft copy; nothing changes on Discover until "Show results".
export function DiscoverFiltersModal({ visible, filters, onClose, onApply }: DiscoverFiltersModalProps) {
  const theme = useTheme();
  const [draft, setDraft] = useState(filters);
  const [wasVisible, setWasVisible] = useState(visible);

  // Each time it opens, start from the filters currently applied (adjusting
  // state during render, as React recommends, rather than in an effect).
  if (visible !== wasVisible) {
    setWasVisible(visible);
    if (visible) setDraft(filters);
  }

  const activeCount = countActiveFilters(draft);

  function renderPill(label: string, selected: boolean, onPress: () => void) {
    return (
      <Pressable
        key={label}
        onPress={onPress}
        accessibilityRole="button"
        accessibilityState={{ selected }}
        style={({ pressed }) => [
          styles.pill,
          { backgroundColor: selected ? theme.secondaryAccent : theme.backgroundSelected },
          pressed && styles.pressed,
        ]}>
        <ThemedText type="small" themeColor={selected ? 'onSecondaryAccent' : 'text'}>
          {label}
        </ThemedText>
      </Pressable>
    );
  }

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <View style={[styles.backdrop, { backgroundColor: theme.scrim }]}>
        <Pressable style={styles.dismissArea} onPress={onClose} accessibilityLabel="Close filters" />
        <ThemedView type="overlay" style={[styles.sheet, { borderColor: theme.overlayBorder }]}>
          <View style={styles.header}>
            <ThemedText type="smallBold">Filters</ThemedText>
            <Pressable
              onPress={() => setDraft(EMPTY_DISCOVER_FILTERS)}
              disabled={activeCount === 0}
              accessibilityRole="button"
              hitSlop={Spacing.two}>
              <ThemedText type="small" themeColor={activeCount === 0 ? 'textSecondary' : 'accentText'}>
                Clear all
              </ThemedText>
            </Pressable>
          </View>

          <ScrollView contentContainerStyle={styles.body} keyboardShouldPersistTaps="handled">
            <View style={styles.section}>
              <ThemedText type="smallBold">Business stage</ThemedText>
              <View style={styles.pillRow}>
                {BusinessStages.map((stage) =>
                  renderPill(stage.label, draft.stages.includes(stage.value), () =>
                    setDraft((current) => ({ ...current, stages: toggle(current.stages, stage.value) })),
                  ),
                )}
              </View>
            </View>

            <View style={styles.section}>
              <ThemedText type="smallBold">Interests</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                Shows people with any of the ones you pick.
              </ThemedText>
              <View style={styles.pillRow}>
                {InterestOptions.map((interest) =>
                  renderPill(interest, draft.interests.includes(interest), () =>
                    setDraft((current) => ({ ...current, interests: toggle(current.interests, interest) })),
                  ),
                )}
              </View>
            </View>

            <View style={styles.section}>
              <ThemedText type="smallBold">City</ThemedText>
              <TextInput
                value={draft.city}
                onChangeText={(city) => setDraft((current) => ({ ...current, city }))}
                placeholder="Any city"
                placeholderTextColor={theme.textSecondary}
                maxLength={CityLimit}
                autoCorrect={false}
                returnKeyType="done"
                style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
              />
            </View>
          </ScrollView>

          <Pressable
            onPress={() => onApply({ ...draft, city: draft.city.trim() })}
            accessibilityRole="button"
            style={({ pressed }) => [
              styles.applyButton,
              { backgroundColor: theme.accent },
              pressed && styles.pressed,
            ]}>
            <ThemedText type="smallBold" style={{ color: theme.onAccent }}>
              Show results
            </ThemedText>
          </Pressable>
        </ThemedView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
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
    maxHeight: '85%',
    paddingHorizontal: Spacing.four,
    paddingTop: Spacing.four,
    paddingBottom: Spacing.five,
    borderTopLeftRadius: Spacing.four,
    borderTopRightRadius: Spacing.four,
    borderWidth: BorderWidth.thin,
    borderBottomWidth: 0,
    gap: Spacing.three,
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  body: {
    gap: Spacing.four,
  },
  section: {
    gap: Spacing.two,
  },
  pillRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.two,
  },
  pill: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.four,
  },
  pressed: {
    opacity: 0.85,
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  applyButton: {
    paddingVertical: Spacing.three,
    alignItems: 'center',
    borderRadius: Spacing.three,
  },
});
