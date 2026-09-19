import { useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ConnectButton } from '@/components/connect-button';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  acceptConnectionRequest,
  fetchConnectionCount,
  fetchMutualCount,
  fetchMyConnections,
  getConnectionStatus,
  removeConnection,
  sendConnectionRequest,
} from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { supabase } from '@/lib/supabase';
import type { ConnectionRow, Profile } from '@/lib/types';

export default function UserProfileScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const myId = session?.user.id;

  const [profile, setProfile] = useState<Profile | null>(null);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [mutualCount, setMutualCount] = useState(0);
  const [connectionCount, setConnectionCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [isUpdating, setIsUpdating] = useState(false);

  const load = useCallback(async () => {
    if (!id || !myId) return;
    setIsLoading(true);
    const [profileResult, myConnections, mutuals, connectionTotal] = await Promise.all([
      supabase.from('profiles').select('*').eq('id', id).maybeSingle(),
      fetchMyConnections(myId),
      fetchMutualCount(id),
      fetchConnectionCount(id),
    ]);
    if (profileResult.error) {
      console.error('Failed to load profile', profileResult.error);
    } else {
      setProfile(profileResult.data);
    }
    setConnections(myConnections);
    setMutualCount(mutuals);
    setConnectionCount(connectionTotal);
    setIsLoading(false);
  }, [id, myId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  async function handleConnectPress() {
    if (!myId || !id) return;
    const { status, connectionId } = getConnectionStatus(connections, myId, id);
    setIsUpdating(true);
    try {
      if (status === 'none') {
        await sendConnectionRequest(myId, id);
      } else if ((status === 'pending_sent' || status === 'accepted') && connectionId) {
        await removeConnection(connectionId);
        setConnectionCount(await fetchConnectionCount(id));
      }
      setConnections(await fetchMyConnections(myId));
    } catch (error) {
      console.error('Failed to update connection', error);
    } finally {
      setIsUpdating(false);
    }
  }

  async function handleRespond(connectionId: string, accept: boolean) {
    if (!myId || !id) return;
    setIsUpdating(true);
    try {
      if (accept) {
        await acceptConnectionRequest(connectionId);
      } else {
        await removeConnection(connectionId);
      }
      setConnections(await fetchMyConnections(myId));
      setConnectionCount(await fetchConnectionCount(id));
    } catch (error) {
      console.error('Failed to respond to request', error);
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
  const { status, connectionId } = myId
    ? getConnectionStatus(connections, myId, profile.id)
    : { status: 'none' as const, connectionId: null };

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ThemedView type="backgroundElement" style={styles.card}>
          <Avatar uri={profile.avatar_url} name={displayName} size={96} />

          <ThemedText type="subtitle" style={styles.centerText}>
            {displayName}
          </ThemedText>

          {profile.username ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              @{profile.username}
            </ThemedText>
          ) : null}

          <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
            {connectionCount} connection{connectionCount === 1 ? '' : 's'}
            {mutualCount > 0 ? ` · ${mutualCount} mutual` : ''}
          </ThemedText>

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
            <ConnectButton
              status={status}
              pending={isUpdating}
              onPress={handleConnectPress}
              onUnconnect={handleConnectPress}
              onAccept={connectionId ? () => handleRespond(connectionId, true) : undefined}
              onDecline={connectionId ? () => handleRespond(connectionId, false) : undefined}
            />
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
