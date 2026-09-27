// Detects a physical "bump" (two phones tapped together) from accelerometer
// samples. Pure, with no device APIs, so it can be unit-tested with
// synthetic samples.
//
// Samples are in g (1 g = gravity) and include gravity, on both iOS and
// Android (expo-sensors Accelerometer). A phone at rest reads ~1 g total.

// Starting values, meant to be tuned on real phones (the Connect screen's
// dev-only debug readout shows live delta/jerk).
export const BUMP_TUNING = {
  // How far total acceleration must jump away from 1 g (gravity).
  SPIKE_G: 1.3,
  // How much it must change between two consecutive samples. This is what
  // separates a sharp tap from a slow wave or a walk.
  JERK_G: 1.0,
  // Ignore further bumps for this long after one triggers.
  COOLDOWN_MS: 2500,
  // Accelerometer update interval (~60 Hz).
  UPDATE_INTERVAL_MS: 16,
} as const;

export type BumpTuning = { [K in keyof typeof BUMP_TUNING]: number };

export type AccelSample = { x: number; y: number; z: number; t: number };

export type BumpDetectorState = {
  lastMagnitude: number | null;
  lastTriggerAt: number | null;
};

export const initialBumpDetectorState: BumpDetectorState = {
  lastMagnitude: null,
  lastTriggerAt: null,
};

export type BumpStep = {
  state: BumpDetectorState;
  detected: boolean;
  // For the debug readout.
  delta: number;
  jerk: number;
};

export function stepBumpDetector(
  state: BumpDetectorState,
  sample: AccelSample,
  tuning: BumpTuning = BUMP_TUNING,
): BumpStep {
  const magnitude = Math.sqrt(sample.x ** 2 + sample.y ** 2 + sample.z ** 2);
  const delta = Math.abs(magnitude - 1);
  const jerk = state.lastMagnitude === null ? 0 : Math.abs(magnitude - state.lastMagnitude);

  const coolingDown =
    state.lastTriggerAt !== null && sample.t - state.lastTriggerAt < tuning.COOLDOWN_MS;
  const detected = !coolingDown && delta > tuning.SPIKE_G && jerk > tuning.JERK_G;

  return {
    state: {
      lastMagnitude: magnitude,
      lastTriggerAt: detected ? sample.t : state.lastTriggerAt,
    },
    detected,
    delta,
    jerk,
  };
}

// Convenience for tests: run a whole sample array, return trigger times.
export function detectBumps(samples: AccelSample[], tuning: BumpTuning = BUMP_TUNING): number[] {
  let state = initialBumpDetectorState;
  const triggers: number[] = [];
  for (const sample of samples) {
    const step = stepBumpDetector(state, sample, tuning);
    state = step.state;
    if (step.detected) triggers.push(sample.t);
  }
  return triggers;
}
