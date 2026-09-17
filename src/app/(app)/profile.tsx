import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, DangerColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  acceptConnectionRequest,
  fetchPendingRequests,
  removeConnection,
  type PendingRequest,
} from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { supabase } from '@/lib/supabase';

function getInitials(name: string) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

export default function ProfileScreen() {
  const { session, profile } = useAuth();

  const [requests, setRequests] = useState<PendingRequest[]>([]);
  const [respondingId, setRespondingId] = useState<string | null>(null);

  const loadRequests = useCallback(async () => {
    if (!session) return;
    setRequests(await fetchPendingRequests(session.user.id));
  }, [session]);

  useEffect(() => {
    void Promise.resolve().then(loadRequests);
  }, [loadRequests]);

  async function handleAccept(connectionId: string) {
    setRespondingId(connectionId);
    try {
      await acceptConnectionRequest(connectionId);
      setRequests((current) => current.filter((request) => request.connectionId !== connectionId));
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
          <ThemedView type="backgroundElement" style={styles.card}>
            <ThemedView type="backgroundSelected" style={styles.avatar}>
              <ThemedText type="subtitle">{getInitials(displayName)}</ThemedText>
            </ThemedView>

            <ThemedText type="subtitle" style={styles.centerText}>
              {displayName}
            </ThemedText>

            {profile?.username ? (
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                @{profile.username}
              </ThemedText>
            ) : null}

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

            <Pressable
              onPress={() => router.push('/edit-profile')}
              accessibilityRole="button"
              accessibilityLabel="Edit profile"
              style={({ pressed }) => [
                styles.button,
                { backgroundColor: AccentColor },
                pressed && styles.buttonPressed,
              ]}>
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Edit Profile
              </ThemedText>
            </Pressable>

            <Pressable
              onPress={() => supabase.auth.signOut()}
              accessibilityRole="button"
              accessibilityLabel="Log out"
              style={({ pressed }) => [
                styles.button,
                { backgroundColor: DangerColor },
                pressed && styles.buttonPressed,
              ]}>
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Log out
              </ThemedText>
            </Pressable>
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
                      <ThemedView type="backgroundSelected" style={styles.requestAvatar}>
                        <ThemedText type="small">{getInitials(name)}</ThemedText>
                      </ThemedView>
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
  button: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    paddingHorizontal: Spacing.five,
    borderRadius: Spacing.four,
    alignItems: 'center',
    minWidth: 180,
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#ffffff',
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
  requestAvatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
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
