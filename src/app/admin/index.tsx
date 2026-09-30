import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  RefreshControl,
  ScrollView,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';

import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, DangerColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import {
  adminFindUser,
  adminListFlaggedEvents,
  adminSetEventStatus,
  adminSetHostStatus,
  formatEventTime,
  REPORT_REASONS,
  type AdminHostStatus,
  type AdminUser,
  type FlaggedEvent,
} from '@/lib/events';
import { getMyAdminStatus } from '@/lib/mfa';
import { friendlyRpcError } from '@/lib/rpc';
import {
  adminListUserReports,
  adminResolveUserReport,
  adminSetAccountStatus,
  USER_REPORT_REASON_LABEL,
  type AdminUserReportGroup,
} from '@/lib/safety';

// Internal moderation tool for the team (app_admins). Kept deliberately
// plain. Every action is also checked on the server, so this screen's own
// admin check is only about not showing an empty tool to regular users who
// deep-link here.

type Tab = 'people' | 'flagged' | 'hosts';

const REASON_LABEL = Object.fromEntries(REPORT_REASONS.map((r) => [r.value, r.label]));

function confirm(title: string, message: string, confirmLabel: string, onConfirm: () => void) {
  Alert.alert(title, message, [
    { text: 'Cancel', style: 'cancel' },
    { text: confirmLabel, style: 'destructive', onPress: onConfirm },
  ]);
}

export default function AdminScreen() {
  const [isAdmin, setIsAdmin] = useState<boolean | null>(null);
  // On the admin list but this session wasn't verified with a two-step code.
  const [needsMfa, setNeedsMfa] = useState(false);
  const [tab, setTab] = useState<Tab>('people');
  const theme = useTheme();

  useEffect(() => {
    getMyAdminStatus()
      .then((status) => {
        setIsAdmin(status.isAdmin);
        setNeedsMfa(status.needsMfa);
      })
      .catch(() => setIsAdmin(false));
  }, []);

  if (isAdmin === null) {
    return (
      <ThemedView style={styles.centered}>
        <ActivityIndicator />
      </ThemedView>
    );
  }

  if (!isAdmin) {
    return (
      <ThemedView style={styles.centered}>
        {needsMfa ? (
          <View style={styles.mfaNotice}>
            <ThemedText type="default" style={styles.centerText}>
              Admin needs two-step verification. Turn it on (or sign in again with your code) to
              open Admin.
            </ThemedText>
            <AdminButton label="Two-step verification" onPress={() => router.replace('/two-step')} />
          </View>
        ) : (
          <ThemedText type="default" themeColor="textSecondary">
            Nothing here.
          </ThemedText>
        )}
      </ThemedView>
    );
  }

  return (
    <ThemedView style={styles.container}>
      <View style={styles.tabs}>
        {(
          [
            ['people', 'User reports'],
            ['flagged', 'Flagged events'],
            ['hosts', 'Hosts'],
          ] as const
        ).map(([value, label]) => {
          const selected = tab === value;
          return (
            <Pressable
              key={value}
              onPress={() => setTab(value)}
              accessibilityRole="tab"
              accessibilityState={{ selected }}
              style={[
                styles.tab,
                { backgroundColor: selected ? AccentColor : theme.backgroundSelected },
              ]}>
              <ThemedText type="smallBold" style={selected ? styles.onAccent : undefined}>
                {label}
              </ThemedText>
            </Pressable>
          );
        })}
      </View>
      {tab === 'people' ? <UserReportsTab /> : tab === 'flagged' ? <FlaggedTab /> : <HostsTab />}
    </ThemedView>
  );
}

// ---------------------------------------------------------------------------
// User reports (report_user): grouped by person, "might be under 18" first
// ---------------------------------------------------------------------------

