-- Security M3: limits on the avatars bucket.
--
-- 20260918030000 created the bucket with no size or file-type limit, so
-- anyone signed in could store any file (up to the project-wide limit) in
-- their avatars folder, publicly served from our domain. Storage now
-- rejects, before saving:
--   * files over 2 MB (2097152 bytes)
--   * anything whose content type isn't JPEG, PNG, WebP or HEIC
--
-- The app always uploads a re-encoded JPEG of at most 1024 px (src/lib/
-- avatar.ts), usually well under 300 KB. PNG/WebP/HEIC stay allowed as
-- ordinary photo formats (and for older app versions that uploaded the
-- picked file as-is).
--
-- Existing files aren't checked or changed by this.

update storage.buckets
set file_size_limit = 2097152,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
where id = 'avatars';
