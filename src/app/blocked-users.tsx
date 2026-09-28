import { useFocusEffect } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Alert, FlatList, Pressable, StyleSheet, View } from 'react-native';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { MaxContentWidth, Spacing } from '@/constants/theme';
import { friendlyRpcError } from '@/lib/rpc';
import { fetchBlockedUsers, unblockUser, type BlockedUser } from '@/lib/safety';

// Settings → Blocked users. Only you can see this list; the people on it
// were never told.
export default function BlockedUsersScreen() {
  const [users, setUsers] = useState<BlockedUser[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [unblockingId, setUnblockingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      setUsers(await fetchBlockedUsers());
    } catch (err) {
      setError(friendlyRpcError(err));
    } finally {
      setIsLoading(false);
    }
  }, []);

  useFocusEffect(
    useCallback(() => {
      void load();
    }, [load]),
  );

  function handleUnblock(user: BlockedUser) {
    const name = user.full_name || user.username || 'this person';
    Alert.alert(
      `Unblock ${name}?`,
      "They'll be able to find your profile and send you a connection request again. You won't be reconnected automatically.",
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Unblock',
          onPress: async () => {
            setUnblockingId(user.user_id);
            try {
              await unblockUser(user.user_id);
              setUsers((current) => current.filter((u) => u.user_id !== user.user_id));
            } catch (err) {
              Alert.alert("Couldn't unblock", friendlyRpcError(err));
            } finally {
              setUnblockingId(null);
            }
          },
        },
      ],
    );
  }

  if (isLoading) {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  return (
    <ThemedView style={styles.container}>
      <FlatList
        data={users}
        keyExtractor={(item) => item.user_id}
        contentContainerStyle={styles.content}
        ListHeaderComponent={
          error ? (
            <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
              {error}
            </ThemedText>
          ) : null
        }
        ListEmptyComponent={
          !error ? (
            <View style={styles.empty}>
              <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
                You haven&apos;t blocked anyone.
              </ThemedText>
              <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
                To block someone, open their profile and tap ⋯.
              </ThemedText>
            </View>
          ) : null
        }
        renderItem={({ item }) => {
          const name = item.full_name || item.username || 'Unknown';
          return (
            <ThemedView type="backgroundElement" style={styles.row}>
              <Avatar uri={item.avatar_url} name={name} size={40} />
              <View style={styles.rowText}>
                <ThemedText type="smallBold" numberOfLines={1}>
                  {name}
                </ThemedText>
                {item.username ? (
                  <ThemedText type="small" themeColor="textSecondary" numberOfLines={1}>
                    @{item.username}
                  </ThemedText>
                ) : null}
              </View>
              <Pressable
                onPress={() => handleUnblock(item)}
                disabled={unblockingId === item.user_id}
                hitSlop={Spacing.two}
                accessibilityRole="button"
                accessibilityLabel={`Unblock ${name}`}
                style={({ pressed }) => [styles.unblock, pressed && styles.pressed]}>
                {unblockingId === item.user_id ? (
                  <ActivityIndicator />
                ) : (
                  <ThemedText type="smallBold" themeColor="accentText">
                    Unblock
                  </ThemedText>
                )}
              </Pressable>
            </ThemedView>
          );
        }}
      />
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  content: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    padding: Spacing.four,
    gap: Spacing.two,
  },
  centerText: {
    textAlign: 'center',
  },
  empty: {
    gap: Spacing.two,
    marginTop: Spacing.six,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    padding: Spacing.three,
    borderRadius: Spacing.three,
  },
  rowText: {
    flex: 1,
  },
  unblock: {
    minHeight: 44,
    minWidth: 72,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pressed: {
    opacity: 0.7,
  },
});
