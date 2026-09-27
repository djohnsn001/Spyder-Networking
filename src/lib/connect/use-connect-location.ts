import * as Location from 'expo-location';
import { useCallback, useEffect, useRef, useState } from 'react';

export type ConnectLocationStatus = 'checking' | 'undetermined' | 'granted' | 'denied';

export type ConnectLocation = {
  status: ConnectLocationStatus;
  // False once the user has permanently denied; then only Settings can fix it.
  canAskAgain: boolean;
  coords: { latitude: number; longitude: number } | null;
  accuracy: number | null;
  city: string | null;
  requestPermission: () => Promise<void>;
};

// Location for connecting in person. Never prompts on its own: screens call
// requestPermission() after explaining why (the Tap tab). Scanning a QR code
// never needs location; if it's off, city stays null and the server falls
// back to a profile city.
//
// `active` should be true only while the Connect screen is focused. With
// `watch` on (Tap tab) it keeps a fresh fix so a bump never waits for GPS;
// otherwise it grabs a single position, just to work out the city.
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

  const refreshPermission = useCallback(async () => {
    const response = await Location.getForegroundPermissionsAsync();
    setCanAskAgain(response.canAskAgain);
    setStatus(
      response.granted ? 'granted' : response.canAskAgain ? 'undetermined' : 'denied',
    );
  }, []);

  useEffect(() => {
    if (active) void refreshPermission();
  }, [active, refreshPermission]);

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

  return { status, canAskAgain, coords, accuracy, city, requestPermission };
}
