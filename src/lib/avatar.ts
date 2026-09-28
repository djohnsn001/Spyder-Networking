import { supabase } from '@/lib/supabase';

// Uploads a picked image to the avatars bucket under the user's own folder
// (required by the storage RLS policies) and returns its public URL.
export async function uploadAvatar(
  userId: string,
  uri: string,
  mimeType: string | undefined,
): Promise<string> {
  const arraybuffer = await fetch(uri).then((res) => res.arrayBuffer());
  const fileExt = uri.split('.').pop()?.toLowerCase() ?? 'jpg';
  const path = `${userId}/${Date.now()}.${fileExt}`;

  const { error: uploadError } = await supabase.storage
    .from('avatars')
    .upload(path, arraybuffer, { contentType: mimeType ?? 'image/jpeg' });
  if (uploadError) throw uploadError;

  const { data } = supabase.storage.from('avatars').getPublicUrl(path);
  return data.publicUrl;
}

// Deletes a replaced photo so old pictures don't stay public forever. Only
// touches files in the user's own folder; failures are ignored (the photo
// is already swapped, and account deletion clears the folder anyway).
export async function removeOldAvatar(userId: string, publicUrl: string | null | undefined) {
  const marker = '/storage/v1/object/public/avatars/';
  const index = publicUrl?.indexOf(marker) ?? -1;
  if (!publicUrl || index === -1) return;
  const path = decodeURIComponent(publicUrl.slice(index + marker.length).split('?')[0]);
  if (!path.startsWith(`${userId}/`)) return;

  const { error } = await supabase.storage.from('avatars').remove([path]);
  if (error && __DEV__) console.warn('Failed to remove old avatar', error);
}
