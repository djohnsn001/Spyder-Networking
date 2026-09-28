import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet } from 'react-native';

import { EventForm } from '@/components/event-form';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { createEvent, getMyHostingStatus, type EventInput, type HostingStatus } from '@/lib/events';

// Next full hour from now — a sensible default that's always in the future.
function nextFullHour(): Date {
  const date = new Date();
  date.setHours(date.getHours() + 1, 0, 0, 0);
  return date;
}

// undefined = still loading; null = couldn't load (show the form anyway and
// let the server decide).
type HostingState = HostingStatus | null | undefined;

// Opened from the Map tab (long-press or the "+" button) with the spot the
// event should be pinned to.
export default function NewEventScreen() {
  const { latitude, longitude } = useLocalSearchParams<{ latitude: string; longitude: string }>();
  const [hosting, setHosting] = useState<HostingState>(undefined);
  const [initialValues] = useState<EventInput>(() => ({
    title: '',
    description: '',
    locationName: '',
    startsAt: nextFullHour(),
    endsAt: null,
    // Connections only by default; public is opt-in (and may be locked).
    visibility: 'connections',
  }));

  useEffect(() => {
    let cancelled = false;
    getMyHostingStatus()
      .then((status) => {
        if (!cancelled) setHosting(status);
      })
      .catch((error) => {
        if (__DEV__) console.warn('Failed to load hosting status', error);
        if (!cancelled) setHosting(null);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const lat = Number(latitude);
  const lng = Number(longitude);

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return <Message text="Pick a spot on the map to create an event." />;
  }

  if (hosting === undefined) {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  if (hosting && !hosting.canHost) {
    return (
      <Message
        text={
          hosting.reason === 'suspended'
            ? 'Hosting is paused on your account.'
            : 'Finish setting up your profile before hosting events.'
        }
      />
    );
  }

  // Say so up front rather than after they've filled everything in.
  if (hosting && !hosting.isAdmin && hosting.activeEvents >= hosting.maxActiveEvents) {
    return (
      <Message
        text={`You can have up to ${hosting.maxActiveEvents} upcoming events. Delete one or wait for one to end, then try again.`}
      />
    );
  }

  return (
    <EventForm
      heading="Create event"
      submitLabel="Create event"
      initialValues={initialValues}
      requireFutureStart
      hosting={hosting}
      locationLocked={false}
      onSubmit={async (input) => {
        const result = await createEvent({ latitude: lat, longitude: lng }, input);
        if (result.kind === 'saved') router.back();
        return result;
      }}
    />
  );
}

function Message({ text }: { text: string }) {
  return (
    <ThemedView style={styles.centered}>
      <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
        {text}
      </ThemedText>
      <Pressable onPress={() => router.back()} accessibilityRole="button" style={styles.closeButton}>
        <ThemedText type="smallBold">Close</ThemedText>
      </Pressable>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.three,
    padding: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
  closeButton: {
    padding: Spacing.two,
  },
});
