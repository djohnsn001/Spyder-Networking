import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';

import { AnimatedSplashOverlay } from '@/components/animated-icon';
import { AuthProvider, useAuth } from '@/lib/auth';
import { ThemePreferenceProvider, useThemePreference } from '@/lib/theme-preference';
import { UnreadMessagesProvider } from '@/lib/unread-messages';

SplashScreen.preventAutoHideAsync();

function RootNavigator() {
  const { session, profile, isLoading } = useAuth();
  const hasUsername = !!profile?.username;

  // The splash overlay covers the screen until it finishes hiding, so
  // returning null here briefly doesn't cause a flash of blank content.
  if (isLoading) {
    return null;
  }

  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={!!session}>
        <Stack.Protected guard={hasUsername}>
          <Stack.Screen name="(app)" />
          <Stack.Screen name="edit-profile" options={{ presentation: 'modal' }} />
          <Stack.Screen name="new-message" options={{ presentation: 'modal' }} />
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
          <Stack.Screen name="user/[id]" options={{ headerShown: true, headerTitle: '' }} />
          <Stack.Screen name="chat/[conversationId]" options={{ headerShown: true, headerTitle: '' }} />
          <Stack.Screen name="settings" options={{ headerShown: true, headerTitle: 'Settings' }} />
          <Stack.Screen
            name="connections"
            options={{ headerShown: true, headerTitle: 'Connections' }}
          />
        </Stack.Protected>

        <Stack.Protected guard={!hasUsername}>
          <Stack.Screen name="profile-setup" />
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
          <RootNavigator />
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
