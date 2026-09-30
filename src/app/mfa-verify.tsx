import { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  TextInput,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import { listTotpFactors, verifyTotpCode } from '@/lib/mfa';
import { supabase } from '@/lib/supabase';

// Shown right after signing in when the account has two-step verification
// on. Nothing else in the app is reachable until a code is entered, so a
// stolen password alone isn't enough (security item H4).
export default function MfaVerifyScreen() {
  const theme = useTheme();
  const { refreshMfa } = useAuth();
  const [factorId, setFactorId] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [isVerifying, setIsVerifying] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    listTotpFactors()
      .then((factors) => setFactorId(factors[0]?.id ?? null))
      .catch(() => setError("Couldn't load your two-step settings. Check your connection."));
  }, []);

  const canSubmit = factorId !== null && /^\d{6}$/.test(code.trim()) && !isVerifying;

  async function handleVerify() {
    if (!factorId || !canSubmit) return;
    setError(null);
    setIsVerifying(true);
    try {
      const result = await verifyTotpCode(factorId, code);
      if (result === 'ok') {
        // The auth provider also hears MFA_CHALLENGE_VERIFIED; this just
        // makes sure the gate lifts straight away.
        await refreshMfa();
        return;
      }
      setError("That code didn't work. Check the newest code in your authenticator app.");
      setCode('');
    } catch {
      setError('Something went wrong. Check your connection and try again.');
    } finally {
      setIsVerifying(false);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.container}>
        <ScrollView
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
          automaticallyAdjustKeyboardInsets={Platform.OS === 'ios'}>
          <ThemedText type="subtitle" accessibilityRole="header">
            Enter your code
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary">
            Two-step verification is on for this account. Open your authenticator app and enter the
            6-digit code for Bolas.
          </ThemedText>

          <TextInput
            value={code}
            onChangeText={(text) => setCode(text.replace(/\D/g, '').slice(0, 6))}
            placeholder="123456"
            placeholderTextColor={theme.textSecondary}
            keyboardType="number-pad"
            textContentType="oneTimeCode"
            autoComplete="one-time-code"
            autoFocus
            maxLength={6}
            onSubmitEditing={handleVerify}
            accessibilityLabel="6-digit code"
            style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
          />

          {error ? (
            <ThemedText type="small" themeColor="error" accessibilityLiveRegion="polite">
              {error}
            </ThemedText>
          ) : null}

          <Pressable
            onPress={handleVerify}
            disabled={!canSubmit}
            accessibilityRole="button"
            accessibilityLabel="Verify"
            accessibilityState={{ disabled: !canSubmit, busy: isVerifying }}
            style={({ pressed }) => [
              styles.button,
              { opacity: canSubmit ? 1 : 0.5 },
              pressed && styles.pressed,
            ]}>
            {isVerifying ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Verify
              </ThemedText>
            )}
          </Pressable>

          <ThemedText type="small" themeColor="textSecondary">
            Lost your authenticator app? Contact support from the email on your account and
            we&apos;ll help you get back in.
          </ThemedText>

          <Pressable
            onPress={() => supabase.auth.signOut()}
            hitSlop={Spacing.three}
            accessibilityRole="button"
            accessibilityLabel="Log out"
            style={styles.logout}>
            <ThemedText type="small" themeColor="textSecondary" style={styles.underline}>
              Log out
            </ThemedText>
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
  content: {
    flexGrow: 1,
    justifyContent: 'center',
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    padding: Spacing.four,
    gap: Spacing.three,
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 24,
    letterSpacing: 6,
    textAlign: 'center',
  },
  button: {
    minHeight: 48,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: AccentColor,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
  logout: {
    alignSelf: 'center',
  },
  underline: {
    textDecorationLine: 'underline',
  },
});
