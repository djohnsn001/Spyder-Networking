import { router, useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { Pressable, SectionList, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { LevelChip } from '@/components/connect/level-chip';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BottomTabInset, MaxContentWidth, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { CONNECTION_LEVEL_LABEL_PLURAL } from '@/lib/connect/labels';
import { fetchConnectionsByLevel, type ConnectionWithProfile } from '@/lib/connections';
import { getBusinessStageLabel } from '@/lib/profile-options';

export default function ConnectionsScreen() {
  const { session } = useAuth();
  const myId = session?.user.id;

  const [connections, setConnections] = useState<ConnectionWithProfile[]>([]);
  const [isLoading, setIsLoading] = useState(true);

  const load = useCallback(async () => {
    if (!myId) return;
    setIsLoading(true);
    setConnections(await fetchConnectionsByLevel(myId));
    setIsLoading(false);
  }, [myId]);

  const sections = [
    {
      title: CONNECTION_LEVEL_LABEL_PLURAL.in_person,
      data: connections.filter((c) => c.level === 'in_person'),
    },
    {
      title: CONNECTION_LEVEL_LABEL_PLURAL.acquaintance,
      data: connections.filter((c) => c.level === 'acquaintance'),
    },
  ].filter((section) => section.data.length > 0);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.content}>
          <SectionList
            sections={sections}
            keyExtractor={(item) => item.connectionId}
            stickySectionHeadersEnabled={false}
            renderSectionHeader={({ section }) => (
              <ThemedText type="smallBold" themeColor="textSecondary" style={styles.sectionHeader}>
                {section.title} ({section.data.length})
              </ThemedText>
            )}
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
            renderItem={({ item: connection }) => {
              const item = connection.profile;
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
                      {connection.level === 'in_person' ? (
                        <LevelChip
                          level="in_person"
                          metAt={connection.metAt}
                          metCity={connection.metCity}
                        />
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
  sectionHeader: {
    marginTop: Spacing.two,
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
