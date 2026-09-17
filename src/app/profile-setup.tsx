import { router } from 'expo-router';

import { ProfileForm } from '@/components/profile-form';

export default function ProfileSetupScreen() {
  return (
    <ProfileForm
      title="Set up your profile"
      subtitle="Tell other builders who you are before you start connecting."
      submitLabel="Save profile"
      onSaved={() => router.replace('/')}
    />
  );
}
