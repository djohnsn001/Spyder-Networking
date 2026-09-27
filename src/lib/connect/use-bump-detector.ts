import { Accelerometer } from 'expo-sensors';
import { useEffect, useRef, useState } from 'react';

import {
  BUMP_TUNING,
  initialBumpDetectorState,
  stepBumpDetector,
} from '@/lib/connect/bump-detector';

const DEBUG_REFRESH_MS = 100;

export type BumpDebug = { delta: number; jerk: number; peakDelta: number; triggers: number };

// Listens to the accelerometer only while `armed`, and calls onBump() when a
// tap is detected. In __DEV__ it also returns live numbers for the debug
// readout (refreshed ~10x a second, not per sample).
export function useBumpDetector({ armed, onBump }: { armed: boolean; onBump: () => void }) {
  const [available, setAvailable] = useState<boolean | null>(null);
  const [debug, setDebug] = useState<BumpDebug>({ delta: 0, jerk: 0, peakDelta: 0, triggers: 0 });

  const onBumpRef = useRef(onBump);
  useEffect(() => {
    onBumpRef.current = onBump;
  }, [onBump]);

  useEffect(() => {
    Accelerometer.isAvailableAsync()
      .then(setAvailable)
      .catch(() => setAvailable(false));
  }, []);

  useEffect(() => {
    if (!armed || !available) return;
    let state = initialBumpDetectorState;
    const live: BumpDebug = { delta: 0, jerk: 0, peakDelta: 0, triggers: 0 };

    Accelerometer.setUpdateInterval(BUMP_TUNING.UPDATE_INTERVAL_MS);
    const subscription = Accelerometer.addListener(({ x, y, z }) => {
      const step = stepBumpDetector(state, { x, y, z, t: Date.now() });
      state = step.state;
      if (__DEV__) {
        live.delta = step.delta;
        live.jerk = step.jerk;
        live.peakDelta = Math.max(live.peakDelta, step.delta);
      }
      if (step.detected) {
        live.triggers += 1;
        onBumpRef.current();
      }
    });

    const debugTimer = __DEV__
      ? setInterval(() => setDebug({ ...live }), DEBUG_REFRESH_MS)
      : undefined;

    return () => {
      subscription.remove();
      if (debugTimer) clearInterval(debugTimer);
    };
  }, [armed, available]);

  return { available, debug };
}
