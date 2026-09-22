import { useLocalSearchParams } from 'expo-router';
import { StyleSheet } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';

// Placeholder so the inbox and "New message" flow have somewhere to
// navigate to. Phase 5 replaces this with the real chat screen.
export default function ChatScreen() {
  const { conversationId } = useLocalSearchParams<{ conversationId: string }>();

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.safeArea}>
        <ThemedText type="default" themeColor="textSecondary" style={styles.text}>
          Conversation {conversationId} — chat screen coming in Phase 5.
        </ThemedText>
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
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: Spacing.four,
  },
  text: {
    textAlign: 'center',
  },
});
