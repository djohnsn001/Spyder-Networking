import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Switch, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, DangerColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import { CONNECTION_LEVEL_LABEL_IN_SENTENCE } from '@/lib/connect/labels';
import { getIsAdmin } from '@/lib/events';
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
  const [isUpdatingNotifications, setIsUpdatingNotifications] = useState(false);
  const [isUpdatingLocationSharing, setIsUpdatingLocationSharing] = useState(false);
  // Only the team (app_admins) sees the Admin row. The admin screen and every
  // admin RPC check again on their own.
  const [isAdmin, setIsAdmin] = useState(false);

  useEffect(() => {
    getIsAdmin()
      .then(setIsAdmin)
      .catch(() => setIsAdmin(false));
  }, []);

  async function handleToggleNotifications(value: boolean) {
    if (!session) return;
    setIsUpdatingNotifications(true);
    try {
      const { error } = await supabase
        .from('profiles')
        .update({ notifications_enabled: value })
        .eq('id', session.user.id);
      if (error) throw error;
      await refreshProfile();
    } catch (error) {
      console.error('Failed to update notification preference', error);
    } finally {
      setIsUpdatingNotifications(false);
    }
  }

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
            <View style={styles.row}>
              <View style={styles.rowTextCol}>
                <ThemedText type="default">Notifications</ThemedText>
                <ThemedText type="small" themeColor="textSecondary">
                  Connection requests and updates
                </ThemedText>
              </View>
              <Switch
                value={profile?.notifications_enabled ?? true}
                onValueChange={handleToggleNotifications}
                disabled={isUpdatingNotifications}
                trackColor={{ true: AccentColor }}
              />
            </View>

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
                <ThemedText type="default">Location &amp; tapping</ThemedText>
                <ThemedText type="small" themeColor="textSecondary">
                  When you tap phones, Bolas uses your location only to find the person
                  you&apos;re with. It&apos;s deleted within minutes, and only the city you met
                  in is kept.
                </ThemedText>
              </View>
            </View>
          </ThemedView>

          <ThemedView type="backgroundElement" style={styles.group}>
            <Pressable
              onPress={() => supabase.auth.signOut()}
              accessibilityRole="button"
              accessibilityLabel="Log out"
              style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
              <ThemedText type="default" themeColor="text" style={styles.logoutLabel}>
                Log out
              </ThemedText>
            </Pressable>
          </ThemedView>
        </ScrollView>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
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
    color: DangerColor,
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
