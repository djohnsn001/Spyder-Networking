import { useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  StyleSheet,
  TextInput,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { supabase } from '@/lib/supabase';

const AccentColor = '#3c87f7';
const ErrorColor = '#d1453b';

type Mode = 'signIn' | 'signUp';

export function LoginScreen() {
  const theme = useTheme();
  const [mode, setMode] = useState<Mode>('signIn');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [infoMessage, setInfoMessage] = useState<string | null>(null);

  const isSignUp = mode === 'signUp';

  async function handleSubmit() {
    setErrorMessage(null);
    setInfoMessage(null);

    const trimmedEmail = email.trim();
    if (!trimmedEmail || !password) {
      setErrorMessage('Enter an email and password.');
      return;
    }

    setIsSubmitting(true);
    try {
      if (isSignUp) {
        const { data, error } = await supabase.auth.signUp({
          email: trimmedEmail,
          password,
        });
        if (error) throw error;

        if (!data.session) {
          setInfoMessage('Check your email to confirm your account, then log in.');
          setMode('signIn');
        }
      } else {
        const { error } = await supabase.auth.signInWithPassword({
          email: trimmedEmail,
          password,
        });
        if (error) throw error;
      }
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : 'Something went wrong.');
    } finally {
      setIsSubmitting(false);
    }
  }

  function toggleMode() {
    setErrorMessage(null);
    setInfoMessage(null);
    setMode(isSignUp ? 'signIn' : 'signUp');
  }

  return (
    <ThemedView style={styles.container}>
      <KeyboardAvoidingView
        style={styles.container}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <SafeAreaView style={styles.safeArea}>
          <ThemedView type="backgroundElement" style={styles.card}>
            <ThemedText type="subtitle" style={styles.title}>
              Bolas
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary" style={styles.subtitle}>
              {isSignUp ? 'Create an account to get started.' : 'Log in to your account.'}
            </ThemedText>

            <TextInput
              value={email}
              onChangeText={setEmail}
              placeholder="Email"
              placeholderTextColor={theme.textSecondary}
              autoCapitalize="none"
              autoComplete="email"
              keyboardType="email-address"
              textContentType="emailAddress"
              style={[
                styles.input,
                { color: theme.text, backgroundColor: theme.backgroundSelected },
              ]}
            />

            <TextInput
              value={password}
              onChangeText={setPassword}
              placeholder="Password"
              placeholderTextColor={theme.textSecondary}
              autoCapitalize="none"
              secureTextEntry
              textContentType={isSignUp ? 'newPassword' : 'password'}
              style={[
                styles.input,
                { color: theme.text, backgroundColor: theme.backgroundSelected },
              ]}
            />

            {errorMessage ? (
              <ThemedText type="small" style={styles.errorText}>
                {errorMessage}
              </ThemedText>
            ) : null}
            {infoMessage ? (
              <ThemedText type="small" themeColor="textSecondary" style={styles.infoText}>
                {infoMessage}
              </ThemedText>
            ) : null}

            <Pressable
              onPress={handleSubmit}
              disabled={isSubmitting}
              accessibilityRole="button"
              accessibilityLabel={isSignUp ? 'Sign up' : 'Log in'}
              style={({ pressed }) => [
                styles.button,
                { backgroundColor: AccentColor, opacity: isSubmitting ? 0.7 : 1 },
                pressed && styles.buttonPressed,
              ]}>
              {isSubmitting ? (
                <ActivityIndicator color="#ffffff" />
              ) : (
                <ThemedText type="smallBold" style={styles.buttonLabel}>
                  {isSignUp ? 'Sign up' : 'Log in'}
                </ThemedText>
              )}
            </Pressable>

            <Pressable onPress={toggleMode} accessibilityRole="button">
              <ThemedText type="link" themeColor="textSecondary" style={styles.toggleText}>
                {isSignUp ? 'Already have an account? Log in' : "Don't have an account? Sign up"}
              </ThemedText>
            </Pressable>
          </ThemedView>
        </SafeAreaView>
      </KeyboardAvoidingView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
  },
  card: {
    alignSelf: 'stretch',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    borderRadius: Spacing.four,
    maxWidth: MaxContentWidth,
  },
  title: {
    textAlign: 'center',
  },
  subtitle: {
    textAlign: 'center',
    marginTop: -Spacing.two,
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  errorText: {
    color: ErrorColor,
    textAlign: 'center',
  },
  infoText: {
    textAlign: 'center',
  },
  button: {
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#ffffff',
  },
  toggleText: {
    textAlign: 'center',
  },
});
