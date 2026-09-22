import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { FlatList, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { fetchConnectionProfiles } from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';
import type { Profile } from '@/lib/types';

export default function ConnectionsScreen() {
  const { session } = useAuth();
  const myId = session?.user.id;

  const [connections, setConnections] = useState<Profile[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const load = useCallback(async () => {
    if (!myId) return;
    setIsLoading(true);
    setConnections(await fetchConnectionProfiles(myId));
    setIsLoading(false);
  }, [myId]);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.content}>
          <FlatList
            data={connections}
            keyExtractor={(item) => item.id}
            contentContainerStyle={styles.listContent}
            refreshing={isLoading}
            onRefresh={load}
            ListEmptyComponent={
              !isLoading ? (
                <ThemedText type="small" themeColor="textSecondary" style={styles.emptyText}>
                  No connections yet — go find some builders in Discover.
                </ThemedText>
              ) : null
            }
            renderItem={({ item }) => {
              const displayName = item.full_name || item.username || '';
              const businessStageLabel = getBusinessStageLabel(item.business_stage);

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
                      {item.city || businessStageLabel ? (
                        <ThemedText type="small" themeColor="textSecondary">
                          {[item.city, businessStageLabel].filter(Boolean).join(' · ')}
                        </ThemedText>
                      ) : null}
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
  listContent: {
    gap: Spacing.three,
    paddingTop: Spacing.three,
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
});
