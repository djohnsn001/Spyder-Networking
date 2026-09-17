-- Profiles table: one row per user, linked 1:1 to Supabase's built-in auth.users table.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text unique check (char_length(username) between 3 and 20),
  full_name text,
  avatar_url text,
  bio text check (char_length(bio) <= 160),
  interests text[] not null default '{}',
  business_stage text check (business_stage in ('idea', 'building', 'launched')),
  city text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Row Level Security: locked down by default, opened up by the policies below.
alter table public.profiles enable row level security;

-- Any logged-in user can read any profile (needed to browse other users / the Web Map).
create policy "Profiles are viewable by authenticated users"
  on public.profiles
  for select
  to authenticated
  using (true);

-- A user can only create the row that matches their own auth id.
create policy "Users can insert their own profile"
  on public.profiles
  for insert
  to authenticated
  with check (auth.uid() = id);

-- A user can only edit their own row, and can't change it to someone else's id.
create policy "Users can update their own profile"
  on public.profiles
  for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Auto-create an empty profile row whenever someone signs up in auth.users.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id)
  values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep updated_at current on every edit.
create function public.handle_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger on_profiles_updated
  before update on public.profiles
  for each row execute function public.handle_updated_at();
