import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import { useCallback, useState } from 'react';
import { ActivityIndicator, Alert, Platform, Pressable, StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ConfirmDialog } from '@/components/confirm-dialog';
import { EventAttendees } from '@/components/event-attendees';
import { EventLocation } from '@/components/event-location';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, DangerColor, Spacing } from '@/constants/theme';
import { useAuth } from '@/lib/auth';
import {
  deleteEvent,
  fetchEvent,
  formatEventTime,
  getEventAttendees,
  setGoing,
} from '@/lib/events';
import type { EventAttendee, EventSummary } from '@/lib/types';

type LoadState = 'loading' | 'loaded' | 'missing' | 'error';

// Who's going is a nice-to-have: if it fails, the rest of the sheet still works.
async function loadAttendees(eventId: string): Promise<EventAttendee[]> {
  try {
    return await getEventAttendees(eventId);
  } catch (error) {
    if (__DEV__) console.warn('Failed to load attendees', error);
    return [];
  }
}

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
  const [attendees, setAttendees] = useState<EventAttendee[]>([]);
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
          const [data, people] = await Promise.all([fetchEvent(id), loadAttendees(id)]);
          if (cancelled) return;
          setEvent(data);
          setAttendees(people);
          setLoadState(data ? 'loaded' : 'missing');
        } catch (error) {
          if (__DEV__) console.warn('Failed to load event', error);
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
        const [fresh, people] = await Promise.all([
          fetchEvent(event.id).catch(() => null),
          loadAttendees(event.id),
        ]);
        if (fresh) setEvent(fresh);
        setAttendees(people);
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
      if (__DEV__) console.warn('Failed to delete event', error);
      setActionError("Couldn't delete this event. Try again.");
      setIsDeleting(false);
    }
  }

  // Close the sheet first so the profile opens as a normal screen rather
  // than stacked inside the sheet.
  function openProfile(userId: string) {
    router.back();
    if (userId === myId) {
      router.navigate('/profile');
    } else {
      router.push(`/user/${userId}`);
    }
  }

  // Alert works the same on iOS and Android, so no platform-specific menu.
  function openMoreMenu() {
    if (!event) return;
    const eventId = event.id;
    Alert.alert(event.title, undefined, [
      {
        text: 'Report event',
        style: 'destructive',
        onPress: () => router.push(`/event/${eventId}/report`),
      },
      { text: 'Cancel', style: 'cancel' },
    ]);
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
  const isActive = event.status === 'active';
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
      {/* Only the host (and admins) ever see an event that isn't active. */}
      {!isActive ? (
        <View style={styles.banner}>
          <ThemedText themeColor="error" type="smallBold" style={styles.bannerText}>
            {event.status === 'hidden'
              ? "This event is under review and isn't visible to others."
              : 'This event was removed.'}
          </ThemedText>
        </View>
      ) : null}

      <View style={styles.titleBlock}>
        <View style={styles.titleRow}>
          <ThemedText type="subtitle" style={styles.title}>
            {event.title}
          </ThemedText>
          {!isCreator ? (
            <Pressable
              onPress={openMoreMenu}
              hitSlop={12}
              accessibilityRole="button"
              accessibilityLabel="More options"
              style={({ pressed }) => [styles.moreButton, pressed && styles.pressed]}>
              <ThemedText type="subtitle" themeColor="textSecondary" style={styles.moreLabel}>
                ⋯
              </ThemedText>
            </Pressable>
          ) : null}
        </View>
        <View style={styles.timeRow}>
          <ThemedText type="smallBold" style={styles.time}>
            {formatEventTime(event.starts_at, event.ends_at)}
          </ThemedText>
          {event.time_changed_at ? (
            <View style={styles.badge}>
              <ThemedText type="small" style={styles.badgeText}>
                🕒 Time changed
              </ThemedText>
            </View>
          ) : null}
        </View>
        <ThemedText type="small" themeColor="textSecondary">
          {event.visibility === 'connections' ? 'Connections only' : 'Public'} · {goingLabel}
        </ThemedText>
      </View>

      <Pressable
        onPress={() => openProfile(event.creator_id)}
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

      <EventLocation event={event} />

      <EventAttendees
        attendees={attendees}
        isHost={isCreator}
        myId={myId}
        onOpenProfile={openProfile}
      />

      {actionError ? (
        <ThemedText themeColor="error" type="small" style={styles.errorText}>
          {actionError}
        </ThemedText>
      ) : null}

      {hasEnded ? (
        <ThemedText type="small" themeColor="textSecondary" style={styles.centerText}>
          This event has ended.
        </ThemedText>
      ) : isCreator ? (
        event.status === 'removed' ? null : (
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
            {/* The server won't delete an event that's under review, so
                don't offer it. */}
            {isActive ? (
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
            ) : null}
          </View>
        )
      ) : isActive ? (
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
      ) : null}
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
  banner: {
    padding: Spacing.three,
    borderRadius: Spacing.three,
    backgroundColor: 'rgba(229, 107, 111, 0.15)',
  },
  bannerText: {
    textAlign: 'center',
  },
  titleBlock: {
    gap: Spacing.one,
  },
  titleRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.two,
  },
  title: {
    flexShrink: 1,
    fontSize: 26,
    lineHeight: 34,
  },
  moreButton: {
    marginLeft: 'auto',
    paddingHorizontal: Spacing.one,
  },
  moreLabel: {
    lineHeight: 34,
  },
  timeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: Spacing.two,
  },
  time: {
    color: AccentColor,
  },
  badge: {
    paddingHorizontal: Spacing.two,
    paddingVertical: Spacing.half,
    borderRadius: Spacing.two,
    backgroundColor: 'rgba(131, 101, 93, 0.15)',
  },
  badgeText: {
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
    textAlign: 'center',
  },
});
