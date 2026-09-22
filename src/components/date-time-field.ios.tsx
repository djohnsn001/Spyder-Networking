import { DatePicker, Host } from '@expo/ui/swift-ui';

import type { DateTimeFieldProps } from '@/components/date-time-field';
import { useThemePreference } from '@/lib/theme-preference';

// iOS: SwiftUI's compact DatePicker picks the date and the time in one
// control (two tappable chips that pop open a calendar / time wheel).
export function DateTimeField({ value, onChange, minimumDate, accessibilityLabel }: DateTimeFieldProps) {
  const { resolvedScheme } = useThemePreference();

  return (
    <Host matchContents={{ vertical: true }} colorScheme={resolvedScheme}>
      <DatePicker
        title={accessibilityLabel}
        selection={value}
        displayedComponents={['date', 'hourAndMinute']}
        range={minimumDate ? { start: minimumDate } : undefined}
        onDateChange={onChange}
      />
    </Host>
  );
}
