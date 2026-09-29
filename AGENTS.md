# Expo HAS CHANGED

Read the exact versioned docs at https://docs.expo.dev/versions/v57.0.0/ before writing any code.

# Security rules

For any coding agent working in this repo.

1. **The database is the security boundary.** Anyone can pull the public Supabase key out of the
   app and call the API directly. Enforce every permission, limit, and validation in SQL: RLS
   policies, constraints, triggers, or security-definer RPCs. Checks in the app are UX only.
2. **Schema changes go in a new file** in `supabase/migrations/`, named with a 14-digit timestamp
   (`YYYYMMDDHHMMSS_description.sql`). Never edit an existing migration.
3. **New tables:** enable RLS and add explicit grants (Supabase requires them after Oct 30, 2026).
   Grant `anon` nothing unless the table truly needs public access.
4. **Security-definer functions:** always `set search_path = public`, and check that `auth.uid()`
   is not null. Then `revoke execute ... from public, anon` and grant only to the roles that need
   it. Internal helpers get no grants at all.
5. **Every security fix ships with tests** in `supabase/tests/security.sql`, in the same style as
   `supabase/tests/legal_compliance.sql`: one `DO` block that always raises at the end, so
   everything rolls back, with PASS/FAIL lines in the report. Tests must include the attack, not
   just the happy path.
6. **Never write to production.** Don't run `supabase db push`, `npm run db:push`, or anything else
   that writes to the production project (ref `fhevoocpcnrjxyjvitai`). Stop and give the exact
   command to run instead. Running the rolled-back test files is allowed.
7. **Never print, log, or commit secrets.** The service key never gets an `EXPO_PUBLIC_` prefix and
   never appears in app code.
8. **Work on a branch** named `security/<item-id>` (e.g. `security/c1-c2`) created from
   `mobile-app`. Commit when done, with a clear message. Don't push unless asked.
9. **When finished, summarize:** what changed, how it was tested, and anything that must be done by
   hand (dashboard settings, `db push`).
