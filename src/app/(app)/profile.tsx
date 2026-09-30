import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { LookingForTags } from '@/components/looking-for-tags';
import { BadgesSection, FeaturedBadges, useProfileBadges } from '@/components/profile-badges';
import { ProfileStatsRow } from '@/components/profile-stats';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  type EarnedBadge,
  fetchProfileStats,
  missingForMemberNumber,
  type ProfileStats,
} from '@/lib/badges';
import {
  acceptConnectionRequest,
  fetchPendingRequests,
  removeConnection,
  type PendingRequest,
} from '@/lib/connections';
import { confirmLookingFor, isLookingForStale, LookingForStaleDays } from '@/lib/looking-for';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { friendlyRpcError } from '@/lib/rpc';

export default function ProfileScreen() {
  const { session, profile, refreshProfile } = useAuth();

  const [requests, setRequests] = useState<PendingRequest[]>([]);
  const [respondingId, setRespondingId] = useState<string | null>(null);
  const [stats, setStats] = useState<ProfileStats | null>(null);
  const [selectedBadge, setSelectedBadge] = useState<EarnedBadge | null>(null);
  const [isConfirmingTags, setIsConfirmingTags] = useState(false);
  const [tagsError, setTagsError] = useState<string | null>(null);
  const myId = session?.user.id;
  const { definitions, badges, reload: reloadBadges } = useProfileBadges(myId);

  const loadStats = useCallback(async () => {
    if (!myId) return;
    try {
      setStats(await fetchProfileStats(myId));
    } catch (error) {
      if (__DEV__) console.warn('Failed to load stats', error);
    }
  }, [myId]);

  const loadRequests = useCallback(async () => {
    if (!myId) return;
    setRequests(await fetchPendingRequests(myId));
  }, [myId]);

  useFocusEffect(
    useCallback(() => {
      void loadRequests();
      void loadStats();
      void reloadBadges();
    }, [loadRequests, loadStats, reloadBadges]),
  );

  async function handleAccept(connectionId: string) {
    setRespondingId(connectionId);
    try {
      await acceptConnectionRequest(connectionId);
      setRequests((current) => current.filter((request) => request.connectionId !== connectionId));
      void loadStats();
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

  async function handleConfirmTags() {
    setTagsError(null);
    setIsConfirmingTags(true);
    try {
      await confirmLookingFor();
      await refreshProfile();
    } catch (error) {
      setTagsError(friendlyRpcError(error));
    } finally {
      setIsConfirmingTags(false);
    }
  }

  const displayName = profile?.full_name || profile?.username || session?.user.email || '';
  const businessStageLabel = getBusinessStageLabel(profile?.business_stage ?? null);
  const hasTags = (profile?.looking_for?.length ?? 0) > 0;
  const tagsAreStale = hasTags && isLookingForStale(profile?.tags_updated_at);
  const missingFields = missingForMemberNumber(profile);

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

            <FeaturedBadges definitions={definitions} badges={badges} onPressBadge={setSelectedBadge} />

            <ProfileStatsRow stats={stats} onPressInPerson={() => router.push('/connections')} />

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

            {hasTags ? (
              <LookingForTags tags={profile?.looking_for} updatedAt={profile?.tags_updated_at} />
            ) : (
              <Pressable
                onPress={() => router.push('/edit-profile')}
                accessibilityRole="button"
                accessibilityLabel="Add what you're looking for">
                <ThemedText type="small" themeColor="accentText" style={styles.centerText}>
                  + Add what you&apos;re looking for
                </ThemedText>
              </Pressable>
            )}

            <BadgesSection
              definitions={definitions}
              badges={badges}
              isOwn
              selected={selectedBadge}
              onSelect={setSelectedBadge}
              onChanged={() => void reloadBadges()}
            />
          </ThemedView>

          {missingFields.length > 0 ? (
            <ThemedView type="backgroundElement" style={styles.staleCard}>
              <ThemedText type="smallBold">Claim your member number</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                Add {missingFields.slice(0, -1).join(', ')}
                {missingFields.length > 1 ? ' and ' : ''}
                {missingFields[missingFields.length - 1]} to finish your profile. Finished profiles get a
                numbered member badge, and the first 200 are Founders.
              </ThemedText>
              <View style={styles.staleActions}>
                <Pressable
                  onPress={() => router.push('/edit-profile')}
                  accessibilityRole="button"
                  accessibilityLabel="Finish your profile"
                  style={({ pressed }) => [
                    styles.smallButton,
                    styles.staleButton,
                    { backgroundColor: AccentColor },
                    pressed && styles.buttonPressed,
                  ]}>
                  <ThemedText type="small" style={styles.buttonLabel}>
                    Finish profile
                  </ThemedText>
                </Pressable>
              </View>
            </ThemedView>
          ) : null}

          {tagsAreStale ? (
            <ThemedView type="backgroundElement" style={styles.staleCard}>
              <ThemedText type="smallBold">Still looking for the same things?</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                Your Looking For tags are over {LookingForStaleDays} days old, so they&apos;ve
                dropped to the bottom of other people&apos;s suggestions.
              </ThemedText>
              <View style={styles.staleActions}>
                <Pressable
                  onPress={handleConfirmTags}
                  disabled={isConfirmingTags}
                  accessibilityRole="button"
                  accessibilityLabel="Keep my Looking For tags"
                  style={({ pressed }) => [
                    styles.smallButton,
                    styles.staleButton,
                    { backgroundColor: AccentColor, opacity: isConfirmingTags ? 0.6 : 1 },
                    pressed && styles.buttonPressed,
                  ]}>
                  {isConfirmingTags ? (
                    <ActivityIndicator color="#fdfbf7" />
                  ) : (
                    <ThemedText type="small" style={styles.buttonLabel}>
                      Still accurate
                    </ThemedText>
                  )}
                </Pressable>
                <Pressable
                  onPress={() => router.push('/edit-profile')}
                  accessibilityRole="button"
                  accessibilityLabel="Update my Looking For tags"
                  style={({ pressed }) => [
                    styles.smallButton,
                    styles.staleButton,
                    pressed && styles.buttonPressed,
                  ]}>
                  <ThemedText type="small" themeColor="accentText">
                    Update
                  </ThemedText>
                </Pressable>
              </View>
              {tagsError ? (
                <ThemedText type="small" themeColor="error">
                  {tagsError}
                </ThemedText>
              ) : null}
            </ThemedView>
          ) : null}

          <Pressable
            onPress={() => router.push('/connect')}
            accessibilityRole="button"
            accessibilityLabel="Connect in person"
            style={({ pressed }) => [styles.connectButton, pressed && styles.buttonPressed]}>
            <ThemedText type="smallBold" style={styles.buttonLabel}>
              Connect in person
            </ThemedText>
          </Pressable>

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
  connectButton: {
    alignSelf: 'stretch',
    maxWidth: MaxContentWidth,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
    alignItems: 'center',
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
  staleCard: {
    alignSelf: 'stretch',
    gap: Spacing.two,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.four,
    borderRadius: Spacing.four,
    maxWidth: MaxContentWidth,
  },
  staleActions: {
    flexDirection: 'row',
    gap: Spacing.two,
    marginTop: Spacing.one,
  },
  staleButton: {
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.three,
    minWidth: 110,
  },
});
