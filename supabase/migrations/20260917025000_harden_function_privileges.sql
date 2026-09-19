-- Fixes for Security Advisor warnings.
--
-- Supabase grants execute on every new public-schema function to anon,
-- authenticated, and service_role by default (its own default-privileges
-- setup, so PostgREST can expose them). Revoking from the generic SQL
-- "public" pseudo-role does nothing to that — anon and authenticated are
-- separate, explicit grants and have to be revoked by name.
--
-- handle_new_user is a trigger function (only ever meant to fire automatically
-- when a row is inserted into auth.users). Triggers don't need the firing role
-- to have execute privilege — they run under the function's own security
-- context — so it's safe to revoke this entirely from every client-facing role.
revoke execute on function public.handle_new_user() from anon, authenticated, public;

-- get_mutuals needs to stay callable by authenticated (the app calls it
-- directly for mutual-connection counts), but anonymous/unauthenticated
-- callers should never be able to run a security-definer function.
revoke execute on function public.get_mutuals(uuid) from anon, public;
grant execute on function public.get_mutuals(uuid) to authenticated;
