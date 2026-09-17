import { router } from 'expo-router';

import { ProfileForm } from '@/components/profile-form';
import { useAuth } from '@/lib/auth';

export default function EditProfileScreen() {
  const { profile } = useAuth();

  return (
    <ProfileForm
      initialProfile={profile}
      title="Edit your profile"
      subtitle="Update how other builders see you."
      submitLabel="Save changes"
      onSaved={() => router.back()}
    />
  );
}
