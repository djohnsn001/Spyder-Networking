import { useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ConnectButton } from '@/components/connect-button';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  fetchMutualCount,
  fetchMyConnections,
  getConnectionStatus,
  removeConnection,
  sendConnectionRequest,
} from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { supabase } from '@/lib/supabase';
import type { ConnectionRow, Profile } from '@/lib/types';

function getInitials(name: string) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export default function UserProfileScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const myId = session?.user.id;

  const [profile, setProfile] = useState<Profile | null>(null);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [mutualCount, setMutualCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [isUpdating, setIsUpdating] = useState(false);

  const load = useCallback(async () => {
    if (!id || !myId) return;
    setIsLoading(true);
    const [profileResult, myConnections, mutuals] = await Promise.all([
      supabase.from('profiles').select('*').eq('id', id).maybeSingle(),
      fetchMyConnections(myId),
      fetchMutualCount(id),
    ]);
    if (profileResult.error) {
      console.error('Failed to load profile', profileResult.error);
    } else {
      setProfile(profileResult.data);
    }
    setConnections(myConnections);
    setMutualCount(mutuals);
    setIsLoading(false);
  }, [id, myId]);

  useEffect(() => {
    void Promise.resolve().then(load);
  }, [load]);

  async function handleConnectPress() {
    if (!myId || !id) return;
    const { status, connectionId } = getConnectionStatus(connections, myId, id);
    setIsUpdating(true);
    try {
      if (status === 'none') {
        await sendConnectionRequest(myId, id);
      } else if (status === 'pending_sent' && connectionId) {
        await removeConnection(connectionId);
      }
      setConnections(await fetchMyConnections(myId));
    } catch (error) {
      console.error('Failed to update connection', error);
    } finally {
      setIsUpdating(false);
    }
  }

  if (isLoading || !profile) {
    return (
      <ThemedView style={styles.container}>
        <SafeAreaView style={styles.safeArea}>
          {isLoading ? (
            <ActivityIndicator />
          ) : (
            <ThemedText type="default" themeColor="textSecondary">
              This profile couldn&apos;t be found.
            </ThemedText>
          )}
        </SafeAreaView>
      </ThemedView>
    );
  }

  const displayName = profile.full_name || profile.username || '';
  const businessStageLabel = getBusinessStageLabel(profile.business_stage);
  const { status } = myId
    ? getConnectionStatus(connections, myId, profile.id)
    : { status: 'none' as const };

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ThemedView type="backgroundElement" style={styles.card}>
          <ThemedView type="backgroundSelected" style={styles.avatar}>
            <ThemedText type="subtitle">{getInitials(displayName)}</ThemedText>
          </ThemedView>

          <ThemedText type="subtitle" style={styles.centerText}>
            {displayName}
          </ThemedText>

          {profile.username ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              @{profile.username}
            </ThemedText>
          ) : null}

          {status === 'accepted' || mutualCount > 0 ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              {mutualCount} mutual connection{mutualCount === 1 ? '' : 's'}
            </ThemedText>
          ) : null}

          {profile.bio ? (
            <ThemedText type="default" style={styles.centerText}>
              {profile.bio}
            </ThemedText>
          ) : null}

          {profile.city || businessStageLabel ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              {[profile.city, businessStageLabel].filter(Boolean).join(' · ')}
            </ThemedText>
          ) : null}

          {profile.interests.length > 0 ? (
            <View style={styles.pillRow}>
              {profile.interests.map((interest) => (
                <ThemedView key={interest} type="backgroundSelected" style={styles.pill}>
                  <ThemedText type="small">{interest}</ThemedText>
                </ThemedView>
              ))}
            </View>
          ) : null}

          {myId ? (
            <ConnectButton status={status} pending={isUpdating} onPress={handleConnectPress} />
          ) : null}
        </ThemedView>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    flexDirection: 'row',
  },
  safeArea: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
    paddingBottom: BottomTabInset + Spacing.three,
    maxWidth: MaxContentWidth,
  },
  card: {
    alignSelf: 'stretch',
    alignItems: 'center',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    borderRadius: Spacing.four,
  },
  avatar: {
    width: 96,
    height: 96,
    borderRadius: 48,
    alignItems: 'center',
    justifyContent: 'center',
  },
  centerText: {
    textAlign: 'center',
  },
  pillRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    justifyContent: 'center',
    gap: Spacing.two,
  },
  pill: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.five,
  },
});
