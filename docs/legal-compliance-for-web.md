# Legal compliance: notes for the web app

The mobile app gained consent records, blocking, reports, suspensions, a content filter, and
account deletion. All of it lives in the **shared Supabase database**, so it applies to the web
too. Today the website is only the landing page and waitlist, so **nothing here breaks it**. This
doc is for when the web grows sign-up, profiles, or other app features.

The legal pages themselves (privacy, terms, and so on) are covered separately in
`docs/legal/web-pages-handoff.md`.

All of this is live on the hosted Supabase project. Migrations:

| Migration | What it adds |
|---|---|
| `20260928000000_data_retention.sql` | Cleanup job every minute; map sharing off by default; coarser map grid |
| `20260928010000_legal_consent.sql` | `user_consents`, `accept_terms`, `get_my_consent_status`, and the sign-up trigger records consent |
| `20260928020000_user_safety.sql` | Blocks, suspensions, user reports, `blocked_terms` content filter, admin RPCs |
| `20260928030000_account_deletion.sql` | Reports survive deletions; nobody can list other people's avatars |

Tests: `supabase/tests/legal_compliance.sql` (56 checks). They always roll back, so they're safe
to run against the live database:
`npx supabase db query --linked -f supabase/tests/legal_compliance.sql`

---

## Sign-up must record consent

Users must agree to the Terms and confirm they're 18+ **when they sign up**, with an **unchecked**
checkbox. Pass the agreement in the sign-up metadata:

```ts
await supabase.auth.signUp({
  email,
  password,
  options: { data: { terms_version: '2026-10-01', age_confirmed: true } },
});
```

- `terms_version` must equal `public._current_terms_version()` (currently `'2026-10-01'`; the app
  keeps it in `src/lib/legal/config.ts` as `TERMS_VERSION`). A wrong or missing value records
  nothing.
- The database records the time itself (server clock). Clients can't write `user_consents`.

**For users who signed up without it** (and after every Terms change):

| RPC | Returns |
|---|---|
| `get_my_consent_status()` | `{ current_version, accepted_version, accepted_at, needs_acceptance }` |
| `accept_terms(p_version, p_age_confirmed)` | `{ outcome: 'accepted' \| 'stale_version' \| 'age_required' }` |

If `needs_acceptance` is true, show a "Before you continue" screen with the same checkbox before
anything else. The app's version is `src/app/legal/accept.tsx`.

## Blocking (automatic through RLS)

When A blocks B, **both** disappear from each other everywhere, and B is never told. Most of it
comes for free, because the database's row rules (RLS) already filter it:

- `profiles`: people blocked either way (and suspended accounts) aren't returned.
- `events` / `event_summaries` / `event_attendees`: the other person's events and attendance are
  hidden.
- `conversations` / `messages`: the chat between them is hidden, including Realtime.
- Inserting a connection request to or from someone blocked fails (`42501`).
- `get_mutuals`, `get_connection_count`, and the in-person RPCs respect blocks.

**Watch out for:** any web-only view or `security definer` function that reads `profiles`. It
must filter with `not public.is_blocked_with(<other user id>) and not public.is_suspended(<id>)`,
because definer functions skip RLS. Show a generic "This profile isn't available" and never say
a block exists.

| RPC | Returns |
|---|---|
| `block_user(p_user_id)` | `{ outcome: 'blocked' \| 'self' \| 'not_found' }`. Also deletes their connection and RSVPs both ways |
| `unblock_user(p_user_id)` | `{ outcome: 'unblocked' }`. Doesn't restore the connection |
| `get_my_blocked_users()` | `[{ user_id, username, full_name, avatar_url, blocked_at }]` |

## Reporting

`report_user(p_user_id, p_context, p_context_id, p_reason, p_details)`:

- `p_context`: `'profile' | 'message' | 'in_person' | 'other'`. For `'message'`, pass the message
  id as `p_context_id`.
- `p_reason`: `'spam' | 'scam_or_selling' | 'harassment' | 'hate' | 'sexual_content' |
  'impersonation' | 'underage' | 'unsafe_meetup' | 'other'`.
- Returns `{ outcome: 'reported' | 'self' | 'not_found' | 'invalid' | 'rate_limited' |
  'not_allowed' }`. The limit is 10 a day.
- After a report, say "Thanks, we'll review this within 24 hours" and offer to block.

Events keep using `report_event` (unchanged).

## Content filter

Updates to `profiles.username`, `full_name`, or `bio` that contain a term from
`public.blocked_terms` fail with:

- `code`: `P0001`, `message`: `blocked_content`, `details`: the field (`username` / `full_name` /
  `bio`).

Show something like "Your bio includes something we don't allow." The same list also filters
event titles and descriptions (`create_event` / `update_event` return
`{ outcome: 'blocked_content' }`).

## Suspended accounts

An admin can suspend an account (`account_restrictions`). A suspended user:

- is invisible to everyone else;
- can't send requests, messages, RSVPs, reports, or events (`42501`, or `not_allowed` from RPCs);
- **can** sign in, read their own restriction row, read the Terms, and delete their account.

To check: `select user_id from account_restrictions where user_id = auth.uid()` returns a row
if suspended. Show a "Your account is suspended" page with support contact and a Delete account
link, and no other features.

## Account deletion

Call the same Edge Function the app uses. Never delete users from the client.

```ts
await supabase.functions.invoke('delete-account', { body: { confirm: username } });
// -> { outcome: 'deleted' } | 400 { outcome: 'confirm_mismatch' } | 401 | 500 { outcome: 'failed' }
```

It deletes the user's avatar files, any **waitlist row with the same email**, and the auth user;
the database cascades the rest. Then sign out locally:
`supabase.auth.signOut({ scope: 'local' })`.

## Other changes that could surprise the web

- **Avatars:** the `avatars` bucket is still public (photo URLs work), but **listing** the bucket
  now only shows your own folder.
- **Map location:** `location_sharing` defaults to `'off'` for new accounts. `update_my_location`
  stores nothing while it's off, and snaps positions to a ~2 km grid.
- **Cleanup job** (`bolas-retention-sweep`, every minute): events are deleted 30 days after they
  end, map spots after 7 days without an update, and tap and QR data within minutes to an hour.
  Don't build features that expect those to last.
- **Right after sign-in**, Supabase sometimes rejects the brand-new token with `PGRST303 "JWT issued
  at future"` for a second or two (a platform clock-skew bug). The app retries that one error
  (`src/lib/supabase.ts`); the web may want the same.
