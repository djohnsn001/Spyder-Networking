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
import { AccentColor, DangerColor, ErrorColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { LEGAL } from '@/lib/legal/config';
import { friendlyRpcError } from '@/lib/rpc';
import {
  confirmBlock,
  reportUser,
  USER_REPORT_DETAILS_LIMIT,
  USER_REPORT_REASONS,
  type UserReportContext,
  type UserReportReason,
} from '@/lib/safety';

const HEADINGS: Record<UserReportContext, string> = {
  profile: 'Report profile',
  message: 'Report message',
  in_person: 'Report someone you met',
  other: 'Report',
};

// Opened from a profile's "⋯" menu, a long-pressed chat message, or the
// in-person match card. The server copies the profile / message at report
// time, so later edits or deletions can't erase the evidence.
export default function ReportUserScreen() {
  const params = useLocalSearchParams<{
    userId: string;
    context?: UserReportContext;
    contextId?: string;
    name?: string;
  }>();
  const context: UserReportContext = params.context ?? 'profile';
  const name = params.name || 'this person';
  const theme = useTheme();
  const [reason, setReason] = useState<UserReportReason | null>(null);
  const [details, setDetails] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function handleSubmit() {
    if (!reason || isSubmitting) return;
    setError(null);
    setIsSubmitting(true);
    try {
      const result = await reportUser({
        userId: params.userId,
        context,
        contextId: params.contextId,
        reason,
        details,
      });
      if (result === 'reported') {
        setDone(true);
      } else if (result === 'rate_limited') {
        setError("You've sent a lot of reports today. Try again tomorrow.");
      } else {
        // not_found / not_allowed / invalid: never say more than this.
        setError("This can't be reported right now.");
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
        <ThemedText type="subtitle" style={styles.centerText} accessibilityRole="header">
          Thanks for telling us.
        </ThemedText>
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          We&apos;ll review this {LEGAL.REPORT_REVIEW_PROMISE}. Reports are private: {name} isn&apos;t
          told who reported them.
        </ThemedText>
        {context === 'in_person' ? (
          <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
            If you&apos;re in danger, call 911.
          </ThemedText>
        ) : null}
        <Pressable
          onPress={() => confirmBlock(name, params.userId)}
          accessibilityRole="button"
          accessibilityLabel={`Block ${name} too`}
          style={({ pressed }) => [styles.button, styles.blockButton, pressed && styles.pressed]}>
          <ThemedText type="smallBold" style={styles.buttonLabel}>
            Block {name} too
          </ThemedText>
        </Pressable>
        <Pressable
          onPress={() => router.back()}
          accessibilityRole="button"
          accessibilityLabel="Done"
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
            <ThemedText type="subtitle" style={styles.heading} accessibilityRole="header">
              {HEADINGS[context]}
            </ThemedText>
            <Pressable
              onPress={() => router.back()}
              hitSlop={Spacing.two}
              accessibilityRole="button"
              accessibilityLabel="Cancel">
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </View>

          <ThemedText type="smallBold">What&apos;s going on?</ThemedText>
          <View style={styles.reasons} accessibilityRole="radiogroup">
            {USER_REPORT_REASONS.map((option) => {
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
                {details.length}/{USER_REPORT_DETAILS_LIMIT}
              </ThemedText>
            </View>
            <TextInput
              value={details}
              onChangeText={(text) => setDetails(text.slice(0, USER_REPORT_DETAILS_LIMIT))}
              placeholder="Anything that helps us understand"
              placeholderTextColor={theme.textSecondary}
              multiline
              numberOfLines={4}
              style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
              accessibilityLabel="Details"
            />
          </View>

          {error ? (
            <ThemedText type="small" style={styles.errorText} accessibilityLiveRegion="polite">
              {error}
            </ThemedText>
          ) : null}

          <Pressable
            onPress={handleSubmit}
            disabled={!reason || isSubmitting}
            accessibilityRole="button"
            accessibilityLabel="Send report"
            accessibilityState={{ disabled: !reason || isSubmitting, busy: isSubmitting }}
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
    flexShrink: 1,
  },
  reasons: {
    gap: Spacing.two,
  },
  reason: {
    minHeight: 48,
    justifyContent: 'center',
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
    minHeight: 48,
    justifyContent: 'center',
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    backgroundColor: AccentColor,
  },
  blockButton: {
    alignSelf: 'stretch',
    backgroundColor: DangerColor,
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
