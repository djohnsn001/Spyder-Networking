import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, TextInput, View } from 'react-native';
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
import { DiscoverFiltersModal } from '@/components/discover-filters-modal';
import { getBusinessStageLabel } from '@/lib/profile-options';
import {
  countActiveFilters,
  DISCOVER_PAGE_SIZE,
  type DiscoverFilters,
  EMPTY_DISCOVER_FILTERS,
  fetchDiscoverPage,
} from '@/lib/profiles';
import { RateLimitError } from '@/lib/rate-limit';
import { friendlyRpcError } from '@/lib/rpc';
import type { ConnectionRow, ConnectionStatus, DiscoverProfile } from '@/lib/types';

// Wait this long after the last keystroke before searching the server.
const SEARCH_DEBOUNCE_MS = 300;

export default function DiscoverScreen() {
  const theme = useTheme();
  const { session } = useAuth();
  const myId = session?.user.id;

  const [profiles, setProfiles] = useState<DiscoverProfile[]>([]);
  const [connections, setConnections] = useState<ConnectionRow[]>([]);
  const [search, setSearch] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isLoadingMore, setIsLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [pendingId, setPendingId] = useState<string | null>(null);
  const [filters, setFilters] = useState<DiscoverFilters>(EMPTY_DISCOVER_FILTERS);
  const [filtersOpen, setFiltersOpen] = useState(false);
  const activeFilterCount = countActiveFilters(filters);

  // Bumped on every new first-page load, so a slow older response (e.g. for
  // the previous search text) can't overwrite a newer one.
  const requestId = useRef(0);

  useEffect(() => {
    const timer = setTimeout(() => {
      const next = search.trim();
      if (next === debouncedSearch) return;
      // A new search starts again from page 1 (loaded by the effect below).
      setIsLoading(true);
      setLoadError(null);
      setDebouncedSearch(next);
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [search, debouncedSearch]);

  // Page 1 for the current search and filters. Callers set isLoading first;
  // state changes here happen only when the answer arrives.
  const fetchFirstPage = useCallback(() => {
    if (!myId) return;
    const thisRequest = ++requestId.current;
    fetchDiscoverPage(null, debouncedSearch, filters).then(
      (page) => {
        if (thisRequest !== requestId.current) return;
        setProfiles(page);
        setHasMore(page.length === DISCOVER_PAGE_SIZE);
        setIsLoading(false);
      },
      (error) => {
        if (thisRequest !== requestId.current) return;
        setLoadError(friendlyRpcError(error));
        setIsLoading(false);
      },
    );
  }, [myId, debouncedSearch, filters]);

  // Next page, starting after the last profile already on screen. After a
  // failed page it waits for a tap (retry) instead of looping on scroll.
  async function loadMore(retry = false) {
    const last = profiles[profiles.length - 1];
    if (!last || !hasMore || isLoading || isLoadingMore || (loadError && !retry)) return;
    const thisRequest = requestId.current;
    setLoadError(null);
    setIsLoadingMore(true);
    try {
      const page = await fetchDiscoverPage(last.cursor, debouncedSearch, filters);
      if (thisRequest !== requestId.current) return;
      setProfiles((current) => {
        const known = new Set(current.map((profile) => profile.id));
        return [...current, ...page.filter((profile) => !known.has(profile.id))];
      });
      setHasMore(page.length === DISCOVER_PAGE_SIZE);
    } catch (error) {
      if (thisRequest !== requestId.current) return;
      setLoadError(friendlyRpcError(error));
    } finally {
      setIsLoadingMore(false);
    }
  }

  // New filters start again from page 1 (loaded by the effect below).
  function applyFilters(next: DiscoverFilters) {
    setFiltersOpen(false);
    if (JSON.stringify(next) === JSON.stringify(filters)) return;
    setIsLoading(true);
    setLoadError(null);
    setFilters(next);
  }

  // New search text or filters (and the first visit) start again from page 1.
  useEffect(() => {
    fetchFirstPage();
  }, [fetchFirstPage]);

  const loadConnections = useCallback(async () => {
    if (!myId) return;
    setConnections(await fetchMyConnections(myId));
  }, [myId]);

  // Coming back to the tab keeps the pages already scrolled through, and
  // only refreshes connection status (it may have changed on a profile).
  useFocusEffect(
    useCallback(() => {
      void loadConnections();
    }, [loadConnections]),
  );

  function handleRefresh() {
    if (!myId) return;
    setIsLoading(true);
    setLoadError(null);
    fetchFirstPage();
    void loadConnections();
  }

  async function handleConnectPress(profile: DiscoverProfile) {
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
      if (error instanceof RateLimitError) Alert.alert(error.title, error.message);
      else console.error('Failed to update connection', error);
    } finally {
      setPendingId(null);
    }
  }

  async function handleRespond(profile: DiscoverProfile, connectionId: string, accept: boolean) {
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

          <View style={styles.searchRow}>
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
            <Pressable
              onPress={() => setFiltersOpen(true)}
              accessibilityRole="button"
              accessibilityLabel={
                activeFilterCount > 0 ? `Filters, ${activeFilterCount} active` : 'Filters'
              }
              style={({ pressed }) => [
                styles.filterButton,
                {
                  backgroundColor:
                    activeFilterCount > 0 ? theme.secondaryAccent : theme.backgroundSelected,
                },
                pressed && styles.cardPressed,
              ]}>
              <ThemedText
                type="smallBold"
                themeColor={activeFilterCount > 0 ? 'onSecondaryAccent' : 'text'}>
                {activeFilterCount > 0 ? `Filters (${activeFilterCount})` : 'Filters'}
              </ThemedText>
            </Pressable>
          </View>

          {activeFilterCount > 0 ? (
            <View style={styles.activeFiltersRow}>
              <ThemedText type="small" themeColor="textSecondary" style={styles.activeFiltersText} numberOfLines={1}>
                {[
                  ...filters.stages.map((stage) => getBusinessStageLabel(stage)),
                  ...filters.interests,
                  filters.city,
                ]
                  .filter(Boolean)
                  .join(' · ')}
              </ThemedText>
              <Pressable
                onPress={() => applyFilters(EMPTY_DISCOVER_FILTERS)}
                accessibilityRole="button"
                hitSlop={Spacing.two}>
                <ThemedText type="small" themeColor="accentText">
                  Clear
                </ThemedText>
              </Pressable>
            </View>
          ) : null}

          <DiscoverFiltersModal
            visible={filtersOpen}
            filters={filters}
            onClose={() => setFiltersOpen(false)}
            onApply={applyFilters}
          />

          <FlatList
            data={profiles}
            keyExtractor={(item) => item.id}
            contentContainerStyle={styles.listContent}
            refreshing={isLoading}
            onRefresh={handleRefresh}
            onEndReached={() => void loadMore()}
            onEndReachedThreshold={0.5}
            ListEmptyComponent={
              !isLoading && !loadError ? (
                <ThemedText type="small" themeColor="textSecondary" style={styles.emptyText}>
                  {debouncedSearch || activeFilterCount > 0
                    ? 'No one matches that search or those filters yet.'
                    : 'No other builders here yet — check back soon.'}
                </ThemedText>
              ) : null
            }
            ListFooterComponent={
              loadError ? (
                <Pressable
                  onPress={profiles.length > 0 ? () => void loadMore(true) : handleRefresh}
                  accessibilityRole="button"
                  style={styles.footer}>
                  <ThemedText type="small" themeColor="textSecondary" style={styles.footerText}>
                    {loadError} Tap to try again.
                  </ThemedText>
                </Pressable>
              ) : isLoadingMore ? (
                <ActivityIndicator style={styles.footer} />
              ) : null
            }
            renderItem={({ item }) => {
              const displayName = item.full_name || item.username || '';
              const businessStageLabel = getBusinessStageLabel(item.business_stage);
              const { status, connectionId, level } = myId
                ? getConnectionStatus(connections, myId, item.id)
                : { status: 'none' as ConnectionStatus, connectionId: null, level: null };

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
                        level={level}
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
  searchRow: {
    flexDirection: 'row',
    gap: Spacing.two,
    marginBottom: Spacing.three,
  },
  searchInput: {
    flex: 1,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  filterButton: {
    justifyContent: 'center',
    paddingHorizontal: Spacing.three,
    borderRadius: Spacing.three,
  },
  activeFiltersRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    marginTop: -Spacing.two,
    marginBottom: Spacing.three,
  },
  activeFiltersText: {
    flex: 1,
  },
  listContent: {
    gap: Spacing.three,
    paddingBottom: BottomTabInset + Spacing.four,
  },
  emptyText: {
    textAlign: 'center',
    marginTop: Spacing.five,
  },
  footer: {
    paddingVertical: Spacing.three,
  },
  footerText: {
    textAlign: 'center',
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
