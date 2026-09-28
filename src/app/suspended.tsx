import { router } from 'expo-router';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { DangerColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { contactSupport, LEGAL, openLegalUrl } from '@/lib/legal/config';
import { supabase } from '@/lib/supabase';

// Shown instead of the app when an admin has suspended the account
// (account_restrictions). No tabs. They can still read the rules, contact
// support, delete their account, or log out. The admin's reason is internal
// and not shown.
export default function SuspendedScreen() {
  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.container}>
        <ScrollView contentContainerStyle={styles.content}>
          <ThemedText type="subtitle" accessibilityRole="header">
            Your account is suspended
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary">
            Your account was suspended for breaking our Terms or Community Guidelines. While
            it&apos;s suspended, other people can&apos;t see your profile and you can&apos;t post,
            message, or connect.
          </ThemedText>
          <ThemedText type="default" themeColor="textSecondary">
            If you think this is a mistake, contact us
            {LEGAL.SUPPORT_EMAIL.includes('{{') ? '' : ` at ${LEGAL.SUPPORT_EMAIL}`}.
          </ThemedText>

          <ThemedView type="backgroundElement" style={styles.group}>
            <Row label="Contact support" onPress={contactSupport} />
            <Row label="Terms of Service" onPress={() => openLegalUrl(LEGAL.TERMS_URL)} />
            <Row label="Community Guidelines" onPress={() => openLegalUrl(LEGAL.GUIDELINES_URL)} />
            <Row label="Delete account" danger onPress={() => router.push('/delete-account')} />
          </ThemedView>

          <View style={styles.logout}>
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

function Row({ label, onPress, danger }: { label: string; onPress: () => void; danger?: boolean }) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={label}
      style={({ pressed }) => [styles.row, pressed && styles.pressed]}>
      <ThemedText type="default" style={danger ? { color: DangerColor } : undefined}>
        {label}
      </ThemedText>
      <ThemedText type="default" themeColor="textSecondary">
        ›
      </ThemedText>
    </Pressable>
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
  group: {
    borderRadius: Spacing.four,
    overflow: 'hidden',
    marginTop: Spacing.two,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 48,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.three,
  },
  pressed: {
    opacity: 0.7,
  },
  logout: {
    alignItems: 'center',
    marginTop: Spacing.two,
  },
  underline: {
    textDecorationLine: 'underline',
  },
});
