import { router, useFocusEffect } from 'expo-router';
import { useCallback, useMemo, useState } from 'react';
import { FlatList, Pressable, StyleSheet, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ConnectButton } from '@/components/connect-button';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import {
  acceptConnectionRequest,
  fetchMyConnections,
  getConnectionStatus,
  removeConnection,
  sendConnectionRequest,
} from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';
import { supabase } from '@/lib/supabase';
import type { ConnectionRow, ConnectionStatus, Profile } from '@/lib/types';

export default function DiscoverScreen() {
  const theme = useTheme();
  const { session } = useAuth();
  const myId = session?.user.id;

  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [search, setSearch] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [pendingId, setPendingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!myId) return;
    setIsLoading(true);
    const [profilesResult, myConnections] = await Promise.all([
      supabase.from('profiles').select('*').neq('id', myId).not('username', 'is', null),
      fetchMyConnections(myId),
    ]);
    if (profilesResult.error) {
      console.error('Failed to load profiles', profilesResult.error);
    } else {
      setProfiles(profilesResult.data ?? []);
    }
    setConnections(myConnections);
    setIsLoading(false);
  }, [myId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  const filteredProfiles = useMemo(() => {
    const query = search.trim().toLowerCase();
    if (!query) return profiles;
    return profiles.filter((profile) => {
      const haystack = [profile.full_name, profile.username, ...profile.interests]
        .filter(Boolean)
        .join(' ')
        .toLowerCase();
      return haystack.includes(query);
    });
  }, [profiles, search]);

  async function handleConnectPress(profile: Profile) {
    if (!myId) return;
    const { status, connectionId } = getConnectionStatus(connections, myId, profile.id);
    setPendingId(profile.id);
    try {
      if (status === 'none') {
        await sendConnectionRequest(myId, profile.id);
      } else if ((status === 'pending_sent' || status === 'accepted') && connectionId) {
        await removeConnection(connectionId);
      }
      setConnections(await fetchMyConnections(myId));
    } catch (error) {
      console.error('Failed to update connection', error);
    } finally {
      setPendingId(null);
    }
  }

  async function handleRespond(profile: Profile, connectionId: string, accept: boolean) {
    if (!myId) return;
    setPendingId(profile.id);
    try {
      if (accept) {
        await acceptConnectionRequest(connectionId);
      } else {
        await removeConnection(connectionId);
      }
      setConnections(await fetchMyConnections(myId));
    } catch (error) {
      console.error('Failed to respond to request', error);
    } finally {
      setPendingId(null);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.content}>
          <ThemedText type="subtitle" style={styles.title}>
            Discover
          </ThemedText>

          <TextInput
            value={search}
            onChangeText={setSearch}
            placeholder="Search by name or interest"
            placeholderTextColor={theme.textSecondary}
            autoCapitalize="none"
            autoCorrect={false}
            style={[
              styles.searchInput,
              { color: theme.text, backgroundColor: theme.backgroundSelected },
            ]}
          />

          <FlatList
            data={filteredProfiles}
            keyExtractor={(item) => item.id}
            contentContainerStyle={styles.listContent}
            refreshing={isLoading}
            onRefresh={load}
            ListEmptyComponent={
              !isLoading ? (
                <ThemedText type="small" themeColor="textSecondary" style={styles.emptyText}>
                  {search
                    ? 'No one matches that search yet.'
                    : 'No other builders here yet — check back soon.'}
                </ThemedText>
              ) : null
            }
            renderItem={({ item }) => {
              const displayName = item.full_name || item.username || '';
              const businessStageLabel = getBusinessStageLabel(item.business_stage);
              const { status, connectionId } = myId
                ? getConnectionStatus(connections, myId, item.id)
                : { status: 'none' as ConnectionStatus, connectionId: null };

              return (
                <Pressable
                  onPress={() => router.push(`/user/${item.id}`)}
                  accessibilityRole="button"
                  accessibilityLabel={`View ${displayName}'s profile`}
                  style={({ pressed }) => pressed && styles.cardPressed}>
                  <ThemedView type="backgroundElement" style={styles.card}>
                    <Avatar uri={item.avatar_url} name={displayName} size={48} />

                    <View style={styles.cardBody}>
                      <ThemedText type="smallBold">{displayName}</ThemedText>
                      {item.username ? (
                        <ThemedText type="small" themeColor="textSecondary">
                          @{item.username}
                        </ThemedText>
                      ) : null}
                      {item.bio ? (
                        <ThemedText type="small" numberOfLines={2}>
                          {item.bio}
                        </ThemedText>
                      ) : null}
                      {item.city || businessStageLabel ? (
                        <ThemedText type="small" themeColor="textSecondary">
                          {[item.city, businessStageLabel].filter(Boolean).join(' · ')}
                        </ThemedText>
                      ) : null}
                      {item.interests.length > 0 ? (
                        <View style={styles.pillRow}>
                          {item.interests.slice(0, 4).map((interest) => (
                            <ThemedView key={interest} type="backgroundSelected" style={styles.pill}>
                              <ThemedText type="small">{interest}</ThemedText>
                            </ThemedView>
                          ))}
                        </View>
                      ) : null}

                      <ConnectButton
                        status={status}
                        pending={pendingId === item.id}
                        onPress={() => handleConnectPress(item)}
                        onUnconnect={() => handleConnectPress(item)}
                        onAccept={
                          connectionId
                            ? () => handleRespond(item, connectionId, true)
                            : undefined
                        }
                        onDecline={
                          connectionId
                            ? () => handleRespond(item, connectionId, false)
                            : undefined
                        }
                      />
                    </View>
                  </ThemedView>
                </Pressable>
              );
            }}
          />
        </View>
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
  content: {
    flex: 1,
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    paddingHorizontal: Spacing.four,
  },
  title: {
    marginTop: Spacing.three,
    marginBottom: Spacing.three,
  },
  searchInput: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
    marginBottom: Spacing.three,
  },
  listContent: {
    gap: Spacing.three,
    paddingBottom: BottomTabInset + Spacing.four,
  },
  emptyText: {
    textAlign: 'center',
    marginTop: Spacing.five,
  },
  cardPressed: {
    opacity: 0.85,
  },
  card: {
    flexDirection: 'row',
    gap: Spacing.three,
    padding: Spacing.three,
    borderRadius: Spacing.four,
  },
  cardBody: {
    flex: 1,
    gap: Spacing.one,
    alignItems: 'flex-start',
  },
  pillRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.one,
    marginTop: Spacing.one,
  },
  pill: {
    paddingHorizontal: Spacing.two,
    paddingVertical: 4,
    borderRadius: Spacing.four,
  },
});
