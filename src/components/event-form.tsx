import { router } from 'expo-router';
import { useState } from 'react';
import {
  ActivityIndicator,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { DateTimeField } from '@/components/date-time-field';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import {
  EVENT_DESCRIPTION_LIMIT,
  EVENT_LOCATION_NAME_LIMIT,
  EVENT_TITLE_LIMIT,
  publicLockHint,
  saveEventErrorMessage,
  validateEventInput,
  type EventInput,
  type EventInputErrors,
  type HostingStatus,
  type SaveEventResult,
} from '@/lib/events';
import { friendlyRpcError } from '@/lib/rpc';
import type { EventVisibility } from '@/lib/types';

const DEFAULT_DURATION_MS = 2 * 60 * 60 * 1000;

const VisibilityOptions: { value: EventVisibility; label: string; hint: string }[] = [
  { value: 'public', label: 'Public', hint: 'Anyone on Bolas can see this event.' },
  {
    value: 'connections',
    label: 'Connections only',
    hint: 'Only your connections can see this event.',
  },
];

type EventFormProps = {
  heading: string;
  submitLabel: string;
  initialValues: EventInput;
  // On for creating, off for editing — see validateEventInput.
  requireFutureStart: boolean;
  // From get_my_hosting_status. null if it couldn't load: Public then stays
  // selectable and the server has the final say.
  hosting: HostingStatus | null;
  // Editing: the place name can't change after posting, so show it read-only.
  locationLocked: boolean;
  // Returns the server's answer; the screen navigates away on 'saved', the
  // form explains anything else. Throws only for network trouble.
  onSubmit: (input: EventInput) => Promise<SaveEventResult>;
};

// Shared by /event/new and /event/[id]/edit. Owns field state and
// validation; the screens own saving and navigation.
export function EventForm({
  heading,
  submitLabel,
  initialValues,
  requireFutureStart,
  hosting,
  locationLocked,
  onSubmit,
}: EventFormProps) {
  const theme = useTheme();
  // The server can report a newer status than the one we loaded (e.g. the
  // public_locked answer), so keep our own copy.
  const [hostingNow, setHostingNow] = useState(hosting);

  const [title, setTitle] = useState(initialValues.title);
  const [description, setDescription] = useState(initialValues.description);
  const [locationName, setLocationName] = useState(initialValues.locationName);
  const [startsAt, setStartsAt] = useState(initialValues.startsAt);
  const [endsAt, setEndsAt] = useState<Date | null>(initialValues.endsAt);
  const [visibility, setVisibility] = useState<EventVisibility>(initialValues.visibility);
  // Captured once so the picker's lower bound doesn't change every render.
  const [openedAt] = useState(() => new Date());

  const [errors, setErrors] = useState<EventInputErrors>({});
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  // An event that's already public stays editable as public even if the
  // host's trust has since lapsed; the server allows keeping it.
  const publicLocked =
    hostingNow != null && !hostingNow.canHostPublic && initialValues.visibility !== 'public';
  const lockHint = publicLocked && hostingNow ? publicLockHint(hostingNow) : null;
  const needsInPerson =
    publicLocked && hostingNow != null && hostingNow.inPersonCount < hostingNow.neededInPerson;

  const inputStyle = [styles.input, { color: theme.text, backgroundColor: theme.backgroundSelected }];

  async function handleSubmit() {
    const input: EventInput = { title, description, locationName, startsAt, endsAt, visibility };
    const nextErrors = validateEventInput(input, { requireFutureStart });
    setErrors(nextErrors);
    setSubmitError(null);
    if (Object.keys(nextErrors).length > 0) return;

    setIsSubmitting(true);
    try {
      const result = await onSubmit(input);
      if (result.kind === 'saved') return;
      const message = saveEventErrorMessage(result);
      if (
        result.kind === 'invalid' &&
        result.field !== 'location' &&
        result.field !== 'visibility'
      ) {
        setErrors({ [result.field]: message });
      } else {
        if (result.kind === 'public_locked') setHostingNow(result.hosting);
        setSubmitError(message);
      }
    } catch (error) {
      if (__DEV__) console.warn('Failed to save event', error);
      setSubmitError(friendlyRpcError(error));
    } finally {
      setIsSubmitting(false);
    }
  }

  function renderError(message: string | undefined) {
    return message ? (
      <ThemedText themeColor="error" type="small" style={styles.errorText}>
        {message}
      </ThemedText>
    ) : null;
  }

  return (
    <ThemedView style={styles.container}>
      <SafeAreaView style={styles.container}>
        <ScrollView
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled"
          automaticallyAdjustKeyboardInsets={Platform.OS === 'ios'}>
          <View style={styles.header}>
            <ThemedText type="subtitle" style={styles.heading}>
              {heading}
            </ThemedText>
            <Pressable onPress={() => router.back()} accessibilityRole="button" accessibilityLabel="Cancel">
              <ThemedText type="smallBold" themeColor="textSecondary">
                Cancel
              </ThemedText>
            </Pressable>
          </View>

          <View style={styles.field}>
            <View style={styles.fieldHeaderRow}>
              <ThemedText type="smallBold">Title *</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                {title.length}/{EVENT_TITLE_LIMIT}
              </ThemedText>
            </View>
            <TextInput
              value={title}
              onChangeText={(text) => setTitle(text.slice(0, EVENT_TITLE_LIMIT))}
              placeholder="Founder coffee, pitch practice…"
              placeholderTextColor={theme.textSecondary}
              style={inputStyle}
              accessibilityLabel="Title"
            />
            {renderError(errors.title)}
          </View>

          <View style={styles.field}>
            <View style={styles.fieldHeaderRow}>
              <ThemedText type="smallBold">Description</ThemedText>
              <ThemedText type="small" themeColor="textSecondary">
                {description.length}/{EVENT_DESCRIPTION_LIMIT}
              </ThemedText>
            </View>
            <TextInput
              value={description}
              onChangeText={(text) => setDescription(text.slice(0, EVENT_DESCRIPTION_LIMIT))}
              placeholder="What's happening, who should come?"
              placeholderTextColor={theme.textSecondary}
              multiline
              numberOfLines={4}
              style={[inputStyle, styles.textArea]}
              accessibilityLabel="Description"
            />
            {renderError(errors.description)}
          </View>

          <View style={styles.field}>
            <ThemedText type="smallBold">Location name</ThemedText>
            {locationLocked ? (
              <>
                <View style={[styles.input, { backgroundColor: theme.backgroundSelected }]}>
                  <ThemedText type="default" themeColor={locationName ? 'text' : 'textSecondary'}>
                    {locationName || 'No place name'}
                  </ThemedText>
                </View>
                <ThemedText type="small" themeColor="textSecondary">
                  The place can't change after posting. To move the event, delete it and drop a
                  new pin.
                </ThemedText>
              </>
            ) : (
              <>
                <TextInput
                  value={locationName}
                  onChangeText={(text) => setLocationName(text.slice(0, EVENT_LOCATION_NAME_LIMIT))}
                  placeholder="Boise State Library"
                  placeholderTextColor={theme.textSecondary}
                  style={inputStyle}
                  accessibilityLabel="Location name"
                />
                <ThemedText type="small" themeColor="textSecondary">
                  Pick a public place like a café, library, or coworking space. People see the
                  general area until they tap Going.
                </ThemedText>
              </>
            )}
            {renderError(errors.locationName)}
          </View>

          <View style={styles.field}>
            <ThemedText type="smallBold">Starts *</ThemedText>
            <DateTimeField
              value={startsAt}
              onChange={setStartsAt}
              minimumDate={requireFutureStart ? openedAt : undefined}
              accessibilityLabel="Start time"
            />
            {renderError(errors.startsAt)}
          </View>

          <View style={styles.field}>
            <View style={styles.fieldHeaderRow}>
              <ThemedText type="smallBold">Ends</ThemedText>
              <Pressable
                onPress={() =>
                  setEndsAt(endsAt ? null : new Date(startsAt.getTime() + DEFAULT_DURATION_MS))
                }
                accessibilityRole="button"
                accessibilityLabel={endsAt ? 'Remove end time' : 'Add end time'}>
                <ThemedText type="smallBold" style={styles.linkText}>
                  {endsAt ? 'Remove' : 'Add end time'}
                </ThemedText>
              </Pressable>
            </View>
            {endsAt ? (
              <DateTimeField
                value={endsAt}
                onChange={setEndsAt}
                minimumDate={startsAt}
                accessibilityLabel="End time"
              />
            ) : (
              <ThemedText type="small" themeColor="textSecondary">
                No end time — it'll leave the map 3 hours after it starts.
              </ThemedText>
            )}
            {renderError(errors.endsAt)}
          </View>

          <View style={styles.field}>
            <ThemedText type="smallBold">Who can see it</ThemedText>
            <View style={styles.pillRow}>
              {VisibilityOptions.map((option) => {
                const selected = visibility === option.value;
                const locked = option.value === 'public' && publicLocked;
                return (
                  <Pressable
                    key={option.value}
                    onPress={() => setVisibility(option.value)}
                    disabled={locked}
                    accessibilityRole="button"
                    accessibilityState={{ selected, disabled: locked }}
                    accessibilityLabel={locked ? `${option.label} (locked)` : option.label}
                    style={({ pressed }) => [
                      styles.pill,
                      { backgroundColor: selected ? AccentColor : theme.backgroundSelected },
                      locked && styles.pillLocked,
                      pressed && styles.pressed,
                    ]}>
                    <ThemedText
                      type="small"
                      style={selected ? styles.pillLabelSelected : undefined}
                      themeColor={selected ? undefined : locked ? 'textSecondary' : 'text'}>
                      {locked ? `🔒 ${option.label}` : option.label}
                    </ThemedText>
                  </Pressable>
                );
              })}
            </View>
            <ThemedText type="small" themeColor="textSecondary">
              {VisibilityOptions.find((option) => option.value === visibility)?.hint}
            </ThemedText>
            {lockHint ? (
              <ThemedText type="small" themeColor="textSecondary">
                {lockHint}
                {needsInPerson ? (
                  <ThemedText
                    type="smallBold"
                    style={styles.linkText}
                    onPress={() => router.push('/connect')}
                    accessibilityRole="link">
                    {' '}
                    Meet people in person →
                  </ThemedText>
                ) : null}
              </ThemedText>
            ) : null}
          </View>

          {submitError ? (
            <ThemedText themeColor="error" type="small" style={[styles.errorText, styles.centerText]}>
              {submitError}
            </ThemedText>
          ) : null}

          <Pressable
            onPress={handleSubmit}
            disabled={isSubmitting}
            accessibilityRole="button"
            accessibilityLabel={submitLabel}
            style={({ pressed }) => [
              styles.button,
              { opacity: isSubmitting ? 0.7 : 1 },
              pressed && styles.pressed,
            ]}>
            {isSubmitting ? (
              <ActivityIndicator color="#fdfbf7" />
            ) : (
              <ThemedText type="smallBold" style={styles.buttonLabel}>
                {submitLabel}
              </ThemedText>
            )}
          </Pressable>
        </ScrollView>
      </SafeAreaView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  content: {
    gap: Spacing.three,
    padding: Spacing.four,
    paddingBottom: Spacing.six,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: Spacing.three,
  },
  heading: {
    flexShrink: 1,
    fontSize: 26,
    lineHeight: 34,
  },
  field: {
    gap: Spacing.two,
  },
  fieldHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  textArea: {
    minHeight: 96,
    textAlignVertical: 'top',
  },
  pillRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.two,
  },
  pill: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.two,
    borderRadius: Spacing.five,
  },
  pillLocked: {
    opacity: 0.6,
  },
  pillLabelSelected: {
    color: '#fdfbf7',
  },
  linkText: {
    color: AccentColor,
  },
  pressed: {
    opacity: 0.8,
  },
  errorText: {
  },
  centerText: {
    textAlign: 'center',
  },
  button: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    backgroundColor: AccentColor,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
});
