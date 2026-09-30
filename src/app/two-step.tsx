import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import QRCode from 'react-native-qrcode-svg';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import {
  listTotpFactors,
  removeTotpFactor,
  startTotpEnrollment,
  verifyTotpCode,
  type TotpEnrollment,
} from '@/lib/mfa';

type Factor = Awaited<ReturnType<typeof listTotpFactors>>[number];

// Settings → Two-step verification. Adds an authenticator app (TOTP) so
// signing in also needs a 6-digit code. Anyone can turn it on; admins must,
// because Admin only opens in a session verified with a code (item H4).
export default function TwoStepScreen() {
  const theme = useTheme();
  const { refreshMfa } = useAuth();
  const [factors, setFactors] = useState<Factor[] | null>(null);
  const [enrollment, setEnrollment] = useState<TotpEnrollment | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setFactors(await listTotpFactors());
    } catch {
      setError("Couldn't load your two-step settings. Check your connection.");
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function handleStart() {
    setError(null);
    setMessage(null);
    setBusy(true);
    try {
      setEnrollment(await startTotpEnrollment());
      setCode('');
    } catch (err) {
      if (__DEV__) console.warn('[mfa] enroll failed', err);
      setError("Couldn't start set-up. Try again in a moment.");
    } finally {
      setBusy(false);
    }
  }

  async function handleOpenApp() {
    if (!enrollment) return;
    try {
      await Linking.openURL(enrollment.uri);
    } catch {
      // No app registered for otpauth:// links.
      setError('No authenticator app found. Install one, or copy the key below into it.');
    }
  }

  async function handleVerify() {
    if (!enrollment || !/^\d{6}$/.test(code)) return;
    setError(null);
    setBusy(true);
    try {
      const result = await verifyTotpCode(enrollment.factorId, code);
      if (result === 'wrong_code') {
        setError("That code didn't work. Enter the newest code from your authenticator app.");
        setCode('');
        return;
      }
      setEnrollment(null);
      setMessage('Two-step verification is on. You’ll enter a code each time you sign in.');
      await Promise.all([load(), refreshMfa()]);
    } catch {
      setError('Something went wrong. Try again.');
    } finally {
      setBusy(false);
    }
  }

  function handleRemove(factor: Factor) {
    Alert.alert(
      'Turn off two-step verification?',
      'Signing in will only need your password. If you’re an admin, you won’t be able to open Admin until you turn it back on.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Turn off',
          style: 'destructive',
          onPress: async () => {
            setError(null);
            setMessage(null);
            setBusy(true);
            try {
              await removeTotpFactor(factor.id);
              setMessage('Two-step verification is off.');
              await Promise.all([load(), refreshMfa()]);
            } catch {
              setError("Couldn't turn it off. Try again.");
            } finally {
              setBusy(false);
            }
          },
        },
      ],
    );
  }

  return (
    <ThemedView style={styles.container}>
      <ScrollView
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
        automaticallyAdjustKeyboardInsets={Platform.OS === 'ios'}>
        <ThemedText type="default" themeColor="textSecondary">
          With two-step verification, signing in needs your password and a 6-digit code from an
          authenticator app (like Google Authenticator, 1Password or Authy). Someone who learns your
          password still can&apos;t get in.
        </ThemedText>

        {message ? (
          <ThemedText type="smallBold" accessibilityLiveRegion="polite">
            {message}
          </ThemedText>
        ) : null}
        {error ? (
          <ThemedText type="small" themeColor="error" accessibilityLiveRegion="polite">
            {error}
          </ThemedText>
        ) : null}

        {factors === null ? <ActivityIndicator color={AccentColor} /> : null}

        {/* Verified authenticator apps */}
        {factors && factors.length > 0 && !enrollment
          ? factors.map((factor) => (
              <ThemedView key={factor.id} type="backgroundElement" style={styles.card}>
                <View style={styles.cardText}>
                  <ThemedText type="smallBold">Authenticator app</ThemedText>
                  <ThemedText type="small" themeColor="textSecondary">
                    On since {new Date(factor.created_at).toLocaleDateString()}
                  </ThemedText>
                </View>
                <Pressable
                  onPress={() => handleRemove(factor)}
                  disabled={busy}
                  hitSlop={Spacing.two}
                  accessibilityRole="button"
                  accessibilityLabel="Turn off two-step verification"
                  style={styles.removeButton}>
                  <ThemedText type="smallBold" themeColor="danger">
                    Turn off
                  </ThemedText>
                </Pressable>
              </ThemedView>
            ))
          : null}

        {/* Not on yet */}
        {factors && factors.length === 0 && !enrollment ? (
          <Pressable
            onPress={handleStart}
            disabled={busy}
            accessibilityRole="button"
            accessibilityLabel="Set up two-step verification"
            style={({ pressed }) => [styles.button, busy && styles.dim, pressed && styles.pressed]}>
            {busy ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Set up two-step verification
              </ThemedText>
            )}
          </Pressable>
        ) : null}

        {/* Setting up */}
        {enrollment ? (
          <View style={styles.enroll}>
            <ThemedText type="smallBold">1. Add Bolas to your authenticator app</ThemedText>
            <ThemedText type="small" themeColor="textSecondary">
              On this phone, tap the button below. On another device, scan the QR code.
            </ThemedText>
            <Pressable
              onPress={handleOpenApp}
              accessibilityRole="button"
              accessibilityLabel="Open in authenticator app"
              style={({ pressed }) => [styles.secondaryButton, pressed && styles.pressed]}>
              <ThemedText type="smallBold" themeColor="accentText">
                Open in authenticator app
              </ThemedText>
            </Pressable>
            {/* Always black on white: some scanners can't read inverted codes. */}
            <View style={styles.qrCard} accessible accessibilityLabel="QR code for your authenticator app">
              <QRCode value={enrollment.uri} size={180} color="#000000" backgroundColor="#ffffff" />
            </View>
            <ThemedText type="small" themeColor="textSecondary">
              Or type this key into the app:
            </ThemedText>
            <ThemedText type="code" selectable style={styles.secret}>
              {enrollment.secret.replace(/(.{4})/g, '$1 ').trim()}
            </ThemedText>

            <ThemedText type="smallBold">2. Enter the 6-digit code it shows</ThemedText>
            <TextInput
              value={code}
              onChangeText={(text) => setCode(text.replace(/\D/g, '').slice(0, 6))}
              placeholder="123456"
              placeholderTextColor={theme.textSecondary}
              keyboardType="number-pad"
              textContentType="oneTimeCode"
              autoComplete="one-time-code"
              maxLength={6}
              onSubmitEditing={handleVerify}
              accessibilityLabel="6-digit code"
              style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
            />
            <Pressable
              onPress={handleVerify}
              disabled={busy || code.length !== 6}
              accessibilityRole="button"
              accessibilityLabel="Turn on two-step verification"
              accessibilityState={{ disabled: busy || code.length !== 6, busy }}
              style={({ pressed }) => [
                styles.button,
                (busy || code.length !== 6) && styles.dim,
                pressed && styles.pressed,
              ]}>
              {busy ? (
                <ActivityIndicator color="#fdfbf7" />
              ) : (
                <ThemedText type="smallBold" style={styles.buttonLabel}>
                  Turn on
                </ThemedText>
              )}
            </Pressable>
            <Pressable
              onPress={() => {
                setEnrollment(null);
                setCode('');
                setError(null);
              }}
              hitSlop={Spacing.three}
              accessibilityRole="button"
              accessibilityLabel="Cancel set-up"
              style={styles.cancel}>
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </View>
        ) : null}

        <ThemedText type="small" themeColor="textSecondary">
          Keep your authenticator app backed up. If you lose it, contact support from the email on
          your account.
        </ThemedText>
      </ScrollView>
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
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    padding: Spacing.three,
    borderRadius: Spacing.three,
  },
  cardText: {
    flex: 1,
  },
  removeButton: {
    minHeight: 44,
    justifyContent: 'center',
  },
  enroll: {
    gap: Spacing.three,
  },
  qrCard: {
    alignSelf: 'center',
    backgroundColor: '#ffffff',
    padding: Spacing.three,
    borderRadius: Spacing.three,
  },
  secret: {
    fontSize: 16,
    letterSpacing: 1,
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 22,
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
  secondaryButton: {
    minHeight: 44,
    paddingVertical: Spacing.two,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: Spacing.four,
    borderWidth: 1,
    borderColor: AccentColor,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
  dim: {
    opacity: 0.5,
  },
  pressed: {
    opacity: 0.8,
  },
  cancel: {
    alignSelf: 'center',
  },
});
