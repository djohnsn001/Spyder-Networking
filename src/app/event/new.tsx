import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import { StyleSheet } from 'react-native';

import { EventForm } from '@/components/event-form';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { createEvent, type EventInput } from '@/lib/events';

// Next full hour from now — a sensible default that's always in the future.
function nextFullHour(): Date {
  const date = new Date();
  date.setHours(date.getHours() + 1, 0, 0, 0);
  return date;
}

// Opened from the Map tab (long-press or the "+" button) with the spot the
// event should be pinned to.
export default function NewEventScreen() {
  const { latitude, longitude } = useLocalSearchParams<{ latitude: string; longitude: string }>();
  const { session } = useAuth();
  const [initialValues] = useState<EventInput>(() => ({
    title: '',
    description: '',
    locationName: '',
    startsAt: nextFullHour(),
    endsAt: null,
    visibility: 'public',
  }));

  const lat = Number(latitude);
  const lng = Number(longitude);

  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    return (
      <ThemedView style={styles.centered}>
        <ThemedText type="default" themeColor="textSecondary">
          Pick a spot on the map to create an event.
        </ThemedText>
      </ThemedView>
    );
  }

  async function handleSubmit(input: EventInput) {
    if (!session) return;
    await createEvent(session.user.id, { latitude: lat, longitude: lng }, input);
    router.back();
  }

  return (
    <EventForm
      heading="Create event"
      submitLabel="Create event"
      initialValues={initialValues}
      requireFutureStart
      onSubmit={handleSubmit}
    />
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: Spacing.four,
  },
});
