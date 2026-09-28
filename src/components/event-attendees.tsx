import { Pressable, ScrollView, StyleSheet, View } from 'react-native';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { Spacing } from '@/constants/theme';
import type { EventAttendee } from '@/lib/types';

// A fixed cap, not flex: this lives in a fitToContents sheet.
const HOST_LIST_MAX_HEIGHT = 220;
const MAX_CONNECTION_AVATARS = 8;

function displayName(attendee: EventAttendee) {
  return attendee.full_name || attendee.username || 'Someone';
}

// Who's going, as much as the viewer is allowed to know (the server decides
// via get_event_attendees):
// - Host: the full list, with a note that only they see it.
// - Everyone else: just their own connections who are going, or nothing.
// The total count is shown separately, from going_count.
export function EventAttendees({
  attendees,
  isHost,
  myId,
  onOpenProfile,
}: {
  attendees: EventAttendee[];
  isHost: boolean;
  myId: string | undefined;
  onOpenProfile: (userId: string) => void;
}) {
  if (isHost) {
    return (
      <View style={styles.container}>
        <ThemedText type="smallBold">Who's going</ThemedText>
        <ScrollView style={styles.hostList} nestedScrollEnabled>
          {attendees.map((attendee) => {
            const name = displayName(attendee);
            const isMe = attendee.user_id === myId;
            return (
              <Pressable
                key={attendee.user_id}
                onPress={() => onOpenProfile(attendee.user_id)}
                accessibilityRole="button"
                accessibilityLabel={`View ${isMe ? 'your' : `${name}'s`} profile`}
                style={({ pressed }) => [styles.row, pressed && styles.pressed]}>
                <Avatar uri={attendee.avatar_url} name={name} size={32} />
                <ThemedText type="default" style={styles.rowName} numberOfLines={1}>
                  {isMe ? 'You (host)' : name}
                </ThemedText>
                {attendee.is_connection ? (
                  <ThemedText type="small" themeColor="textSecondary">
                    Connection
                  </ThemedText>
                ) : null}
              </Pressable>
            );
          })}
        </ScrollView>
        <ThemedText type="small" themeColor="textSecondary">
          You're the host: only you can see everyone.
        </ThemedText>
      </View>
    );
  }

  const connections = attendees.filter((attendee) => attendee.is_connection);
  if (connections.length === 0) return null;

  const shown = connections.slice(0, MAX_CONNECTION_AVATARS);
  const extra = connections.length - shown.length;
  const label =
    connections.length === 1
      ? `${displayName(connections[0])} is going`
      : `${connections.length} of your connections are going`;

  return (
    <View style={styles.container}>
      <ThemedText type="small" themeColor="textSecondary" style={styles.italic}>
        {label}
      </ThemedText>
      <View style={styles.avatarRow}>
        {shown.map((attendee) => (
          <Pressable
            key={attendee.user_id}
            onPress={() => onOpenProfile(attendee.user_id)}
            accessibilityRole="button"
            accessibilityLabel={`View ${displayName(attendee)}'s profile`}
            style={({ pressed }) => pressed && styles.pressed}>
            <Avatar uri={attendee.avatar_url} name={displayName(attendee)} size={32} />
          </Pressable>
        ))}
        {extra > 0 ? (
          <ThemedText type="small" themeColor="textSecondary">
            +{extra}
          </ThemedText>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: Spacing.two,
  },
  hostList: {
    maxHeight: HOST_LIST_MAX_HEIGHT,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
    paddingVertical: Spacing.one,
  },
  rowName: {
    flexShrink: 1,
  },
  avatarRow: {
    flexDirection: 'row',
    alignItems: 'center',
    flexWrap: 'wrap',
    gap: Spacing.one,
  },
  italic: {
    fontStyle: 'italic',
  },
  pressed: {
    opacity: 0.7,
  },
});
