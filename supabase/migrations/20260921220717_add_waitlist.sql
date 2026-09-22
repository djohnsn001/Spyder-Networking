-- Backfilled into git: this was applied directly against the database
-- (not through a committed migration) for the marketing website's
-- waitlist form. Recorded here, matching the timestamp it actually ran
-- under, so local migration history and the live database agree again.
create table public.waitlist (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  created_at timestamptz not null default now()
);

alter table public.waitlist enable row level security;

create policy "Anyone can join the waitlist"
  on public.waitlist
  for insert
  to anon
  with check (true);
