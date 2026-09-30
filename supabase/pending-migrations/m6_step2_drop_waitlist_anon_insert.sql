-- Security M6, step 2 of 2: the website can only join through join_waitlist().
--
-- NOT IN supabase/migrations ON PURPOSE. Do NOT push this until the live
-- bolas-web form calls supabase.rpc('join_waitlist', ...) instead of
-- inserting into the table. Pushing it early breaks the website's waitlist
-- form (every signup fails).
--
-- When the new form is live: move this file into supabase/migrations with a
-- fresh timestamp name (e.g. <today>000000_drop_waitlist_anon_insert.sql)
-- and db push.
--
-- After this, a direct insert from anon fails with a permission error, so
-- the "already on the list" unique-violation leak is gone too.

drop policy if exists "Anyone can join the waitlist" on public.waitlist;
revoke insert on public.waitlist from anon, authenticated;
