import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, ErrorColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import {
  REPORT_DETAILS_LIMIT,
  REPORT_REASONS,
  reportEvent,
  type ReportReason,
} from '@/lib/events';
import { friendlyRpcError } from '@/lib/rpc';

// Opened from the "⋯" menu on an event. A regular modal rather than part of
// the detail sheet, which sizes itself to its content and shouldn't grow a
// form. The reporter only ever hears "Thanks, we'll take a look" — never
// whether their report hid the event.
export default function ReportEventScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const theme = useTheme();
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [details, setDetails] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function handleSubmit() {
    if (!reason || isSubmitting) return;
    setError(null);
    setIsSubmitting(true);
    try {
      const result = await reportEvent(id, reason, details);
      if (result === 'reported' || result === 'already_reported') {
        setDone(true);
      } else if (result === 'rate_limited') {
        setError("You've sent a lot of reports today. Try again tomorrow.");
      } else {
        setError("This event can't be reported right now.");
      }
    } catch (err) {
      setError(friendlyRpcError(err));
    } finally {
      setIsSubmitting(false);
    }
  }

  if (done) {
    return (
      <ThemedView style={styles.centered}>
        <ThemedText type="subtitle" style={styles.centerText}>
          Thanks, we'll take a look.
        </ThemedText>
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          Reports are private. The host isn't told who reported their event.
        </ThemedText>
        <Pressable
          onPress={() => router.back()}
          accessibilityRole="button"
          style={({ pressed }) => [styles.button, styles.doneButton, pressed && styles.pressed]}>
          <ThemedText type="smallBold" style={styles.buttonLabel}>
            Done
          </ThemedText>
        </Pressable>
      </ThemedView>
    );
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.container}>
        <ScrollView
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
          automaticallyAdjustKeyboardInsets={Platform.OS === 'ios'}>
          <View style={styles.header}>
            <ThemedText type="subtitle" style={styles.heading}>
              Report event
            </ThemedText>
            <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel="Cancel">
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </View>

          <ThemedText type="smallBold">What's wrong with it?</ThemedText>
          <View style={styles.reasons}>
            {REPORT_REASONS.map((option) => {
              const selected = reason === option.value;
              return (
                <Pressable
                  key={option.value}
                  onPress={() => setReason(option.value)}
                  accessibilityRole="radio"
                  accessibilityState={{ selected }}
                  style={({ pressed }) => [
                    styles.reason,
                    { backgroundColor: selected ? AccentColor : theme.backgroundSelected },
                    pressed && styles.pressed,
                  ]}>
                  <ThemedText
                    type="default"
                    style={selected ? styles.buttonLabel : undefined}
                    themeColor={selected ? undefined : 'text'}>
                    {option.label}
                  </ThemedText>
                </Pressable>
              );
            })}
          </View>

          <View style={styles.field}>
            <View style={styles.fieldHeaderRow}>
              <ThemedText type="smallBold">Details (optional)</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                {details.length}/{REPORT_DETAILS_LIMIT}
              </ThemedText>
            </View>
            <TextInput
              value={details}
              onChangeText={(text) => setDetails(text.slice(0, REPORT_DETAILS_LIMIT))}
              placeholder="Anything that helps us understand"
              placeholderTextColor={theme.textSecondary}
              multiline
              numberOfLines={4}
              style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
              accessibilityLabel="Details"
            />
          </View>

          {error ? (
            <ThemedText type="small" style={styles.errorText}>
              {error}
            </ThemedText>
          ) : null}

          <Pressable
            onPress={handleSubmit}
            disabled={!reason || isSubmitting}
            accessibilityRole="button"
            accessibilityLabel="Send report"
            style={({ pressed }) => [
              styles.button,
              { opacity: !reason || isSubmitting ? 0.5 : 1 },
              pressed && styles.pressed,
            ]}>
            {isSubmitting ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Send report
              </ThemedText>
            )}
          </Pressable>
        </ScrollView>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.three,
    padding: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
  content: {
    gap: Spacing.three,
    padding: Spacing.four,
    paddingBottom: Spacing.six,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  heading: {
    fontSize: 26,
    lineHeight: 34,
  },
  reasons: {
    gap: Spacing.two,
  },
  reason: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
  },
  field: {
    gap: Spacing.two,
  },
  fieldHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  input: {
    minHeight: 96,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
    textAlignVertical: 'top',
  },
  errorText: {
    color: ErrorColor,
    textAlign: 'center',
  },
  button: {
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    backgroundColor: AccentColor,
  },
  doneButton: {
    alignSelf: 'stretch',
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
});
