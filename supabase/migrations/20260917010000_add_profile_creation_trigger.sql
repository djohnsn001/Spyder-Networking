-- The original create_profiles migration was only partially applied by hand in the
-- Supabase dashboard: the table, RLS policies, and updated_at trigger existed, but this
-- function/trigger (which auto-creates a profile row when someone signs up) was missing.
-- Re-creating it here so it's tracked in git and reproducible from a fresh database.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill any accounts that signed up before this trigger existed.
insert into public.profiles (id)
select id from auth.users
where id not in (select id from public.profiles)
on conflict (id) do nothing;
