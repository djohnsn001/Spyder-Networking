import { router } from 'expo-router';
import {
  createContext,
  type ReactNode,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import { Animated, AppState, Pressable, StyleSheet } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { FullWindowOverlay } from 'react-native-screens';

import { BadgeEmblem } from '@/components/badge-emblem';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { BorderWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useAuth } from '@/lib/auth';
import {
  type BadgeDefinition,
  badgeLabel,
  fetchBadgeDefinitions,
  fetchUnseenBadges,
  markBadgesSeen,
} from '@/lib/badges';

// "You earned a badge" toasts. Badges are awarded by the server (a trigger,
// a check-in), so the app asks for unseen ones: on sign-in, when the app
// comes back to the foreground, every minute, and right after anything that
// might earn one (screens call checkForNewBadges()). Each badge is marked
// seen as soon as it's queued, so it's announced once.

const POLL_MS = 60_000;
const SHOW_MS = 3500;
// First check after sign-in, once the app has settled.
const FIRST_CHECK_MS = 1500;

type Toast = { key: string; definition: BadgeDefinition | undefined; label: string };

const BadgeToastContext = createContext<{ checkForNewBadges: () => void }>({
  checkForNewBadges: () => {},
});

export function useBadgeToasts() {
  return useContext(BadgeToastContext);
}

export function BadgeToastProvider({ children }: { children: ReactNode }) {
  const { session, profile } = useAuth();
  const [queue, setQueue] = useState<Toast[]>([]);
  const busyRef = useRef(false);
  // Only once the app is usable (signed in, profile set up).
  const enabled = !!session && !!profile?.username;

  const checkForNewBadges = useCallback(async () => {
    if (!enabled || busyRef.current) return;
    busyRef.current = true;
    try {
      const unseen = await fetchUnseenBadges();
      if (unseen.length === 0) return;
      const definitions = await fetchBadgeDefinitions();
      await markBadgesSeen(unseen.map((badge) => badge.badge_key));
      setQueue((current) => [
        ...current,
        ...unseen.map((badge) => {
          const definition = definitions.get(badge.badge_key);
          return {
            key: badge.badge_key,
            definition,
            label: badgeLabel(definition, badge),
          };
        }),
      ]);
    } catch (error) {
      if (__DEV__) console.warn('Failed to check for new badges', error);
    } finally {
      busyRef.current = false;
    }
  }, [enabled]);

  useEffect(() => {
    if (!enabled) return;
    const first = setTimeout(() => void checkForNewBadges(), FIRST_CHECK_MS);
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') void checkForNewBadges();
    });
    const timer = setInterval(() => void checkForNewBadges(), POLL_MS);
    return () => {
      clearTimeout(first);
      subscription.remove();
      clearInterval(timer);
    };
  }, [enabled, checkForNewBadges]);

  const next = queue[0];
  // Stable, so the toast's animation isn't restarted by unrelated re-renders.
  const dismiss = useCallback(() => setQueue((current) => current.slice(1)), []);

  return (
    <BadgeToastContext.Provider value={{ checkForNewBadges }}>
      {children}
      {/* On iOS, modal screens (check-in, edit profile) sit above the app's
          root view; FullWindowOverlay draws the toast above them too. On
          Android it's a plain View, already on top. */}
      {next ? (
        <FullWindowOverlay>
          <BadgeToast key={next.key} toast={next} onDone={dismiss} />
        </FullWindowOverlay>
      ) : null}
    </BadgeToastContext.Provider>
  );
}

function BadgeToast({ toast, onDone }: { toast: Toast; onDone: () => void }) {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const [progress] = useState(() => new Animated.Value(0));
  // Tapping and the timer can both end a toast; only the first counts, so
  // the next toast in line isn't skipped.
  const doneRef = useRef(false);
  const finish = useCallback(() => {
    if (doneRef.current) return;
    doneRef.current = true;
    onDone();
  }, [onDone]);

  useEffect(() => {
    const animation = Animated.sequence([
      Animated.timing(progress, { toValue: 1, duration: 250, useNativeDriver: true }),
      Animated.delay(SHOW_MS),
      Animated.timing(progress, { toValue: 0, duration: 250, useNativeDriver: true }),
    ]);
    animation.start(({ finished }) => {
      if (finished) finish();
    });
    return () => animation.stop();
  }, [progress, finish]);

  return (
    <Animated.View
      pointerEvents="box-none"
      style={[
        styles.container,
        {
          top: insets.top + Spacing.two,
          opacity: progress,
          transform: [{ translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [-20, 0] }) }],
        },
      ]}>
      <Pressable
        onPress={() => {
          finish();
          router.navigate('/profile');
        }}
        accessibilityRole="button"
        accessibilityLiveRegion="polite"
        accessibilityLabel={`New badge: ${toast.label}. Tap to see your badges.`}>
        <ThemedView
          type="overlay"
          style={[styles.toast, { borderColor: theme.overlayBorder, shadowColor: theme.shadow }]}>
          <BadgeEmblem badgeKey={toast.key} definition={toast.definition} size={32} />
          <ThemedText type="small" themeColor="textSecondary">
            New badge
          </ThemedText>
          <ThemedText type="smallBold">{toast.label}</ThemedText>
        </ThemedView>
      </Pressable>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    left: Spacing.three,
    right: Spacing.three,
    alignItems: 'center',
    zIndex: 1000,
    elevation: 10,
  },
  toast: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.five,
    borderWidth: BorderWidth.thin,
    shadowOpacity: 0.15,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
  },
});
