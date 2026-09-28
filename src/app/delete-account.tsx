import { useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
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
import { DangerColor, ErrorColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { clearAfterAccountDeletion, deleteMyAccount } from '@/lib/account';
import { useAuth } from '@/lib/auth';

const DELETED = [
  'Your profile, photos, and settings',
  'Your connections and connection requests',
  'Your chats — they disappear for the other person too',
  'Events you host, and your RSVPs',
  'Your map location, blocks, and any QR codes or taps',
];

// Settings → Delete account. Apple requires this to be easy to find and to
// really delete the account (Guideline 5.1.1(v)).
export default function DeleteAccountScreen() {
  const theme = useTheme();
  const { session, profile } = useAuth();
  // Someone who never finished profile setup types DELETE instead.
  const expected = profile?.username ?? 'DELETE';
  const [confirm, setConfirm] = useState('');
  const [isDeleting, setIsDeleting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const matches = confirm.trim().toLowerCase() === expected.toLowerCase();

  async function handleDelete() {
    if (!session || !matches) return;
    setErrorMessage(null);
    setIsDeleting(true);
    const result = await deleteMyAccount(confirm.trim());
    if (result === 'deleted') {
      // Signing out swaps the whole app for the login screen, which shows
      // "Your account was deleted."
      await clearAfterAccountDeletion(session.user.id);
      return;
    }
    setIsDeleting(false);
    setErrorMessage(
      result === 'confirm_mismatch'
        ? "That doesn't match your username."
        : result === 'offline'
          ? "Couldn't reach Bolas. Check your connection and try again."
          : 'Something went wrong, and your account was not deleted. Please try again.',
    );
  }

  return (
    <ThemedView style={styles.container}>
      <KeyboardAvoidingView
        style={styles.container}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <SafeAreaView style={styles.container} edges={['bottom', 'left', 'right']}>
          <ScrollView
            contentContainerStyle={styles.content}
            keyboardShouldPersistTaps="handled">
            <ThemedText type="subtitle" accessibilityRole="header">
              Delete your account
            </ThemedText>

            <ThemedView type="backgroundElement" style={styles.card}>
              <ThemedText type="smallBold">This permanently deletes:</ThemedText>
              {DELETED.map((item) => (
                <View key={item} style={styles.bulletRow}>
                  <ThemedText type="small" themeColor="textSecondary">
                    •
                  </ThemedText>
                  <ThemedText type="small" themeColor="textSecondary" style={styles.bulletText}>
                    {item}
                  </ThemedText>
                </View>
              ))}
            </ThemedView>

            <ThemedView type="backgroundElement" style={styles.card}>
              <ThemedText type="smallBold">What we keep</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                Safety reports you made, or that were made about you, are kept so we can keep the
                community safe. They&apos;re no longer linked to your account, but a report can
                include a copy of the profile or message that was reported.
              </ThemedText>
            </ThemedView>

            <ThemedText type="smallBold" style={{ color: DangerColor }}>
              This can&apos;t be undone.
            </ThemedText>

            <View style={styles.field}>
              <ThemedText type="small" themeColor="textSecondary" nativeID="confirm-label">
                {profile?.username
                  ? `Type your username (${profile.username}) to confirm`
                  : 'Type DELETE to confirm'}
              </ThemedText>
              <TextInput
                value={confirm}
                onChangeText={setConfirm}
                placeholder={expected}
                placeholderTextColor={theme.textSecondary}
                autoCapitalize="none"
                autoCorrect={false}
                editable={!isDeleting}
                accessibilityLabelledBy="confirm-label"
                accessibilityLabel="Confirm by typing your username"
                style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
              />
            </View>

            {errorMessage ? (
              <ThemedText type="small" style={styles.errorText} accessibilityLiveRegion="polite">
                {errorMessage}
              </ThemedText>
            ) : null}

            <Pressable
              onPress={handleDelete}
              disabled={!matches || isDeleting}
              accessibilityRole="button"
              accessibilityLabel="Delete my account"
              accessibilityState={{ disabled: !matches || isDeleting, busy: isDeleting }}
              style={({ pressed }) => [
                styles.button,
                { backgroundColor: DangerColor, opacity: !matches || isDeleting ? 0.5 : 1 },
                pressed && matches && styles.buttonPressed,
              ]}>
              {isDeleting ? (
                <ActivityIndicator color="#fdfbf7" />
              ) : (
                <ThemedText type="smallBold" style={styles.buttonLabel}>
                  Delete my account
                </ThemedText>
              )}
            </Pressable>
          </ScrollView>
        </SafeAreaView>
      </KeyboardAvoidingView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    padding: Spacing.four,
    gap: Spacing.three,
  },
  card: {
    padding: Spacing.three,
    borderRadius: Spacing.three,
    gap: Spacing.one,
  },
  bulletRow: {
    flexDirection: 'row',
    gap: Spacing.two,
  },
  bulletText: {
    flex: 1,
  },
  field: {
    gap: Spacing.one,
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  errorText: {
    color: ErrorColor,
  },
  button: {
    minHeight: 48,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
});
