-- Stored preference only — there's no push notification delivery wired up
-- yet (that needs device push tokens and a server-side trigger, which
-- don't exist in this app). This just gives the Settings toggle something
-- real to read and write for when that's built.
alter table public.profiles
  add column if not exists notifications_enabled boolean not null default true;
