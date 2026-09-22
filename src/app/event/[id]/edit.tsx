import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet } from 'react-native';

import { EventForm } from '@/components/event-form';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { fetchEvent, updateEvent, type EventInput } from '@/lib/events';

type LoadState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; initialValues: EventInput };

export default function EditEventScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const [state, setState] = useState<LoadState>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const event = await fetchEvent(id);
        if (cancelled) return;
        // RLS only lets the creator update, but don't even show the form to
        // anyone else.
        if (!event || event.creator_id !== session?.user.id) {
          setState({ status: 'error' });
          return;
        }
        setState({
          status: 'loaded',
          initialValues: {
            title: event.title,
            description: event.description ?? '',
            locationName: event.location_name ?? '',
            startsAt: new Date(event.starts_at),
            endsAt: event.ends_at ? new Date(event.ends_at) : null,
            visibility: event.visibility,
          },
        });
      } catch (error) {
        console.error('Failed to load event for editing', error);
        if (!cancelled) setState({ status: 'error' });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id, session?.user.id]);

  async function handleSubmit(input: EventInput) {
    await updateEvent(id, input);
    router.back();
  }

  if (state.status === 'loading') {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  if (state.status === 'error') {
    return (
      <ThemedView style={styles.centered}>
        <ThemedText type="default" themeColor="textSecondary">
          Couldn't load this event.
        </ThemedText>
      </ThemedView>
    );
  }

  return (
    <EventForm
      heading="Edit event"
      submitLabel="Save changes"
      initialValues={state.initialValues}
      requireFutureStart={false}
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
