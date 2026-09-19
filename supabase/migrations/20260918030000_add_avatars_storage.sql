-- Storage bucket for profile pictures. Public so avatar_url values are
-- plain, cacheable URLs (anyone with the direct link can view the image,
-- same exposure level as any other public CDN-hosted profile photo).
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Anyone can view avatar images (matches the bucket being public).
create policy "Avatar images are publicly accessible"
  on storage.objects for select
  using (bucket_id = 'avatars');

-- Uploads must live under a folder named after the uploader's own user id,
-- e.g. avatars/<user_id>/<filename> — this is what lets us check ownership
-- below without a separate table tracking who owns which file.
create policy "Users can upload their own avatar"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Users can update their own avatar"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "Users can delete their own avatar"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
