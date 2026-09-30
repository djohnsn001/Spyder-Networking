-- Review for security item H5 (READ-ONLY).
--
-- Lists profiles whose avatar_url is NOT null and is NOT exactly
--   <project URL>/storage/v1/object/public/avatars/<their own id>/<file name>
-- with a plain file name (letters, digits, '.', '_', '-'; no '..', no more
-- slashes, no '?'). These rows break the check constraint added in
-- 20260929040000 and tightened in 20260930000000 (and block step 2,
-- VALIDATE). Works before or after those migrations.
--
-- It only reads. The first line makes the whole run read-only, so even a
-- mistake can't write. Paste it into the Supabase SQL editor, or:
--   npx supabase db query --linked -f supabase/queries/h5_bad_avatar_urls.sql
-- (check which project is linked first: cat supabase/.temp/project-ref)
--
-- The base URLs and the file-name rule below must match
-- public.avatar_url_allowed() in the newest migration that defines it
-- (20260930000000). Change them there and here together.
--
-- Zero rows = ready for step 2. For each row it lists, either the owner
-- re-uploads their photo, or the photo is cleared (a write, so NOT here):
--   update public.profiles set avatar_url = null where id = '<id>';
-- Seed accounts: rerunning scripts/update-seed-avatars.js --confirm fixes them.

set transaction read only;

with allowed_base(url) as (
  values
    ('https://fhevoocpcnrjxyjvitai.supabase.co')  -- production
  , ('https://ojrtebubjvkhpiryilum.supabase.co')  -- dev (bolas-dev)
)
select
  p.id,
  p.username,
  p.avatar_url,
  -- the host the photo is loaded from, to spot outside servers at a glance
  substring(p.avatar_url from '^[a-zA-Z]+://([^/?#]+)') as host,
  p.updated_at
from public.profiles p
where p.avatar_url is not null
  and not exists (
    select 1
    from allowed_base b
    where starts_with(
      p.avatar_url,
      b.url || '/storage/v1/object/public/avatars/' || p.id::text || '/'
    )
    and split_part(p.avatar_url, '/avatars/' || p.id::text || '/', 2) ~ '^[A-Za-z0-9._-]{1,100}$'
    and strpos(split_part(p.avatar_url, '/avatars/' || p.id::text || '/', 2), '..') = 0
  )
order by p.updated_at desc;
