import { router, useLocalSearchParams } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet } from 'react-native';

import { EventForm } from '@/components/event-form';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  fetchEvent,
  getMyHostingStatus,
  updateEvent,
  type EventInput,
  type HostingStatus,
} from '@/lib/events';

type LoadState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'removed' }
  | { status: 'loaded'; initialValues: EventInput; hosting: HostingStatus | null };

export default function EditEventScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const [state, setState] = useState<LoadState>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [event, hosting] = await Promise.all([
          fetchEvent(id),
          // The form still works without it; the server has the final say.
          getMyHostingStatus().catch((error) => {
            if (__DEV__) console.warn('Failed to load hosting status', error);
            return null;
          }),
        ]);
        if (cancelled) return;
        // The server only lets the creator update, but don't even show the
        // form to anyone else.
        if (!event || event.creator_id !== session?.user.id) {
          setState({ status: 'error' });
          return;
        }
        if (event.status === 'removed') {
          setState({ status: 'removed' });
          return;
        }
        setState({
          status: 'loaded',
          hosting,
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
        if (__DEV__) console.warn('Failed to load event for editing', error);
        if (!cancelled) setState({ status: 'error' });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id, session?.user.id]);

  if (state.status === 'loading') {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  if (state.status !== 'loaded') {
    return (
      <ThemedView style={styles.centered}>
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          {state.status === 'removed'
            ? "This event was removed, so it can't be edited."
            : "Couldn't load this event."}
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
      hosting={state.hosting}
      locationLocked
      onSubmit={async (input) => {
        const result = await updateEvent(id, input);
        if (result.kind === 'saved') router.back();
        return result;
      }}
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
  centerText: {
    textAlign: 'center',
  },
});
