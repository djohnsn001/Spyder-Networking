import { Image } from 'expo-image';
import { StyleSheet } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';

export function getInitials(name: string) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

type AvatarProps = {
  uri: string | null;
  name: string;
  size: number;
};

export function Avatar({ uri, name, size }: AvatarProps) {
  const dimensions = { width: size, height: size, borderRadius: size / 2 };

  if (uri) {
    return (
      <Image
        source={{ uri }}
        style={dimensions}
        accessible
        accessibilityLabel={name ? `${name}'s profile picture` : 'Profile picture'}
      />
    );
  }

  return (
    <ThemedView
      type="backgroundSelected"
      style={[styles.fallback, dimensions]}
      accessible
      accessibilityLabel={name ? `${name}'s profile picture` : 'Profile picture'}>
      <ThemedText type={size >= 72 ? 'subtitle' : size >= 40 ? 'smallBold' : 'small'}>
        {getInitials(name)}
      </ThemedText>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  fallback: {
    alignItems: 'center',
    justifyContent: 'center',
  },
});
