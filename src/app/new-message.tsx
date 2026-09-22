import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { ErrorColor, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { fetchConnectionProfiles } from '@/lib/connections';
import { getOrStartDirectConversation } from '@/lib/messages';
import type { Profile } from '@/lib/types';

export default function NewMessageScreen() {
  const { session } = useAuth();
  const myId = session?.user.id;

  const [connections, setConnections] = useState<Profile[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [startingId, setStartingId] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    if (!myId) return;
    (async () => {
      setConnections(await fetchConnectionProfiles(myId));
      setIsLoading(false);
    })();
  }, [myId]);

  async function handleSelect(profile: Profile) {
    if (startingId) return;
    setErrorMessage(null);
    setStartingId(profile.id);
    try {
      const conversationId = await getOrStartDirectConversation(profile.id);
      router.replace(`/chat/${conversationId}`);
    } catch (error) {
      console.error('Failed to start conversation', error);
      setErrorMessage('Could not start that conversation. Try again.');
      setStartingId(null);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <View style={styles.header}>
          <ThemedText type="subtitle">New Message</ThemedText>
          <Pressable
            onPress={() => router.back()}
            accessibilityRole="button"
            accessibilityLabel="Cancel">
            <ThemedText type="smallBold" themeColor="textSecondary">
              Cancel
            </ThemedText>
          </Pressable>
        </View>

        {errorMessage ? (
          <ThemedText type="small" style={styles.errorText}>
            {errorMessage}
          </ThemedText>
        ) : null}

        {isLoading ? (
          <ActivityIndicator style={styles.loading} />
        ) : (
          <FlatList
            data={connections}
            keyExtractor={(item) => item.id}
            contentContainerStyle={styles.listContent}
            ListEmptyComponent={
              <ThemedText type="small" themeColor="textSecondary" style={styles.emptyText}>
                You don&apos;t have any connections yet — add some in Discover first.
              </ThemedText>
            }
            renderItem={({ item }) => {
              const displayName = item.full_name || item.username || '';
              return (
                <Pressable
                  onPress={() => handleSelect(item)}
                  disabled={startingId !== null}
                  accessibilityRole="button"
                  accessibilityLabel={`Message ${displayName}`}
                  style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
                  <Avatar uri={item.avatar_url} name={displayName} size={44} />
                  <View style={styles.rowBody}>
                    <ThemedText type="smallBold">{displayName}</ThemedText>
                    {item.username ? (
                      <ThemedText type="small" themeColor="textSecondary">
                        @{item.username}
                      </ThemedText>
                    ) : null}
                  </View>
                  {startingId === item.id ? <ActivityIndicator /> : null}
                </Pressable>
              );
            }}
          />
        )}
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
    paddingHorizontal: Spacing.four,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: Spacing.three,
  },
  loading: {
    marginTop: Spacing.five,
  },
  listContent: {
    gap: Spacing.one,
    paddingBottom: Spacing.four,
  },
  emptyText: {
    textAlign: 'center',
    marginTop: Spacing.five,
  },
  errorText: {
    color: ErrorColor,
    textAlign: 'center',
    marginBottom: Spacing.two,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    paddingVertical: Spacing.two,
  },
  rowPressed: {
    opacity: 0.7,
  },
  rowBody: {
    flex: 1,
    gap: Spacing.half,
  },
});
