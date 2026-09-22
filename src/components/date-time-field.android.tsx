import { DatePickerDialog, Host, TimePickerDialog } from '@expo/ui/jetpack-compose';
import { useState } from 'react';
import { Pressable, StyleSheet } from 'react-native';

import type { DateTimeFieldProps } from '@/components/date-time-field';
import { ThemedText } from '@/components/themed-text';
import { AccentColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';

type Step = 'closed' | 'date' | 'time';

// Android: Material's pickers can't do date and time in one control, so
// tapping the field opens the date dialog, then the time dialog.
export function DateTimeField({ value, onChange, minimumDate, accessibilityLabel }: DateTimeFieldProps) {
  const theme = useTheme();
  const [step, setStep] = useState<Step>('closed');
  // The day picked in step 1, carried into the time dialog.
  const [pendingDate, setPendingDate] = useState(value);

  const label = value.toLocaleString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });

  return (
    <>
      <Pressable
        onPress={() => setStep('date')}
        accessibilityRole="button"
        accessibilityLabel={`${accessibilityLabel}: ${label}`}
        style={({ pressed }) => [
          styles.field,
          { backgroundColor: theme.backgroundSelected },
          pressed && styles.pressed,
        ]}>
        <ThemedText type="default">{label}</ThemedText>
      </Pressable>

      {step === 'date' ? (
        <Host matchContents>
          <DatePickerDialog
            initialDate={value.toISOString()}
            color={AccentColor}
            selectableDates={minimumDate ? { start: minimumDate } : undefined}
            onDateSelected={(picked) => {
              // Material reports the chosen day as midnight UTC, so read the
              // calendar day in UTC and keep the current local time of day.
              const next = new Date(value);
              next.setFullYear(picked.getUTCFullYear(), picked.getUTCMonth(), picked.getUTCDate());
              setPendingDate(next);
              setStep('time');
            }}
            onDismissRequest={() => setStep('closed')}
          />
        </Host>
      ) : null}

      {step === 'time' ? (
        <Host matchContents>
          <TimePickerDialog
            initialDate={pendingDate.toISOString()}
            color={AccentColor}
            is24Hour={false}
            onDateSelected={(picked) => {
              setStep('closed');
              onChange(picked);
            }}
            onDismissRequest={() => setStep('closed')}
          />
        </Host>
      ) : null}
    </>
  );
}

const styles = StyleSheet.create({
  field: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
  },
  pressed: {
    opacity: 0.8,
  },
});