function UserReportsTab() {
  const [groups, setGroups] = useState<AdminUserReportGroup[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [busyKey, setBusyKey] = useState<string | null>(null);

  const load = useCallback(
    () =>
      adminListUserReports().then(
        (next) => {
          setGroups(next);
          setError(null);
        },
        (err) => setError(friendlyRpcError(err)),
      ),
    [],
  );

  useEffect(() => {
    void load();
  }, [load]);

  async function run(key: string, action: () => Promise<unknown>) {
    setBusyKey(key);
    try {
      await action();
      await load();
    } catch (err) {
      Alert.alert("Couldn't update", friendlyRpcError(err));
    } finally {
      setBusyKey(null);
    }
  }

  return (
    <ScrollView
      contentContainerStyle={styles.list}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={async () => {
            setRefreshing(true);
            await load();
            setRefreshing(false);
          }}
        />
      }>
      {error ? <ThemedText themeColor="error" style={styles.errorText}>{error}</ThemedText> : null}
      {groups === null && !error ? <ActivityIndicator /> : null}
      {groups?.length === 0 ? (
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          No open reports. 🎉
        </ThemedText>
      ) : null}
      {groups?.map((group) => {
        const key = group.reported_user_id ?? group.reports[0]?.id ?? 'unknown';
        const busy = busyKey === key;
        const name =
          group.full_name || group.username || group.latest_snapshot?.username || 'Deleted account';
        const reasons = Object.entries(group.reports_by_reason ?? {})
          .map(([reason, n]) => `${USER_REPORT_REASON_LABEL[reason] ?? reason} ×${n}`)
          .join(', ');
        const userId = group.reported_user_id;
        return (
          <ThemedView key={key} type="backgroundElement" style={styles.card}>
            {group.has_underage ? (
              <ThemedText type="smallBold" themeColor="danger">
                ⚠︎ Reported as possibly under 18 — review first
              </ThemedText>
            ) : null}
            <Pressable
              onPress={() => (userId ? router.push(`/user/${userId}`) : undefined)}
              disabled={!userId}
              accessibilityRole="button">
              <ThemedText type="smallBold">
                {name}
                {group.username ? ` (@${group.username})` : ''}
                {group.is_suspended ? ' · SUSPENDED' : ''}
              </ThemedText>
            </Pressable>
            <ThemedText type="small">
              {group.report_count} open report{group.report_count === 1 ? '' : 's'}
              {reasons ? ` · ${reasons}` : ''}
            </ThemedText>
            {group.latest_snapshot?.bio ? (
              <ThemedText type="small" themeColor="textSecondary" numberOfLines={3}>
                Bio at report time: {group.latest_snapshot.bio}
              </ThemedText>
            ) : null}
            {group.latest_snapshot?.message?.body ? (
              <ThemedText type="small" themeColor="textSecondary" numberOfLines={4}>
                Reported message: “{group.latest_snapshot.message.body}”
              </ThemedText>
            ) : null}
            {group.reports.slice(0, 5).map((report) => (
              <ThemedText key={report.id} type="small" themeColor="textSecondary">
                {USER_REPORT_REASON_LABEL[report.reason] ?? report.reason} ({report.context})
                {report.details ? `: “${report.details}”` : ''} — @
                {report.reporter_username ?? 'deleted'}
              </ThemedText>
            ))}

            <View style={styles.buttonRow}>
              <AdminButton
                label="Dismiss"
                disabled={busy}
                onPress={() =>
                  confirm(
                    'Dismiss these reports?',
                    'They leave this list. Nothing happens to the account.',
                    'Dismiss',
                    () =>
                      run(key, () =>
                        Promise.all(
                          group.reports.map((r) => adminResolveUserReport(r.id, 'dismissed')),
                        ),
                      ),
                  )
                }
              />
              {userId && !group.is_suspended ? (
                <AdminButton
                  label="Suspend"
                  danger
                  disabled={busy}
                  onPress={() =>
                    confirm(
                      `Suspend ${name}?`,
                      "They disappear for everyone and can't post, message, or connect. Their upcoming events are removed and these reports are marked handled.",
                      'Suspend',
                      () => run(key, () => adminSetAccountStatus(userId, 'suspended')),
                    )
                  }
                />
              ) : null}
              {userId && group.is_suspended ? (
                <AdminButton
                  label="Lift suspension"
                  disabled={busy}
                  onPress={() => run(key, () => adminSetAccountStatus(userId, null))}
                />
              ) : null}
            </View>
          </ThemedView>
        );
      })}
    </ScrollView>
  );
}

// ---------------------------------------------------------------------------
// Flagged events
// ---------------------------------------------------------------------------

