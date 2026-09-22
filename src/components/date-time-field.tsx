// Shared props for the platform-specific pickers in date-time-field.ios.tsx
// and date-time-field.android.tsx — Metro picks the right file per
// platform. This base file only exists so TypeScript (and web, which the
// Map tab doesn't support anyway) has something to resolve the import to.
import { StyleSheet } from 'react-native';

import { ThemedText } from '@/components/themed-text';

export type DateTimeFieldProps = {
  value: Date;
  onChange: (date: Date) => void;
  minimumDate?: Date;
  accessibilityLabel: string;
};

export function DateTimeField({ value }: DateTimeFieldProps) {
  return (
    <ThemedText type="default" style={styles.text}>
      {value.toLocaleString()}
    </ThemedText>
  );
}

const styles = StyleSheet.create({
  text: {
    paddingVertical: 8,
  },
});
