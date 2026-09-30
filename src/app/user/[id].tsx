import { router, Stack, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { LevelChip } from '@/components/connect/level-chip';
import { ConnectButton } from '@/components/connect-button';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
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
import { getOrStartDirectConversation } from '@/lib/messages';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { PUBLIC_PROFILE_COLUMNS } from '@/lib/profiles';
import { openSafetyMenu } from '@/lib/safety';
import { supabase } from '@/lib/supabase';
import type { ConnectionRow, PublicProfile } from '@/lib/types';

export default function UserProfileScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const myId = session?.user.id;

  const [profile, setProfile] = useState<PublicProfile | null>(null);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [mutualCount, setMutualCount] = useState(0);
  const [connectionCount, setConnectionCount] = useState(0);
  const [isLoading, setIsLoading] = useState(true);
  const [isUpdating, setIsUpdating] = useState(false);
  const [isStartingChat, setIsStartingChat] = useState(false);
  const [chatError, setChatError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!id || !myId) return;
    setIsLoading(true);
    const [profileResult, myConnections, mutuals, connectionTotal] = await Promise.all([
      supabase.from('profiles').select(PUBLIC_PROFILE_COLUMNS).eq('id', id).maybeSingle(),
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

  async function handleMessage() {
    if (!profile) return;
    setChatError(null);
    setIsStartingChat(true);
    try {
      const conversationId = await getOrStartDirectConversation(profile.id);
      router.push(`/chat/${conversationId}`);
    } catch (error) {
      console.error('Failed to start conversation', error);
      setChatError('Could not start a conversation. Try again.');
    } finally {
      setIsStartingChat(false);
    }
  }

  if (isLoading || !profile) {
    return (
      <ThemedView style={styles.container}>
        <SafeAreaView style={styles.safeArea}>
          {isLoading ? (
            <ActivityIndicator />
          ) : (
            // Also what someone sees for a profile that blocked them, or a
            // suspended account: never anything more specific.
            <ThemedText type="default" themeColor="textSecondary">
              This profile isn&apos;t available.
            </ThemedText>
          )}
        </SafeAreaView>
      </ThemedView>
    );
  }

  const displayName = profile.full_name || profile.username || '';
  const businessStageLabel = getBusinessStageLabel(profile.business_stage);
  const { status, connectionId, level, metAt, metCity } = myId
    ? getConnectionStatus(connections, myId, profile.id)
    : { status: 'none' as const, connectionId: null, level: null, metAt: null, metCity: null };
  const isMe = myId === profile.id;

  return (
    <ThemedView style={styles.container}>
      {!isMe ? (
        <Stack.Screen
          options={{
            headerRight: () => (
              <Pressable
                onPress={() => openSafetyMenu(displayName || 'this person', profile.id, 'profile')}
                hitSlop={Spacing.three}
                accessibilityRole="button"
                accessibilityLabel={`More options for ${displayName || 'this person'}`}
                accessibilityHint="Report or block">
                <ThemedText type="subtitle" themeColor="textSecondary">
                  ⋯
                </ThemedText>
              </Pressable>
            ),
          }}
        />
      ) : null}
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

          {status === 'accepted' && level ? (
            <View style={styles.chipRow}>
              <LevelChip level={level} metAt={metAt} metCity={metCity} />
            </View>
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
              level={level}
              pending={isUpdating}
              onPress={handleConnectPress}
              onUnconnect={handleConnectPress}
              onAccept={connectionId ? () => handleRespond(connectionId, true) : undefined}
              onDecline={connectionId ? () => handleRespond(connectionId, false) : undefined}
            />
          ) : null}

          {myId && status === 'accepted' ? (
            <>
              <Pressable
                onPress={handleMessage}
                disabled={isStartingChat}
                accessibilityRole="button"
                accessibilityLabel={`Message ${displayName}`}
                style={({ pressed }) => [
                  styles.messageButton,
                  { opacity: isStartingChat ? 0.7 : 1 },
                  pressed && styles.buttonPressed,
                ]}>
                {isStartingChat ? (
                  <ActivityIndicator color="#fdfbf7" />
                ) : (
                  <ThemedText type="smallBold" style={styles.messageButtonLabel}>
                    Message
                  </ThemedText>
                )}
              </Pressable>
              {chatError ? (
                <ThemedText themeColor="error" type="small" style={styles.errorText}>
                  {chatError}
                </ThemedText>
              ) : null}
            </>
          ) : null}

          {myId && !isMe && level !== 'in_person' ? (
            <Pressable
              onPress={() => router.push('/connect')}
              accessibilityRole="button"
              accessibilityLabel="Tap phones to add them to your map"
              style={({ pressed }) => pressed && styles.buttonPressed}>
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                Met in real life?{' '}
                <ThemedText type="smallBold" style={styles.accentText}>
                  Tap phones
                </ThemedText>{' '}
                to add them to your map
              </ThemedText>
            </Pressable>
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
  chipRow: {
    alignItems: 'center',
  },
  accentText: {
    color: AccentColor,
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
  messageButton: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.four,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
    alignItems: 'center',
    justifyContent: 'center',
  },
  messageButtonLabel: {
    color: '#fdfbf7',
  },
  buttonPressed: {
    opacity: 0.85,
  },
  errorText: {
    textAlign: 'center',
    marginTop: Spacing.one,
  },
});
