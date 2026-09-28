import { FlatList, Modal, Pressable, StyleSheet, View } from 'react-native';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import type { ConnectionLocation } from '@/lib/types';

type ClusterListModalProps = {
  visible: boolean;
  members: ConnectionLocation[];
  onClose: () => void;
  onSelect: (id: string) => void;
};

export function ClusterListModal({ visible, members, onClose, onSelect }: ClusterListModalProps) {
  const theme = useTheme();
  // Pressed rows get a solid highlight rather than fading, so the text
  // stays at full contrast.
  const pressedStyle = { backgroundColor: theme.backgroundSelected };

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <View style={[styles.backdrop, { backgroundColor: theme.scrim }]}>
        <ThemedView
          type="overlay"
          style={[styles.card, { borderColor: theme.overlayBorder }]}>
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
                  style={({ pressed }) => [styles.row, pressed && pressedStyle]}>
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
            style={({ pressed }) => [styles.closeButton, pressed && pressedStyle]}>
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
    padding: Spacing.four,
  },
  card: {
    width: '100%',
    maxWidth: 360,
    maxHeight: '70%',
    gap: Spacing.two,
    padding: Spacing.four,
    borderRadius: Spacing.four,
    borderWidth: BorderWidth.thin,
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
    paddingVertical: Spacing.one,
    paddingHorizontal: Spacing.two,
    borderRadius: Spacing.three,
  },
  closeButton: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    alignItems: 'center',
    borderRadius: Spacing.three,
  },
});
