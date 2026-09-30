import * as Location from 'expo-location';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import type { ConnectFix } from '@/lib/connect/api';

// Used when the OS doesn't report GPS accuracy.
export const FALLBACK_ACCURACY_M = 100;

export type ConnectLocationStatus = 'checking' | 'undetermined' | 'granted' | 'denied';

export type ConnectLocation = {
  status: ConnectLocationStatus;
  // False once the user has permanently denied; then only Settings can fix it.
  canAskAgain: boolean;
  coords: { latitude: number; longitude: number } | null;
  accuracy: number | null;
  city: string | null;
  // coords + accuracy, ready to send with a QR code or scan; null until the
  // first fix arrives.
  fix: ConnectFix | null;
  requestPermission: () => Promise<void>;
};

// Location for connecting in person. Never prompts on its own: screens call
// requestPermission() after explaining why. Every way of connecting in person
// needs it: tapping phones, showing a QR code, and scanning one (the server
// checks the two phones are together, security item H2).
//
// `active` should be true only while the Connect screen is focused. With
// `watch` on it keeps a fresh fix so nothing waits for GPS; otherwise it grabs
// a single position.
export function useConnectLocation({
  active,
  watch,
}: {
  active: boolean;
  watch: boolean;
}): ConnectLocation {
  const [status, setStatus] = useState<ConnectLocationStatus>('checking');
  const [canAskAgain, setCanAskAgain] = useState(true);
  const [coords, setCoords] = useState<ConnectLocation['coords']>(null);
  const [accuracy, setAccuracy] = useState<number | null>(null);
  const [city, setCity] = useState<string | null>(null);
  const geocodedRef = useRef(false);

  // Re-check whenever the screen becomes active (the user may have changed
  // it in Settings meanwhile).
  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    Location.getForegroundPermissionsAsync().then((response) => {
      if (cancelled) return;
      setCanAskAgain(response.canAskAgain);
      setStatus(
        response.granted ? 'granted' : response.canAskAgain ? 'undetermined' : 'denied',
      );
    });
    return () => {
      cancelled = true;
    };
  }, [active]);

  const requestPermission = useCallback(async () => {
    const response = await Location.requestForegroundPermissionsAsync();
    setCanAskAgain(response.canAskAgain);
    setStatus(response.granted ? 'granted' : 'denied');
  }, []);

  // Reverse-geocode once per screen visit: geocoding is rate-limited, and the
  // city doesn't change while two people are standing together.
  const lookUpCity = useCallback(async (latitude: number, longitude: number) => {
    if (geocodedRef.current) return;
    geocodedRef.current = true;
    try {
      const [address] = await Location.reverseGeocodeAsync({ latitude, longitude });
      setCity(address?.city || address?.subregion || address?.district || null);
    } catch (error) {
      if (__DEV__) console.warn('[connect] reverse geocode failed', error);
    }
  }, []);

  useEffect(() => {
    if (!active || status !== 'granted') return;
    let cancelled = false;
    let subscription: Location.LocationSubscription | null = null;

    function apply(position: Location.LocationObject) {
      if (cancelled) return;
      setCoords({ latitude: position.coords.latitude, longitude: position.coords.longitude });
      setAccuracy(position.coords.accuracy ?? null);
      void lookUpCity(position.coords.latitude, position.coords.longitude);
    }

    (async () => {
      try {
        const last = await Location.getLastKnownPositionAsync();
        if (last) apply(last);
        if (watch) {
          const sub = await Location.watchPositionAsync(
            { accuracy: Location.Accuracy.Balanced, timeInterval: 2000, distanceInterval: 5 },
            apply,
          );
          if (cancelled) sub.remove();
          else subscription = sub;
        } else if (!last) {
          apply(await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced }));
        }
      } catch (error) {
        if (__DEV__) console.warn('[connect] location failed', error);
      }
    })();

    return () => {
      cancelled = true;
      subscription?.remove();
    };
  }, [active, status, watch, lookUpCity]);

  const fix = useMemo<ConnectFix | null>(
    () =>
      coords
        ? { latitude: coords.latitude, longitude: coords.longitude, accuracy: accuracy ?? FALLBACK_ACCURACY_M }
        : null,
    [coords, accuracy],
  );

  return { status, canAskAgain, coords, accuracy, city, fix, requestPermission };
}
