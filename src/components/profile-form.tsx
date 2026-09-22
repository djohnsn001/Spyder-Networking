import * as ImagePicker from 'expo-image-picker';
import { useState } from 'react';
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  TextInput,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { Avatar } from '@/components/avatar';
import { ThemedText } from '@/components/themed-text';
import { ThemedView } from '@/components/themed-view';
import { AccentColor, ErrorColor, MaxContentWidth, Spacing } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { uploadAvatar } from '@/lib/avatar';
import { useAuth } from '@/lib/auth';
import { BioLimit, BusinessStages, InterestOptions, UsernamePattern } from '@/lib/profile-options';
import { supabase } from '@/lib/supabase';
import type { BusinessStage, Profile } from '@/lib/types';

type ProfileFormProps = {
  initialProfile?: Profile | null;
  title: string;
  subtitle: string;
  submitLabel: string;
  onSaved: () => void;
};

export function ProfileForm({
  initialProfile,
  title,
  subtitle,
  submitLabel,
  onSaved,
}: ProfileFormProps) {
  const theme = useTheme();
  const { session, refreshProfile } = useAuth();

  const [username, setUsername] = useState(initialProfile?.username ?? '');
  const [fullName, setFullName] = useState(initialProfile?.full_name ?? '');
  const [avatarUrl, setAvatarUrl] = useState(initialProfile?.avatar_url ?? null);
  const [bio, setBio] = useState(initialProfile?.bio ?? '');
  const [city, setCity] = useState(initialProfile?.city ?? '');
  const [businessStage, setBusinessStage] = useState<BusinessStage | null>(
    initialProfile?.business_stage ?? null,
  );
  const [interests, setInterests] = useState<string[]>(initialProfile?.interests ?? []);

  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isUploadingAvatar, setIsUploadingAvatar] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  async function handlePickAvatar() {
    if (!session) return;
    setErrorMessage(null);

    const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
    if (!permission.granted) {
      setErrorMessage('Photo library access is needed to set a profile picture.');
      return;
    }

    const result = await ImagePicker.launchImageLibraryAsync({
      mediaTypes: ['images'],
      allowsEditing: true,
      quality: 0.8,
    });
    if (result.canceled || !result.assets[0]) return;

    setIsUploadingAvatar(true);
    try {
      const asset = result.assets[0];
      const publicUrl = await uploadAvatar(session.user.id, asset.uri, asset.mimeType);
      const { error } = await supabase
        .from('profiles')
        .update({ avatar_url: publicUrl })
        .eq('id', session.user.id);
      if (error) throw error;
      setAvatarUrl(publicUrl);
      await refreshProfile();
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : 'Failed to upload photo.');
    } finally {
      setIsUploadingAvatar(false);
    }
  }

  function toggleInterest(interest: string) {
    setInterests((current) =>
      current.includes(interest)
        ? current.filter((item) => item !== interest)
        : [...current, interest],
    );
  }

  async function handleSubmit() {
    setErrorMessage(null);

    const trimmedUsername = username.trim();
    if (!UsernamePattern.test(trimmedUsername)) {
      setErrorMessage(
        'Username must be 3-20 characters, using only letters, numbers, and underscores.',
      );
      return;
    }

    if (!session) return;

    setIsSubmitting(true);
    try {
      const { data: existing, error: lookupError } = await supabase
        .from('profiles')
        .select('id')
        .eq('username', trimmedUsername)
        .neq('id', session.user.id)
        .maybeSingle();
      if (lookupError) throw lookupError;
      if (existing) {
        setErrorMessage('That username is already taken. Try another one.');
        return;
      }

      const { error: updateError } = await supabase
        .from('profiles')
        .update({
          username: trimmedUsername,
          full_name: fullName.trim() || null,
          bio: bio.trim() || null,
          city: city.trim() || null,
          business_stage: businessStage,
          interests,
        })
        .eq('id', session.user.id);

      if (updateError) {
        if (updateError.code === '23505') {
          setErrorMessage('That username is already taken. Try another one.');
          return;
        }
        throw updateError;
      }

      await refreshProfile();
      onSaved();
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : 'Something went wrong.');
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <ThemedView style={styles.container}>
      <KeyboardAvoidingView
        style={styles.container}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <SafeAreaView style={styles.safeArea}>
          <ScrollView
            contentContainerStyle={styles.scrollContent}
            keyboardShouldPersistTaps="handled">
            <ThemedView type="backgroundElement" style={styles.card}>
              <ThemedText type="subtitle" style={styles.title}>
                {title}
              </ThemedText>
              <ThemedText type="small" themeColor="textSecondary" style={styles.subtitle}>
                {subtitle}
              </ThemedText>

              <View style={styles.avatarSection}>
                <Avatar uri={avatarUrl} name={fullName || username || 'You'} size={96} />
                <Pressable
                  onPress={handlePickAvatar}
                  disabled={isUploadingAvatar}
                  accessibilityRole="button"
                  accessibilityLabel={avatarUrl ? 'Change profile picture' : 'Add profile picture'}>
                  {isUploadingAvatar ? (
                    <ActivityIndicator size="small" />
                  ) : (
                    <ThemedText type="link">{avatarUrl ? 'Change photo' : 'Add photo'}</ThemedText>
                  )}
                </Pressable>
              </View>

              <View style={styles.field}>
                <ThemedText type="smallBold">Username *</ThemedText>
                <TextInput
                  value={username}
                  onChangeText={setUsername}
                  placeholder="yourname"
                  placeholderTextColor={theme.textSecondary}
                  autoCapitalize="none"
                  autoCorrect={false}
                  style={[
                    styles.input,
                    { color: theme.text, backgroundColor: theme.backgroundSelected },
                  ]}
                />
              </View>

              <View style={styles.field}>
                <ThemedText type="smallBold">Full name</ThemedText>
                <TextInput
                  value={fullName}
                  onChangeText={setFullName}
                  placeholder="Full name"
                  placeholderTextColor={theme.textSecondary}
                  style={[
                    styles.input,
                    { color: theme.text, backgroundColor: theme.backgroundSelected },
                  ]}
                />
              </View>

              <View style={styles.field}>
                <View style={styles.fieldHeaderRow}>
                  <ThemedText type="smallBold">Bio</ThemedText>
                  <ThemedText type="small" themeColor="textSecondary">
                    {bio.length}/{BioLimit}
                  </ThemedText>
                </View>
                <TextInput
                  value={bio}
                  onChangeText={(text) => setBio(text.slice(0, BioLimit))}
                  placeholder="What are you building?"
                  placeholderTextColor={theme.textSecondary}
                  multiline
                  numberOfLines={3}
                  style={[
                    styles.input,
                    styles.textArea,
                    { color: theme.text, backgroundColor: theme.backgroundSelected },
                  ]}
                />
              </View>

              <View style={styles.field}>
                <ThemedText type="smallBold">City</ThemedText>
                <TextInput
                  value={city}
                  onChangeText={setCity}
                  placeholder="Boise, ID"
                  placeholderTextColor={theme.textSecondary}
                  style={[
                    styles.input,
                    { color: theme.text, backgroundColor: theme.backgroundSelected },
                  ]}
                />
              </View>

              <View style={styles.field}>
                <ThemedText type="smallBold">Business stage</ThemedText>
                <View style={styles.pillRow}>
                  {BusinessStages.map((stage) => {
                    const selected = businessStage === stage.value;
                    return (
                      <Pressable
                        key={stage.value}
                        onPress={() => setBusinessStage(stage.value)}
                        accessibilityRole="button"
                        accessibilityState={{ selected }}
                        style={({ pressed }) => [
                          styles.pill,
                          {
                            backgroundColor: selected ? AccentColor : theme.backgroundSelected,
                          },
                          pressed && styles.pressed,
                        ]}>
                        <ThemedText
                          type="small"
                          style={selected ? styles.pillLabelSelected : undefined}
                          themeColor={selected ? undefined : 'text'}>
                          {stage.label}
                        </ThemedText>
                      </Pressable>
                    );
                  })}
                </View>
              </View>

              <View style={styles.field}>
                <ThemedText type="smallBold">Interests</ThemedText>
                <View style={styles.pillRow}>
                  {InterestOptions.map((interest) => {
                    const selected = interests.includes(interest);
                    return (
                      <Pressable
                        key={interest}
                        onPress={() => toggleInterest(interest)}
                        accessibilityRole="button"
                        accessibilityState={{ selected }}
                        style={({ pressed }) => [
                          styles.pill,
                          {
                            backgroundColor: selected ? AccentColor : theme.backgroundSelected,
                          },
                          pressed && styles.pressed,
                        ]}>
                        <ThemedText
                          type="small"
                          style={selected ? styles.pillLabelSelected : undefined}
                          themeColor={selected ? undefined : 'text'}>
                          {interest}
                        </ThemedText>
                      </Pressable>
                    );
                  })}
                </View>
              </View>

              {errorMessage ? (
                <ThemedText type="small" style={styles.errorText}>
                  {errorMessage}
                </ThemedText>
              ) : null}

              <Pressable
                onPress={handleSubmit}
                disabled={isSubmitting}
                accessibilityRole="button"
                accessibilityLabel={submitLabel}
                style={({ pressed }) => [
                  styles.button,
                  { backgroundColor: AccentColor, opacity: isSubmitting ? 0.7 : 1 },
                  pressed && styles.buttonPressed,
                ]}>
                {isSubmitting ? (
                  <ActivityIndicator color="#fdfbf7" />
                ) : (
                  <ThemedText type="smallBold" style={styles.buttonLabel}>
                    {submitLabel}
                  </ThemedText>
                )}
              </Pressable>
            </ThemedView>
          </ScrollView>
        </SafeAreaView>
      </KeyboardAvoidingView>
    </ThemedView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  safeArea: {
    flex: 1,
  },
  scrollContent: {
    flexGrow: 1,
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
  },
  card: {
    alignSelf: 'stretch',
    gap: Spacing.three,
    paddingHorizontal: Spacing.four,
    paddingVertical: Spacing.five,
    borderRadius: Spacing.four,
    maxWidth: MaxContentWidth,
  },
  title: {
    textAlign: 'center',
  },
  subtitle: {
    textAlign: 'center',
    marginTop: -Spacing.two,
  },
  avatarSection: {
    alignItems: 'center',
    gap: Spacing.two,
  },
  field: {
    gap: Spacing.two,
  },
  fieldHeaderRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  input: {
    paddingHorizontal: Spacing.three,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.three,
    fontSize: 16,
  },
  textArea: {
    minHeight: 80,
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
  pillLabelSelected: {
    color: '#fdfbf7',
  },
  pressed: {
    opacity: 0.8,
  },
  errorText: {
    color: ErrorColor,
    textAlign: 'center',
  },
  button: {
    marginTop: Spacing.two,
    paddingVertical: Spacing.three,
    borderRadius: Spacing.four,
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonPressed: {
    opacity: 0.8,
  },
  buttonLabel: {
    color: '#fdfbf7',
  },
});
