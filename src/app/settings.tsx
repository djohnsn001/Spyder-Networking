import Constants from 'expo-constants';
import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Switch, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import { CONNECTION_LEVEL_LABEL_IN_SENTENCE } from '@/lib/connect/labels';
import { getIsAdmin } from '@/lib/events';
import { contactSupport, LEGAL, openLegalUrl } from '@/lib/legal/config';
import { setLocationSharing } from '@/lib/map';
import { supabase } from '@/lib/supabase';
import { useThemePreference, type ThemePreference } from '@/lib/theme-preference';

const THEME_OPTIONS: { value: ThemePreference; label: string }[] = [
  { value: 'system', label: 'Match device' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
];

export default function SettingsScreen() {
  const { session, profile, refreshProfile } = useAuth();
  const theme = useTheme();
  const { preference, setPreference } = useThemePreference();
  const [isUpdatingLocationSharing, setIsUpdatingLocationSharing] = useState(false);
  // Only the team (app_admins) sees the Admin row. The admin screen and every
  // admin RPC check again on their own.
  const [isAdmin, setIsAdmin] = useState(false);

  useEffect(() => {
    getIsAdmin()
      .then(setIsAdmin)
      .catch(() => setIsAdmin(false));
  }, []);

  async function handleToggleLocationSharing(value: boolean) {
    if (!session) return;
    setIsUpdatingLocationSharing(true);
    try {
      await setLocationSharing(session.user.id, value);
      await refreshProfile();
    } catch (error) {
      console.error('Failed to update location sharing preference', error);
    } finally {
      setIsUpdatingLocationSharing(false);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ScrollView contentContainerStyle={styles.scrollContent}>
          <ThemedText type="small" themeColor="textSecondary" style={styles.sectionLabel}>
            Account
          </ThemedText>
          <ThemedView type="backgroundElement" style={styles.group}>
            <Pressable
              onPress={() => router.push('/edit-profile')}
              accessibilityRole="button"
              accessibilityLabel="Edit profile"
              style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
              <ThemedText type="default">Edit Profile</ThemedText>
              <ThemedText type="default" themeColor="textSecondary">
                ›
              </ThemedText>
            </Pressable>
            {isAdmin ? (
              <Pressable
                onPress={() => router.push('/admin')}
                accessibilityRole="button"
                accessibilityLabel="Admin"
                style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
                <ThemedText type="default">Admin</ThemedText>
                <ThemedText type="default" themeColor="textSecondary">
                  ›
                </ThemedText>
              </Pressable>
            ) : null}
            {/* Apple requires deleting an account to be easy to find. */}
            <Pressable
              onPress={() => router.push('/delete-account')}
              accessibilityRole="button"
              accessibilityLabel="Delete account"
              style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
              <ThemedText themeColor="danger" type="default" style={styles.logoutLabel}>
                Delete account
              </ThemedText>
              <ThemedText type="default" themeColor="textSecondary">
                ›
              </ThemedText>
            </Pressable>
          </ThemedView>

          <ThemedText type="small" themeColor="textSecondary" style={styles.sectionLabel}>
            Appearance
          </ThemedText>
          <ThemedView type="backgroundElement" style={styles.group}>
            <View style={styles.row}>
              <View style={styles.rowTextCol}>
                <ThemedText type="default">Theme</ThemedText>
                <ThemedText type="small" themeColor="textSecondary">
                  Choose how Bolas looks
                </ThemedText>
              </View>
            </View>
            <View style={[styles.row, styles.themeOptionsRow]}>
              {THEME_OPTIONS.map((option) => {
                const selected = preference === option.value;
                return (
                  <Pressable
                    key={option.value}
                    onPress={() => setPreference(option.value)}
                    accessibilityRole="button"
                    accessibilityLabel={option.label}
                    accessibilityState={{ selected }}
                    style={({ pressed }) => [
                      styles.themeOption,
                      { backgroundColor: selected ? AccentColor : theme.backgroundSelected },
                      pressed && styles.rowPressed,
                    ]}>
                    <ThemedText
                      type="smallBold"
                      style={selected ? styles.themeOptionLabelSelected : undefined}>
                      {option.label}
                    </ThemedText>
                  </Pressable>
                );
              })}
            </View>
          </ThemedView>

          <ThemedText type="small" themeColor="textSecondary" style={styles.sectionLabel}>
            Preferences
          </ThemedText>
          <ThemedView type="backgroundElement" style={styles.group}>
            {/* No Notifications toggle until push notifications exist
                (data-inventory flag M6): a switch that does nothing would be
                a promise the app doesn't keep. */}
            <View style={styles.row}>
              <View style={styles.rowTextCol}>
                <ThemedText type="default">Show me on the map</ThemedText>
                <ThemedText type="small" themeColor="textSecondary">
                  Let your {CONNECTION_LEVEL_LABEL_IN_SENTENCE.in_person} see your approximate
                  location on the Web Map
                </ThemedText>
              </View>
              <Switch
                value={profile?.location_sharing === 'connections'}
                onValueChange={handleToggleLocationSharing}
                disabled={isUpdatingLocationSharing}
                trackColor={{ true: AccentColor }}
              />
            </View>

            <View style={styles.row}>
              <View style={styles.rowTextCol}>
                <ThemedText type="default">Location &amp; connecting in person</ThemedText>
                <ThemedText type="small" themeColor="textSecondary">
                  When you tap phones or use a QR code, Bolas uses your location only to check
                  you&apos;re with the other person. It&apos;s deleted within minutes, and only
                  the city you met in is kept.
                </ThemedText>
              </View>
            </View>
          </ThemedView>

          <ThemedText type="small" themeColor="textSecondary" style={styles.sectionLabel}>
            Privacy &amp; safety
          </ThemedText>
          <ThemedView type="backgroundElement" style={styles.group}>
            <LinkRow label="Blocked users" onPress={() => router.push('/blocked-users')} />
          </ThemedView>

          <ThemedText type="small" themeColor="textSecondary" style={styles.sectionLabel}>
            Legal
          </ThemedText>
          <ThemedView type="backgroundElement" style={styles.group}>
            <LinkRow label="Terms of Service" onPress={() => openLegalUrl(LEGAL.TERMS_URL)} />
            <LinkRow label="Privacy Policy" onPress={() => openLegalUrl(LEGAL.PRIVACY_URL)} />
            <LinkRow
              label="Community Guidelines"
              onPress={() => openLegalUrl(LEGAL.GUIDELINES_URL)}
            />
            <LinkRow label="Safety Tips" onPress={() => openLegalUrl(LEGAL.SAFETY_URL)} />
            <LinkRow label="Open-source licenses" onPress={() => router.push('/legal/licenses')} />
            <LinkRow label="Contact support" onPress={contactSupport} />
          </ThemedView>

          <ThemedView type="backgroundElement" style={styles.group}>
            <Pressable
              onPress={() => supabase.auth.signOut()}
              accessibilityRole="button"
              accessibilityLabel="Log out"
              style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
              <ThemedText type="default" themeColor="danger" style={styles.logoutLabel}>
                Log out
              </ThemedText>
            </Pressable>
          </ThemedView>

          <ThemedText type="small" themeColor="textSecondary" style={styles.version}>
            Bolas {Constants.expoConfig?.version ?? ''}
          </ThemedText>
        </ScrollView>
      </SafeAreaView>
    </ThemedView>
  );
}

function LinkRow({ label, onPress }: { label: string; onPress: () => void }) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={label}
      style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
      <ThemedText type="default">{label}</ThemedText>
      <ThemedText type="default" themeColor="textSecondary">
        ›
      </ThemedText>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  version: {
    textAlign: 'center',
    marginTop: Spacing.four,
  },
  container: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
  },
  scrollContent: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.four,
    gap: Spacing.one,
  },
  sectionLabel: {
    marginTop: Spacing.three,
    marginBottom: Spacing.one,
    marginLeft: Spacing.one,
    textTransform: 'uppercase',
  },
  group: {
    borderRadius: Spacing.four,
    overflow: 'hidden',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.three,
  },
  rowPressed: {
    opacity: 0.7,
  },
  rowTextCol: {
    flex: 1,
    marginRight: Spacing.three,
    gap: 2,
  },
  logoutLabel: {
  },
  themeOptionsRow: {
    gap: Spacing.two,
    paddingTop: 0,
  },
  themeOption: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.five,
  },
  themeOptionLabelSelected: {
    color: '#fdfbf7',
  },
});
