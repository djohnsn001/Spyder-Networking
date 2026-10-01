import { CameraView, useCameraPermissions, type BarcodeScanningResult } from 'expo-camera';
import * as Haptics from 'expo-haptics';
import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Linking, Pressable, StyleSheet, View } from 'react-native';

import { LocationGate } from '@/components/connect/location-gate';
import { ThemedText } from '@/components/themed-text';
import { AccentColor, Spacing } from '@/constants/theme';
import {
  friendlyConnectError,
  LOCATION_MESSAGE,
  redeemConnectToken,
  type InPersonMatch,
} from '@/lib/connect/api';
import { parseCheckinUrl } from '@/lib/checkin';
import { parseConnectUrl } from '@/lib/connect/parse-connect-url';
import type { ConnectLocation } from '@/lib/connect/use-connect-location';

const VIEWFINDER_SIZE = 260;
// How long a "that code expired" style message stays before scanning resumes.
const RESUME_AFTER_MS = 2500;

const RESULT_MESSAGE = {
  expired: 'That code expired. Ask them to refresh.',
  used: 'That code was just used. Scan their new one.',
  self: "That's your own code 🙂",
  invalid: "That's not a Bolas code.",
  ...LOCATION_MESSAGE,
} as const;

// Scanning sends this phone's location with the code: the server only
// connects the two phones if they're together (security item H2). The city
// comes from the same location (or null; the server falls back to a
// profile city). Face to face, so a successful scan connects right away.
export function ScanPanel({
  active,
  location,
  onMatched,
}: {
  active: boolean;
  location: ConnectLocation;
  onMatched: (match: InPersonMatch) => void;
}) {
  const [permission, requestPermission] = useCameraPermissions();
  const [message, setMessage] = useState<string | null>(null);
  const [isRedeeming, setIsRedeeming] = useState(false);
  // A ref, not state: the camera fires many scans per second and state
  // updates land too late to block the next one.
  const busyRef = useRef(false);
  const resumeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Ready for the next person whenever the panel becomes active again
  // (e.g. after the match card closes): clear the old message while
  // rendering (React's pattern for resetting state when a prop changes),
  // and unblock the scanner in the effect.
  const [wasActive, setWasActive] = useState(active);
  if (active !== wasActive) {
    setWasActive(active);
    if (active) setMessage(null);
  }
  useEffect(() => {
    if (active) busyRef.current = false;
    return () => {
      if (resumeTimerRef.current) clearTimeout(resumeTimerRef.current);
    };
  }, [active]);

  function resumeSoon(text: string) {
    setMessage(text);
    resumeTimerRef.current = setTimeout(() => {
      busyRef.current = false;
      setMessage(null);
    }, RESUME_AFTER_MS);
  }

  async function handleScanned({ data }: BarcodeScanningResult) {
    if (busyRef.current) return;
    busyRef.current = true;
    void Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);

    // An event's check-in code: hand it to the check-in screen (which asks
    // first and sends location). The pause stops the camera, which still
    // sees the code, from opening it again.
    const checkinToken = parseCheckinUrl(data);
    if (checkinToken) {
      router.push(`/checkin/${checkinToken}`);
      resumeSoon('Opening check-in…');
      return;
    }

    const token = parseConnectUrl(data);
    if (!token) {
      resumeSoon(RESULT_MESSAGE.invalid);
      return;
    }
    if (!location.fix) {
      resumeSoon('Finding your location… try again in a moment.');
      return;
    }

    setIsRedeeming(true);
    setMessage(null);
    try {
      const result = await redeemConnectToken(token, location.city, location.fix);
      if (result.kind === 'matched') {
        // Stays busy until the match card closes and `active` flips back.
        onMatched(result.match);
      } else {
        void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Warning);
        resumeSoon(RESULT_MESSAGE[result.kind]);
      }
    } catch (error) {
      resumeSoon(friendlyConnectError(error));
    } finally {
      setIsRedeeming(false);
    }
  }

  // Location first (the server requires it), then the camera.
  if (location.status !== 'granted') {
    return <LocationGate location={location} title="Scan a friend's code" />;
  }

  if (!permission) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator color={AccentColor} />
      </View>
    );
  }

  if (!permission.granted) {
    const canAsk = permission.canAskAgain;
    return (
      <View style={styles.centered}>
        <ThemedText type="smallBold" style={styles.center}>
          {canAsk ? "Scan a friend's code" : 'Camera is off for Bolas'}
        </ThemedText>
        <ThemedText type="small" themeColor="textSecondary" style={styles.center}>
          {canAsk
            ? "Bolas uses your camera only to scan someone's code when you meet in person."
            : "Turn on camera access in Settings to scan someone's code."}
        </ThemedText>
        <Pressable
          onPress={() => (canAsk ? requestPermission() : Linking.openSettings())}
          accessibilityRole="button"
          accessibilityLabel={canAsk ? 'Allow camera' : 'Open Settings'}
          style={({ pressed }) => [styles.primaryButton, pressed && styles.pressed]}>
          <ThemedText type="smallBold" style={styles.primaryLabel}>
            {canAsk ? 'Allow camera' : 'Open Settings'}
          </ThemedText>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.viewfinder}>
        {active ? (
          <CameraView
            style={StyleSheet.absoluteFill}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
            onBarcodeScanned={handleScanned}
          />
        ) : null}
        {isRedeeming ? (
          <View style={styles.overlay}>
            <ActivityIndicator color="#ffffff" size="large" />
          </View>
        ) : null}
      </View>

      <ThemedText type="default" themeColor="textSecondary" style={styles.center}>
        {message ?? "Point at their code in Bolas"}
      </ThemedText>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    alignItems: 'center',
    gap: Spacing.three,
  },
  centered: {
    alignItems: 'center',
    gap: Spacing.two,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
  },
  viewfinder: {
    width: VIEWFINDER_SIZE,
    height: VIEWFINDER_SIZE,
    borderRadius: Spacing.four,
    overflow: 'hidden',
    backgroundColor: '#000000',
  },
  overlay: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0, 0, 0, 0.45)',
  },
  center: {
    textAlign: 'center',
  },
  primaryButton: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.two,
    paddingHorizontal: Spacing.four,
    borderRadius: Spacing.four,
    backgroundColor: AccentColor,
  },
  primaryLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
});