function FlaggedTab() {
  const [events, setEvents] = useState<FlaggedEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const load = useCallback(
    () =>
      adminListFlaggedEvents().then(
        (next) => {
          setEvents(next);
          setError(null);
        },
        (err) => setError(friendlyRpcError(err)),
      ),
    [],
  );

  useEffect(() => {
    void load();
  }, [load]);

  async function setStatus(event: FlaggedEvent, status: 'active' | 'removed') {
    setBusyId(event.event_id);
    try {
      await adminSetEventStatus(event.event_id, status);
      await load();
    } catch (err) {
      Alert.alert("Couldn't update", friendlyRpcError(err));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <ScrollView
      contentContainerStyle={styles.list}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={async () => {
            setRefreshing(true);
            await load();
            setRefreshing(false);
          }}
        />
      }>
      {error ? <ThemedText themeColor="error" style={styles.errorText}>{error}</ThemedText> : null}
      {events === null && !error ? <ActivityIndicator /> : null}
      {events?.length === 0 ? (
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          Nothing flagged. 🎉
        </ThemedText>
      ) : null}
      {events?.map((event) => {
        const busy = busyId === event.event_id;
        const reasons = Object.entries(event.reports_by_reason)
          .map(([reason, n]) => `${REASON_LABEL[reason] ?? reason} ×${n}`)
          .join(', ');
        return (
          <ThemedView key={event.event_id} type="backgroundElement" style={styles.card}>
            <Pressable onPress={() => router.push(`/event/${event.event_id}`)} accessibilityRole="button">
              <ThemedText type="smallBold">{event.title}</ThemedText>
            </Pressable>
            <ThemedText type="small" themeColor="textSecondary">
              {event.status.toUpperCase()} · {event.visibility} · {event.going_count} going
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary">
              {formatEventTime(event.starts_at, event.ends_at)}
            </ThemedText>
            <ThemedText type="small">
              Host: {event.creator_full_name || event.creator_username || 'Unknown'}
              {event.creator_username ? ` (@${event.creator_username})` : ''}
              {event.host_status ? ` · ${event.host_status}` : ''}
            </ThemedText>
            {event.location_name ? (
              <ThemedText type="small">📍 {event.location_name}</ThemedText>
            ) : null}
            {event.description ? (
              <ThemedText type="small" themeColor="textSecondary" numberOfLines={3}>
                {event.description}
              </ThemedText>
            ) : null}

            <ThemedText type="smallBold">
              {event.open_reports} open report{event.open_reports === 1 ? '' : 's'} (
              {event.counted_reports} count toward auto-hide)
            </ThemedText>
            {reasons ? <ThemedText type="small">{reasons}</ThemedText> : null}
            {event.recent_reports
              .filter((report) => report.details)
              .map((report, index) => (
                <ThemedText key={index} type="small" themeColor="textSecondary">
                  “{report.details}” — @{report.reporter_username ?? 'unknown'}
                  {report.counts ? '' : ' (new account)'}
                </ThemedText>
              ))}

            <View style={styles.buttonRow}>
              <AdminButton
                label="Restore"
                disabled={busy}
                onPress={() =>
                  confirm(
                    'Restore this event?',
                    'It shows up again for everyone and its open reports are dismissed.',
                    'Restore',
                    () => setStatus(event, 'active'),
                  )
                }
              />
              <AdminButton
                label="Remove"
                danger
                disabled={busy}
                onPress={() =>
                  confirm(
                    'Remove this event?',
                    'It disappears for everyone except the host, who sees that it was removed.',
                    'Remove',
                    () => setStatus(event, 'removed'),
                  )
                }
              />
            </View>
          </ThemedView>
        );
      })}
    </ScrollView>
  );
}

// ---------------------------------------------------------------------------
// Hosts
// ---------------------------------------------------------------------------

function hostSummary(user: AdminUser) {
  const h = user.hosting;
  const override =
    user.hostStatus === 'approved'
      ? 'Approved'
      : user.hostStatus === 'suspended'
        ? 'Suspended'
        : 'Automatic';
  const access = !h.canHost ? "can't host" : h.canHostPublic ? 'can host public' : 'connections only';
  return `${override} · ${access} · ${h.accountAgeDays}d old · ${h.inPersonCount} in person · ${h.activeEvents} upcoming${h.isAdmin ? ' · admin' : ''}`;
}

