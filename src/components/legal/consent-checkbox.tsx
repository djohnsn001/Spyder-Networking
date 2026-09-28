import { Pressable, StyleSheet, View } from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { AccentColor, BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { LEGAL, openLegalUrl } from '@/lib/legal/config';

const BOX_SIZE = 22;

// "I'm 18 or older and I agree to the Terms and Privacy Policy."
// Always starts unchecked: a pre-checked box is a dark pattern and weakens
// the agreement (clickwrap needs a real, active "yes").
export function ConsentCheckbox({
  checked,
  onChange,
  disabled,
}: {
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
}) {
  const theme = useTheme();

  return (
    <View style={styles.row}>
      <Pressable
        onPress={() => onChange(!checked)}
        disabled={disabled}
        // 22 pt box + 12 pt on each side = a 46 pt tap target (44 minimum).
        hitSlop={12}
        accessibilityRole="checkbox"
        accessibilityState={{ checked, disabled }}
        accessibilityLabel={`I'm ${LEGAL.MIN_AGE} or older and I agree to the Terms and Privacy Policy`}
        style={[
          styles.box,
          {
            borderColor: checked ? AccentColor : theme.textSecondary,
            backgroundColor: checked ? AccentColor : 'transparent',
          },
        ]}>
        {checked ? (
          <ThemedText type="smallBold" style={styles.check}>
            ✓
          </ThemedText>
        ) : null}
      </Pressable>

      {/* The sentence toggles the box too; the two links open the pages. */}
      <ThemedText
        type="small"
        style={styles.label}
        onPress={disabled ? undefined : () => onChange(!checked)}
        accessibilityElementsHidden
        importantForAccessibility="no-hide-descendants">
        {`I'm ${LEGAL.MIN_AGE} or older and I agree to the `}
        <ThemedText
          type="small"
          themeColor="secondaryAccent"
          style={styles.link}
          onPress={() => void openLegalUrl(LEGAL.TERMS_URL)}>
          Terms
        </ThemedText>
        {' and '}
        <ThemedText
          type="small"
          themeColor="secondaryAccent"
          style={styles.link}
          onPress={() => void openLegalUrl(LEGAL.PRIVACY_URL)}>
          Privacy Policy
        </ThemedText>
        .
      </ThemedText>

      {/* Screen readers can't reach links nested in text, so give them
          their own buttons. */}
      <View style={styles.srLinks}>
        <Pressable
          onPress={() => void openLegalUrl(LEGAL.TERMS_URL)}
          accessibilityRole="link"
          accessibilityLabel="Read the Terms"
          style={styles.srOnly}
        />
        <Pressable
          onPress={() => void openLegalUrl(LEGAL.PRIVACY_URL)}
          accessibilityRole="link"
          accessibilityLabel="Read the Privacy Policy"
          style={styles.srOnly}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.three,
  },
  box: {
    width: BOX_SIZE,
    height: BOX_SIZE,
    borderRadius: 6,
    borderWidth: BorderWidth.thick,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 1,
  },
  check: {
    color: '#fdfbf7',
    lineHeight: 18,
  },
  label: {
    flex: 1,
  },
  link: {
    textDecorationLine: 'underline',
  },
  srLinks: {
    position: 'absolute',
    width: 1,
    height: 1,
    overflow: 'hidden',
  },
  srOnly: {
    width: 1,
    height: 1,
  },
});
