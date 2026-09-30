import { DarkTheme, DefaultTheme, router, Stack, ThemeProvider, usePathname } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { useEffect } from 'react';

import { AnimatedSplashOverlay } from '@/components/animated-icon';
import { AuthProvider, useAuth } from '@/lib/auth';
import { BadgeToastProvider } from '@/lib/badge-toasts';
import { takePendingConnectToken } from '@/lib/connect/pending-link';
import { ThemePreferenceProvider, useThemePreference } from '@/lib/theme-preference';
import { UnreadMessagesProvider } from '@/lib/unread-messages';

SplashScreen.preventAutoHideAsync();

function RootNavigator() {
  const { session, profile, needsConsent, isSuspended, needsMfaCode, isLoading } = useAuth();
  const hasUsername = !!profile?.username;
  // Two-step code entered (if the account uses it) — checked before anything
  // else, so a password alone gets nowhere (security item H4).
  const mfaOk = !needsMfaCode;
  // Past the code, not suspended, past the consent gate (Terms + 18+), and
  // past profile setup.
  const isReady = mfaOk && !isSuspended && !needsConsent && hasUsername;
  const pathname = usePathname();

  // A bolas://connect/<code> link that arrived while signed out (or before
  // profile setup finished) gets redeemed as soon as the app is usable.
  useEffect(() => {
    if (isLoading || !session || !isReady) return;
    if (pathname.startsWith('/connect/')) return;
    const token = takePendingConnectToken();
    if (token) router.push(`/connect/${token}`);
  }, [isLoading, session, isReady, pathname]);

  // The splash overlay covers the screen until it finishes hiding, so
  // returning null here briefly doesn't cause a flash of blank content.
  if (isLoading) {
    return null;
  }

  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={!!session}>
        {/* Two-step code first: with it on, a signed-in session sees only
            the code screen until a code is entered. */}
        <Stack.Protected guard={!mfaOk}>
          <Stack.Screen name="mfa-verify" />
        </Stack.Protected>

        {/* Then suspension, then the consent gate: accounts that haven't
            accepted the current Terms see only that (plus Delete account). */}
        <Stack.Protected guard={mfaOk && isSuspended}>
          <Stack.Screen name="suspended" />
        </Stack.Protected>

        <Stack.Protected guard={mfaOk && !isSuspended && needsConsent}>
          <Stack.Screen name="legal/accept" />
        </Stack.Protected>

        <Stack.Protected guard={isReady}>
          <Stack.Screen name="(app)" />
          <Stack.Screen name="edit-profile" options={{ presentation: 'modal' }} />
          <Stack.Screen name="new-message" options={{ presentation: 'modal' }} />
          <Stack.Screen name="premium" options={{ presentation: 'modal' }} />
          {/* The create/edit forms are tall and scroll, so they're regular
              modals like new-message. The detail view is a bottom sheet sized
              to its content — on iOS a formSheet's content has no fixed
              height, so screens inside one must not rely on flex: 1. */}
          <Stack.Screen name="event/new" options={{ presentation: 'modal' }} />
          <Stack.Screen
            name="event/[id]/index"
            options={{
              presentation: 'formSheet',
              sheetAllowedDetents: 'fitToContents',
              sheetGrabberVisible: true,
            }}
          />
          <Stack.Screen name="event/[id]/edit" options={{ presentation: 'modal' }} />
          <Stack.Screen name="event/[id]/report" options={{ presentation: 'modal' }} />
          <Stack.Screen name="event/[id]/checkin" options={{ presentation: 'modal' }} />
          <Stack.Screen name="checkin/[token]" options={{ presentation: 'modal' }} />
          <Stack.Screen name="connect/index" options={{ presentation: 'modal' }} />
          <Stack.Screen name="connect/[token]" options={{ presentation: 'modal' }} />
          <Stack.Screen name="user/[id]" options={{ headerShown: true, headerTitle: '' }} />
          <Stack.Screen name="chat/[conversationId]" options={{ headerShown: true, headerTitle: '' }} />
          <Stack.Screen name="settings" options={{ headerShown: true, headerTitle: 'Settings' }} />
          <Stack.Screen name="report/[userId]" options={{ presentation: 'modal' }} />
          <Stack.Screen
            name="blocked-users"
            options={{ headerShown: true, headerTitle: 'Blocked users' }}
          />
          <Stack.Screen
            name="two-step"
            options={{ headerShown: true, headerTitle: 'Two-step verification' }}
          />
          <Stack.Screen
            name="legal/licenses"
            options={{ headerShown: true, headerTitle: 'Open-source licenses' }}
          />
          <Stack.Screen name="admin/index" options={{ headerShown: true, headerTitle: 'Admin' }} />
          <Stack.Screen
            name="connections"
            options={{ headerShown: true, headerTitle: 'Connections' }}
          />
        </Stack.Protected>

        <Stack.Protected guard={mfaOk && !isSuspended && !needsConsent && !hasUsername}>
          <Stack.Screen name="profile-setup" />
        </Stack.Protected>

        {/* Reachable from anywhere once signed in (including the consent
            gate, so nobody is trapped), but only after the two-step code:
            a stolen password mustn't be able to delete the account. */}
        <Stack.Protected guard={mfaOk}>
          <Stack.Screen
            name="delete-account"
            options={{ headerShown: true, headerTitle: 'Delete account' }}
          />
        </Stack.Protected>
      </Stack.Protected>

      <Stack.Protected guard={!session}>
        <Stack.Screen name="(auth)" />
      </Stack.Protected>
    </Stack>
  );
}

function RootLayoutThemed() {
  const { resolvedScheme } = useThemePreference();
  return (
    <ThemeProvider value={resolvedScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <AnimatedSplashOverlay />
      <AuthProvider>
        <UnreadMessagesProvider>
          <BadgeToastProvider>
            <RootNavigator />
          </BadgeToastProvider>
        </UnreadMessagesProvider>
      </AuthProvider>
    </ThemeProvider>
  );
}

export default function RootLayout() {
  return (
    <ThemePreferenceProvider>
      <RootLayoutThemed />
    </ThemePreferenceProvider>
  );
}