function HostsTab() {
  const theme = useTheme();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<AdminUser[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isSearching, setIsSearching] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  async function search(text = query) {
    if (!text.trim()) return;
    setIsSearching(true);
    try {
      setResults(await adminFindUser(text));
      setError(null);
    } catch (err) {
      setError(friendlyRpcError(err));
    } finally {
      setIsSearching(false);
    }
  }

  async function setHost(user: AdminUser, status: AdminHostStatus) {
    setBusyId(user.userId);
    try {
      const { eventsRemoved } = await adminSetHostStatus(user.userId, status);
      if (status === 'suspended' && eventsRemoved > 0) {
        Alert.alert('Suspended', `${eventsRemoved} upcoming event${eventsRemoved === 1 ? '' : 's'} removed.`);
      }
      await search();
    } catch (err) {
      Alert.alert("Couldn't update", friendlyRpcError(err));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <ScrollView contentContainerStyle={styles.list} keyboardShouldPersistTaps="handled">
      <View style={styles.searchRow}>
        <TextInput
          value={query}
          onChangeText={setQuery}
          onSubmitEditing={() => search()}
          placeholder="Username"
          placeholderTextColor={theme.textSecondary}
          autoCapitalize="none"
          autoCorrect={false}
          returnKeyType="search"
          style={[styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }]}
          accessibilityLabel="Search by username"
        />
        <AdminButton label={isSearching ? '…' : 'Search'} disabled={isSearching} onPress={() => search()} />
      </View>
      {error ? <ThemedText themeColor="error" style={styles.errorText}>{error}</ThemedText> : null}
      {results?.length === 0 ? (
        <ThemedText type="default" themeColor="textSecondary" style={styles.centerText}>
          No one with that username.
        </ThemedText>
      ) : null}
      {results?.map((user) => {
        const busy = busyId === user.userId;
        return (
          <ThemedView key={user.userId} type="backgroundElement" style={styles.card}>
            <ThemedText type="smallBold">
              {user.fullName || user.username} {user.username ? `(@${user.username})` : ''}
            </ThemedText>
            <ThemedText type="small" themeColor="textSecondary">
              {hostSummary(user)}
            </ThemedText>
            {user.hostNote ? (
              <ThemedText type="small" themeColor="textSecondary">
                Note: {user.hostNote}
              </ThemedText>
            ) : null}
            <View style={styles.buttonRow}>
              <AdminButton
                label="Approve"
                disabled={busy || user.hostStatus === 'approved'}
                onPress={() => setHost(user, 'approved')}
              />
              <AdminButton
                label="Suspend"
                danger
                disabled={busy || user.hostStatus === 'suspended'}
                onPress={() =>
                  confirm(
                    `Suspend @${user.username}?`,
                    "They can't host any events, and their upcoming events are removed.",
                    'Suspend',
                    () => setHost(user, 'suspended'),
                  )
                }
              />
              <AdminButton
                label="Clear"
                disabled={busy || user.hostStatus === null}
                onPress={() => setHost(user, null)}
              />
            </View>
          </ThemedView>
        );
      })}
    </ScrollView>
  );
}

function AdminButton({
  label,
  onPress,
  disabled,
  danger,
}: {
  label: string;
  onPress: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      style={({ pressed }) => [
        styles.adminButton,
        { backgroundColor: danger ? DangerColor : AccentColor, opacity: disabled ? 0.4 : 1 },
        pressed && styles.pressed,
      ]}>
      <ThemedText type="smallBold" style={styles.onAccent}>
        {label}
      </ThemedText>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    padding: Spacing.four,
  },
  centerText: {
    textAlign: 'center',
  },
  mfaNotice: {
    alignItems: 'center',
    gap: Spacing.three,
    maxWidth: 360,
  },
  tabs: {
    flexDirection: 'row',
    gap: Spacing.two,
    padding: Spacing.three,
    alignSelf: 'center',
  },
  tab: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.five,
  },
  onAccent: {
    color: '#fdfbf7',
  },
  list: {
    alignSelf: 'center',
    width: '100%',
    maxWidth: MaxContentWidth,
    gap: Spacing.three,
    padding: Spacing.three,
    paddingBottom: Spacing.six,
  },
  card: {
    gap: Spacing.one,
    padding: Spacing.three,
    borderRadius: Spacing.three,
  },
  buttonRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.two,
    marginTop: Spacing.two,
  },
  adminButton: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.three,
  },
  searchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.two,
  },
  input: {
    flex: 1,
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  errorText: {
    textAlign: 'center',
  },
  pressed: {
    opacity: 0.8,
  },
});
