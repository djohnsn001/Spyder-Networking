import { router } from 'expo-router';
import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Switch, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, DangerColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { supabase } from '@/lib/supabase';

export default function SettingsScreen() {
  const { session, profile, refreshProfile } = useAuth();
  const [isUpdatingNotifications, setIsUpdatingNotifications] = useState(false);
  const [isUpdatingLocationSharing, setIsUpdatingLocationSharing] = useState(false);

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
      const { error } = await supabase
        .from('profiles')
        .update({ location_sharing: value ? 'connections' : 'off' })
        .eq('id', session.user.id);
      if (error) throw error;
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
                  Let your connections see your approximate location on the Web Map
                </ThemedText>
              </View>
              <Switch
                value={(profile?.location_sharing ?? 'connections') === 'connections'}
                onValueChange={handleToggleLocationSharing}
                disabled={isUpdatingLocationSharing}
                trackColor={{ true: AccentColor }}
              />
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
    gap: 2,
  },
  logoutLabel: {
    color: DangerColor,
  },
});
