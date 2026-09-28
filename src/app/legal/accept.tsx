import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ConsentCheckbox } from '@/components/legal/consent-checkbox';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, ErrorColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { LEGAL } from '@/lib/legal/config';
import { callRpc, friendlyRpcError } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';

// The consent gate: shown once to accounts that haven't accepted the
// current Terms version (older accounts, and everyone after the Terms
// change). Nothing else in the app is reachable until they agree — except
// deleting their account or logging out, so nobody is trapped.
export default function AcceptTermsScreen() {
  const { refreshConsent } = useAuth();
  const [agreed, setAgreed] = useState(false);
  // True once we know they accepted an older version: "We've updated…".
  const [isUpdate, setIsUpdate] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    callRpc<{ accepted_version: string | null }>('get_my_consent_status')
      .then((status) => setIsUpdate(Boolean(status?.accepted_version)))
      .catch(() => {});
  }, []);

  async function handleContinue() {
    if (!agreed) return;
    setErrorMessage(null);
    setIsSubmitting(true);
    try {
      const result = await callRpc<{ outcome: string }>('accept_terms', {
        p_version: LEGAL.TERMS_VERSION,
        p_age_confirmed: true,
      });
      if (result?.outcome === 'accepted') {
        // Lifts the gate; the root layout moves on by itself.
        await refreshConsent();
        return;
      }
      setErrorMessage(
        result?.outcome === 'stale_version'
          ? 'Our Terms changed since this version of Bolas was released. Please update the app to continue.'
          : 'Something went wrong. Try again.',
      );
    } catch (error) {
      setErrorMessage(friendlyRpcError(error));
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.container}>
        <ScrollView contentContainerStyle={styles.content}>
          <ThemedText type="subtitle" accessibilityRole="header">
            {isUpdate ? "We've updated our Terms" : 'Before you continue'}
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary">
            {isUpdate
              ? 'Please take a look at the updated Terms and Privacy Policy. To keep using Bolas, confirm you agree.'
              : `Bolas is for people ${LEGAL.MIN_AGE} and older. Please read and agree to our Terms and Privacy Policy to keep using Bolas.`}
          </ThemedText>

          <ThemedView type="backgroundElement" style={styles.card}>
            <ConsentCheckbox checked={agreed} onChange={setAgreed} disabled={isSubmitting} />
          </ThemedView>

          {errorMessage ? (
            <ThemedText type="small" style={styles.errorText} accessibilityLiveRegion="polite">
              {errorMessage}
            </ThemedText>
          ) : null}

          <Pressable
            onPress={handleContinue}
            disabled={!agreed || isSubmitting}
            accessibilityRole="button"
            accessibilityLabel="Continue"
            accessibilityState={{ disabled: !agreed || isSubmitting, busy: isSubmitting }}
            style={({ pressed }) => [
              styles.button,
              { backgroundColor: AccentColor, opacity: !agreed || isSubmitting ? 0.5 : 1 },
              pressed && agreed && styles.buttonPressed,
            ]}>
            {isSubmitting ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Continue
              </ThemedText>
            )}
          </Pressable>

          <View style={styles.secondaryActions}>
            <Pressable
              onPress={() => router.push('/delete-account')}
              hitSlop={Spacing.two}
              accessibilityRole="button"
              accessibilityLabel="Delete my account instead">
              <ThemedText type="small" themeColor="textSecondary" style={styles.underline}>
                Delete my account instead
              </ThemedText>
            </Pressable>
            <Pressable
              onPress={() => supabase.auth.signOut()}
              hitSlop={Spacing.two}
              accessibilityRole="button"
              accessibilityLabel="Log out">
              <ThemedText type="small" themeColor="textSecondary" style={styles.underline}>
                Log out
              </ThemedText>
            </Pressable>
          </View>
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
  card: {
    padding: Spacing.three,
    borderRadius: Spacing.three,
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
  secondaryActions: {
    flexDirection: 'row',
    justifyContent: 'center',
    gap: Spacing.five,
    marginTop: Spacing.two,
  },
  underline: {
    textDecorationLine: 'underline',
  },
});
