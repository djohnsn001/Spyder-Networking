import { DarkTheme, DefaultTheme, Stack, ThemeProvider } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { useColorScheme } from 'react-native';

import { AnimatedSplashOverlay } from '@/components/animated-icon';
import { AuthProvider, useAuth } from '@/lib/auth';

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
          <Stack.Screen name="user/[id]" options={{ headerShown: true, headerTitle: '' }} />
          <Stack.Screen name="settings" options={{ headerShown: true, headerTitle: 'Settings' }} />
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

export default function RootLayout() {
  const colorScheme = useColorScheme();
  return (
    <ThemeProvider value={colorScheme === 'dark' ? DarkTheme : DefaultTheme}>
      <AnimatedSplashOverlay />
      <AuthProvider>
        <RootNavigator />
      </AuthProvider>
    </ThemeProvider>
  );
}
