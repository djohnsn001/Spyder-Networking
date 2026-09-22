import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  acceptConnectionRequest,
  fetchConnectionCount,
  fetchPendingRequests,
  removeConnection,
  type PendingRequest,
} from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';

export default function ProfileScreen() {
  const { session, profile } = useAuth();

  const [requests, setRequests] = useState<PendingRequest[]>([]);
  const [respondingId, setRespondingId] = useState<string | null>(null);
  const [connectionCount, setConnectionCount] = useState(0);

  const loadRequests = useCallback(async () => {
    if (!session) return;
    setRequests(await fetchPendingRequests(session.user.id));
    setConnectionCount(await fetchConnectionCount(session.user.id));
  }, [session]);

  useFocusEffect(
    useCallback(() => {
      void loadRequests();
    }, [loadRequests]),
  );

  async function handleAccept(connectionId: string) {
    setRespondingId(connectionId);
    try {
      await acceptConnectionRequest(connectionId);
      setRequests((current) => current.filter((request) => request.connectionId !== connectionId));
      if (session) setConnectionCount(await fetchConnectionCount(session.user.id));
    } catch (error) {
      console.error('Failed to accept request', error);
    } finally {
      setRespondingId(null);
    }
  }

  async function handleDecline(connectionId: string) {
    setRespondingId(connectionId);
    try {
      await removeConnection(connectionId);
      setRequests((current) => current.filter((request) => request.connectionId !== connectionId));
    } catch (error) {
      console.error('Failed to decline request', error);
    } finally {
      setRespondingId(null);
    }
  }

  const displayName = profile?.full_name || profile?.username || session?.user.email || '';
  const businessStageLabel = getBusinessStageLabel(profile?.business_stage ?? null);

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ScrollView contentContainerStyle={styles.scrollContent} style={styles.scrollView}>
          <Pressable
            onPress={() => router.push('/settings')}
            accessibilityRole="button"
            accessibilityLabel="Settings"
            style={({ pressed }) => [styles.settingsLink, pressed && styles.buttonPressed]}>
            <ThemedText type="smallBold" themeColor="textSecondary">
              Settings
            </ThemedText>
          </Pressable>

          <ThemedView type="backgroundElement" style={styles.card}>
            <Avatar uri={profile?.avatar_url ?? null} name={displayName} size={96} />

            <ThemedText type="subtitle" style={styles.centerText}>
              {displayName}
            </ThemedText>

            {profile?.username ? (
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                @{profile.username}
              </ThemedText>
            ) : null}

            <Pressable
              onPress={() => router.push('/connections')}
              accessibilityRole="button"
              accessibilityLabel="View connections">
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                {connectionCount} connection{connectionCount === 1 ? '' : 's'}
              </ThemedText>
            </Pressable>

            {profile?.bio ? (
              <ThemedText type="default" style={styles.centerText}>
                {profile.bio}
              </ThemedText>
            ) : null}

            {profile?.city || businessStageLabel ? (
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                {[profile?.city, businessStageLabel].filter(Boolean).join(' · ')}
              </ThemedText>
            ) : null}

            {profile?.interests && profile.interests.length > 0 ? (
              <View style={styles.pillRow}>
                {profile.interests.map((interest) => (
                  <ThemedView key={interest} type="backgroundSelected" style={styles.pill}>
                    <ThemedText type="small">{interest}</ThemedText>
                  </ThemedView>
                ))}
              </View>
            ) : null}
          </ThemedView>

          {requests.length > 0 ? (
            <ThemedView type="backgroundElement" style={styles.requestsCard}>
              <ThemedText type="smallBold">
                Requests ({requests.length})
              </ThemedText>

              {requests.map((request) => {
                const name =
                  request.requester.full_name || request.requester.username || 'Someone';
                const isResponding = respondingId === request.connectionId;
                return (
                  <View key={request.connectionId} style={styles.requestRow}>
                    <Pressable
                      style={styles.requestInfo}
                      onPress={() => router.push(`/user/${request.requester.id}`)}
                      accessibilityRole="button"
                      accessibilityLabel={`View ${name}'s profile`}>
                      <Avatar uri={request.requester.avatar_url} name={name} size={36} />
                      <View style={styles.requestNameCol}>
                        <ThemedText type="small">{name}</ThemedText>
                        {request.requester.username ? (
                          <ThemedText type="small" themeColor="textSecondary">
                            @{request.requester.username}
                          </ThemedText>
                        ) : null}
                      </View>
                    </Pressable>

                    <View style={styles.requestActions}>
                      <Pressable
                        onPress={() => handleAccept(request.connectionId)}
                        disabled={isResponding}
                        accessibilityRole="button"
                        accessibilityLabel={`Accept ${name}`}
                        style={({ pressed }) => [
                          styles.smallButton,
                          { backgroundColor: AccentColor, opacity: isResponding ? 0.6 : 1 },
                          pressed && styles.buttonPressed,
                        ]}>
                        <ThemedText type="small" style={styles.buttonLabel}>
                          Accept
                        </ThemedText>
                      </Pressable>
                      <Pressable
                        onPress={() => handleDecline(request.connectionId)}
                        disabled={isResponding}
                        accessibilityRole="button"
                        accessibilityLabel={`Decline ${name}`}
                        style={({ pressed }) => [
                          styles.smallButton,
                          styles.declineButton,
                          { opacity: isResponding ? 0.6 : 1 },
                          pressed && styles.buttonPressed,
                        ]}>
                        <ThemedText type="small" themeColor="textSecondary">
                          Decline
                        </ThemedText>
                      </Pressable>
                    </View>
                  </View>
                );
              })}
            </ThemedView>
          ) : null}
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
  scrollView: {
    flex: 1,
  },
  scrollContent: {
    flexGrow: 1,
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    paddingBottom: BottomTabInset + Spacing.three,
    gap: Spacing.three,
  },
  card: {
    alignSelf: 'stretch',
    alignItems: 'center',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    borderRadius: Spacing.four,
    maxWidth: MaxContentWidth,
  },
  settingsLink: {
    alignSelf: 'flex-end',
    paddingVertical: Spacing.one,
    paddingHorizontal: Spacing.two,
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
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
  requestsCard: {
    alignSelf: 'stretch',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.four,
    borderRadius: Spacing.four,
    maxWidth: MaxContentWidth,
  },
  requestRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: Spacing.two,
  },
  requestInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    flex: 1,
  },
  requestNameCol: {
    flexShrink: 1,
  },
  requestActions: {
    flexDirection: 'row',
    gap: Spacing.one,
  },
  smallButton: {
    paddingVertical: Spacing.one,
    paddingHorizontal: Spacing.two,
    borderRadius: Spacing.three,
    alignItems: 'center',
    justifyContent: 'center',
  },
  declineButton: {
    backgroundColor: 'transparent',
  },
});
