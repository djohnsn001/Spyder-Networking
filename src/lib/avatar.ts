import { ImageManipulator, SaveFormat } from 'expo-image-manipulator';

import { supabase } from '@/lib/supabase';

// Longest side of an uploaded profile photo, in pixels. The avatars bucket
// also rejects files over 2 MB (security item M3).
const MaxAvatarPixels = 1024;
const AvatarJpegQuality = 0.8;

// Re-draws the photo as a fresh JPEG, at most 1024 px on its longest side.
// Re-encoding writes only the pixels, so EXIF metadata from the camera (GPS
// location, device, time) is left behind; the picker's exif: false only
// hides it from the app, it doesn't remove it from the file. Rotation from
// the camera is applied to the pixels first, so the photo isn't sideways.
async function toAvatarJpeg(uri: string): Promise<string> {
  let image = await ImageManipulator.manipulate(uri).renderAsync();
  if (Math.max(image.width, image.height) > MaxAvatarPixels) {
    const resized = await ImageManipulator.manipulate(image)
      .resize(image.width >= image.height ? { width: MaxAvatarPixels } : { height: MaxAvatarPixels })
      .renderAsync();
    image.release();
    image = resized;
  }
  try {
    const result = await image.saveAsync({ format: SaveFormat.JPEG, compress: AvatarJpegQuality });
    return result.uri;
  } finally {
    image.release();
  }
}

// Uploads a picked image to the avatars bucket under the user's own folder
// (required by the storage RLS policies) and returns its public URL. Always
// uploads the re-encoded JPEG, never the original file.
export async function uploadAvatar(userId: string, uri: string): Promise<string> {
  const jpegUri = await toAvatarJpeg(uri);
  const arraybuffer = await fetch(jpegUri).then((res) => res.arrayBuffer());
  const path = `${userId}/${Date.now()}.jpg`;

  const { error: uploadError } = await supabase.storage
    .from('avatars')
    .upload(path, arraybuffer, { contentType: 'image/jpeg' });
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
