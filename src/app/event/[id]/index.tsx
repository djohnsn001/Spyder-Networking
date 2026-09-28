import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Platform, Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ConfirmDialog } from '@/components/confirm-dialog';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, DangerColor, ErrorColor, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import { deleteEvent, fetchEvent, formatEventTime, setGoing } from '@/lib/events';
import type { EventSummary } from '@/lib/types';

type LoadState = 'loading' | 'loaded' | 'missing' | 'error';

// Bottom sheet opened by tapping an event pin on the Map tab. It's a
// fitToContents formSheet: the sheet takes its height from this content, so
// nothing here may use flex: 1 (there's no parent height to fill — on iOS
// that renders a blank sheet).
export default function EventDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const { session } = useAuth();
  const myId = session?.user.id;
  const insets = useSafeAreaInsets();

  const [event, setEvent] = useState<EventSummary | null>(null);
  const [loadState, setLoadState] = useState<LoadState>('loading');
  const [isUpdatingRsvp, setIsUpdatingRsvp] = useState(false);
  const [isDeleting, setIsDeleting] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  // On focus rather than mount, so coming back from Edit shows the changes.
  useFocusEffect(
    useCallback(() => {
      let cancelled = false;
      (async () => {
        try {
          const data = await fetchEvent(id);
          if (cancelled) return;
          setEvent(data);
          setLoadState(data ? 'loaded' : 'missing');
        } catch (error) {
          console.error('Failed to load event', error);
          if (!cancelled) setLoadState('error');
        }
      })();
      return () => {
        cancelled = true;
      };
    }, [id]),
  );

  async function handleToggleGoing() {
    if (!event || !myId || isUpdatingRsvp) return;
    const nextGoing = !event.is_going;
    setActionError(null);
    setIsUpdatingRsvp(true);
    // Optimistic: flip it now, roll back if the request fails.
    const previous = event;
    setEvent({
      ...event,
      is_going: nextGoing,
      going_count: event.going_count + (nextGoing ? 1 : -1),
    });
    try {
      const result = await setGoing(event.id, myId, nextGoing);
      if (result === 'rate_limited') {
        setEvent(previous);
        setActionError("You've RSVP'd to a lot of events today. Try again tomorrow.");
      } else if (result === 'unavailable') {
        setEvent(previous);
        setActionError("This event isn't taking RSVPs anymore.");
      } else {
        // Refetch: going unlocks the exact spot and place name (and
        // un-going hides them again), which only the server knows.
        const fresh = await fetchEvent(event.id).catch(() => null);
        if (fresh) setEvent(fresh);
      }
    } catch (error) {
      if (__DEV__) console.warn('Failed to update RSVP', error);
      setEvent(previous);
      setActionError("Couldn't update your RSVP. Check your connection and try again.");
    } finally {
      setIsUpdatingRsvp(false);
    }
  }

  async function handleDelete() {
    if (!event) return;
    setConfirmingDelete(false);
    setActionError(null);
    setIsDeleting(true);
    try {
      await deleteEvent(event.id);
      router.back();
    } catch (error) {
      console.error('Failed to delete event', error);
      setActionError("Couldn't delete this event. Try again.");
      setIsDeleting(false);
    }
  }

  // Close the sheet first so the profile opens as a normal screen rather
  // than stacked inside the sheet.
  function handleOpenCreator() {
    if (!event) return;
    router.back();
    if (event.creator_id === myId) {
      router.navigate('/profile');
    } else {
      router.push(`/user/${event.creator_id}`);
    }
  }

  if (loadState === 'loading') {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  if (!event || loadState !== 'loaded') {
    return (
      <ThemedView style={styles.centered}>
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          {loadState === 'error'
            ? "Couldn't load this event. Check your connection and try again."
            : 'This event is no longer available.'}
        </ThemedText>
      </ThemedView>
    );
  }

  const isCreator = event.creator_id === myId;
  const creatorName = event.creator_full_name || event.creator_username || 'Someone';
  const hasEnded = new Date(event.effective_ends_at).getTime() <= Date.now();
  const goingLabel = event.going_count === 1 ? '1 going' : `${event.going_count} going`;

  return (
    // iOS already pads a fitToContents sheet for the home indicator.
    <ThemedView
      style={[
        styles.content,
        { paddingBottom: Spacing.four + (Platform.OS === 'android' ? insets.bottom : 0) },
      ]}>
      <View style={styles.titleBlock}>
        <ThemedText type="subtitle" style={styles.title}>
          {event.title}
        </ThemedText>
        <ThemedText type="smallBold" style={styles.time}>
          {formatEventTime(event.starts_at, event.ends_at)}
        </ThemedText>
        {event.location_name ? (
          <ThemedText type="default" themeColor="textSecondary">
            {event.location_name}
          </ThemedText>
        ) : null}
        <ThemedText type="small" themeColor="textSecondary">
          {event.visibility === 'connections' ? 'Connections only' : 'Public'} · {goingLabel}
        </ThemedText>
      </View>

      <Pressable
        onPress={handleOpenCreator}
        accessibilityRole="button"
        accessibilityLabel={`View ${creatorName}'s profile`}
        style={({ pressed }) => [styles.creatorRow, pressed && styles.pressed]}>
        <Avatar uri={event.creator_avatar_url} name={creatorName} size={36} />
        <View style={styles.creatorText}>
          <ThemedText type="small" themeColor="textSecondary">
            Hosted by
          </ThemedText>
          <ThemedText type="smallBold">{isCreator ? 'You' : creatorName}</ThemedText>
        </View>
      </Pressable>

      {event.description ? <ThemedText type="default">{event.description}</ThemedText> : null}

      {actionError ? (
        <ThemedText type="small" style={styles.errorText}>
          {actionError}
        </ThemedText>
      ) : null}

      {hasEnded ? (
        <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
          This event has ended.
        </ThemedText>
      ) : isCreator ? (
        <View style={styles.actionRow}>
          <Pressable
            onPress={() => router.push(`/event/${event.id}/edit`)}
            disabled={isDeleting}
            accessibilityRole="button"
            accessibilityLabel="Edit event"
            style={({ pressed }) => [
              styles.button,
              styles.rowButton,
              styles.secondaryButton,
              pressed && styles.pressed,
            ]}>
            <ThemedText type="smallBold">Edit</ThemedText>
          </Pressable>
          <Pressable
            onPress={() => setConfirmingDelete(true)}
            disabled={isDeleting}
            accessibilityRole="button"
            accessibilityLabel="Delete event"
            style={({ pressed }) => [
              styles.button,
              styles.rowButton,
              { backgroundColor: DangerColor },
              pressed && styles.pressed,
            ]}>
            {isDeleting ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                Delete
              </ThemedText>
            )}
          </Pressable>
        </View>
      ) : (
        <Pressable
          onPress={handleToggleGoing}
          disabled={isUpdatingRsvp}
          accessibilityRole="button"
          accessibilityState={{ selected: event.is_going }}
          accessibilityLabel={event.is_going ? "You're going. Tap to change to not going" : 'Going'}
          style={({ pressed }) => [
            styles.button,
            event.is_going ? styles.secondaryButton : { backgroundColor: AccentColor },
            pressed && styles.pressed,
          ]}>
          <ThemedText type="smallBold" style={event.is_going ? undefined : styles.buttonLabel}>
            {event.is_going ? "✓ Going · Tap if you can't make it" : 'Going'}
          </ThemedText>
        </Pressable>
      )}
      <ConfirmDialog
        visible={confirmingDelete}
        title="Delete this event?"
        message="It'll be removed from the map for everyone. This can't be undone."
        confirmLabel="Delete"
        danger
        onConfirm={handleDelete}
        onCancel={() => setConfirmingDelete(false)}
      />
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  centered: {
    minHeight: 200,
    alignItems: 'center',
    justifyContent: 'center',
    padding: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
  content: {
    gap: Spacing.three,
    padding: Spacing.four,
    paddingTop: Spacing.five,
  },
  titleBlock: {
    gap: Spacing.one,
  },
  title: {
    fontSize: 26,
    lineHeight: 34,
  },
  time: {
    color: AccentColor,
  },
  creatorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.three,
    alignSelf: 'flex-start',
  },
  creatorText: {
    gap: Spacing.half,
  },
  actionRow: {
    flexDirection: 'row',
    gap: Spacing.two,
  },
  button: {
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  // Only inside the Edit/Delete row, to split its width — never on its own,
  // where flex: 1 would try to fill a height the sheet doesn't have.
  rowButton: {
    flex: 1,
  },
  secondaryButton: {
    borderWidth: 1,
    borderColor: 'rgba(131,101,93,0.35)',
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
  errorText: {
    color: ErrorColor,
    textAlign: 'center',
  },
});
