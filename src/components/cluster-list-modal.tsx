import { FlatList, Modal, Pressable, StyleSheet, View } from 'react-native';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import type { ConnectionLocation } from '@/lib/types';

type ClusterListModalProps = {
  visible: boolean;
  members: ConnectionLocation[];
  onClose: () => void;
  onSelect: (id: string) => void;
};

export function ClusterListModal({ visible, members, onClose, onSelect }: ClusterListModalProps) {
  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <ThemedView type="backgroundElement" style={styles.card}>
          <ThemedText type="smallBold" style={styles.title}>
            {members.length} builders in this area
          </ThemedText>

          <FlatList
            data={members}
            keyExtractor={(item) => item.id}
            style={styles.list}
            ItemSeparatorComponent={() => <View style={styles.separator} />}
            renderItem={({ item }) => {
              const displayName = item.full_name || item.username || '';
              return (
                <Pressable
                  onPress={() => onSelect(item.id)}
                  accessibilityRole="button"
                  accessibilityLabel={`View ${displayName}'s profile`}
                  style={({ pressed }) => [styles.row, pressed && styles.rowPressed]}>
                  <Avatar uri={item.avatar_url} name={displayName} size={36} />
                  <ThemedText type="default">{displayName}</ThemedText>
                </Pressable>
              );
            }}
          />

          <Pressable
            onPress={onClose}
            accessibilityRole="button"
            accessibilityLabel="Close"
            style={({ pressed }) => [styles.closeButton, pressed && styles.rowPressed]}>
            <ThemedText type="smallBold">Close</ThemedText>
          </Pressable>
        </ThemedView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    padding: Spacing.four,
  },
  card: {
    width: '100%',
    maxWidth: 360,
    maxHeight: '70%',
    gap: Spacing.two,
    padding: Spacing.four,
    borderRadius: Spacing.four,
  },
  title: {
    textAlign: 'center',
    marginBottom: Spacing.one,
  },
  list: {
    flexGrow: 0,
  },
  separator: {
    height: Spacing.two,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
  },
  rowPressed: {
    opacity: 0.7,
  },
  closeButton: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    alignItems: 'center',
  },
});
