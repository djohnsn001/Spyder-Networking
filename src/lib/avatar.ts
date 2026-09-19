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
