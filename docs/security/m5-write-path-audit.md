# M5 — client write-path audit (suspension + Terms)

Taken from the database catalog after replaying every migration on `mobile-app` (b46e22e):
`pg_policies` (insert/update/delete) and every `public` function `authenticated` can execute.
Fix: `supabase/migrations/20260929080000_suspension_and_terms_enforcement.sql`.
Tests: `supabase/tests/security.sql` sections S and T.

"Before" is the state on `mobile-app`. "After" is with the M5 migration. Terms = the current
Terms version must be accepted (`has_accepted_current_terms`).

## Tables with a write policy for `authenticated`

| Table | Write | Blocked suspended before? | After | Terms after |
|---|---|---|---|---|
| connections | insert (request) | ✅ policy | ✅ + restrictive | ✅ |
| connections | update (accept) | ✅ policy | ✅ + restrictive | ✅ |
| connections | delete (remove / cancel / decline) | ❌ | ✅ restrictive | — |
| conversation_participants | update (mark read) | ❌ | ✅ restrictive | — |
| event_attendees | insert (RSVP) | ✅ policy | ✅ + restrictive | ✅ |
| event_attendees | delete (un-RSVP) | ❌ | ✅ restrictive | — |
| events | delete (creator; admin) | ❌ | ✅ restrictive (admins too) | — |
| messages | insert | ✅ policy | ✅ + restrictive | ✅ |
| profiles | insert | ❌ | ✅ restrictive | — |
| profiles | update | ❌ | ✅ restrictive | — |
| storage.objects (avatars) | insert / update / delete | ❌ | ✅ restrictive | — |
| waitlist | insert | n/a (anon only, not an account) | n/a | — |

Every other table (user_blocks, user_reports, user_consents, conversations, bump_events,
connect_tokens, account_restrictions, ...) has no client write policy, so only RPCs write them.

## RPCs `authenticated` can call that write

| RPC | Blocked suspended before? | After | Terms after |
|---|---|---|---|
| accept_terms | allowed (on purpose) | allowed | — |
| unblock_user | allowed | allowed (on purpose) | — |
| report_user | ❌ refused (`not_allowed`) | **allowed** (on purpose) | — |
| report_event | ❌ refused (`not_allowed`) | **allowed**, but doesn't count toward auto-hide | — |
| block_user | ❌ | ✅ `not_allowed` | — |
| undo_in_person_connection | ❌ | ✅ `not_allowed` | — |
| update_my_location | ❌ (hidden from map only) | ✅ raises `account_suspended` | — |
| create_connect_token | ❌ (token made; redeem failed later) | ✅ trigger on connect_tokens | ✅ |
| redeem_connect_token | ✅ `_connect_in_person` → unavailable | ✅ | ✅ caller raises `terms_not_accepted`; other side → unavailable |
| submit_bump | ✅ no_match, nothing stored | ✅ | ✅ trigger on bump_events |
| get_or_create_direct_conversation | ✅ | ✅ | — (sending is what needs Terms) |
| create_event | ✅ via `_hosting_status` | ✅ | ✅ `not_allowed` / `terms_not_accepted` |
| update_event | ✅ via `_hosting_status` | ✅ | — |
| admin_* (6 RPCs) | ❌ a suspended admin kept admin power | ✅ `_require_admin` checks suspension | — |
| get_bump_result | ❌ flips own stale bump to no_match | left open (housekeeping on own row; a suspended account can't create bumps) | — |
| delete account | Edge Function, service role | allowed | — |

Read-only RPCs (get_*, is_*, admin_list_*/admin_find_user) are unaffected: suspended users can
still read their own data.

## Merging with the other security branches

All done on `security/all` (2026-09-30). `20260930000000_security_fixups.sql` restores the aal2
hint in `_require_admin`, and adds two more rules on top of this table: every table listed above
gets a restrictive "Two-step code required" policy, and every API request (tables and RPCs) runs
`_check_request()`, which refuses a password-only session of an account with two-step on.

Original notes:

- **h1** `preview_connect_token` (new RPC, writes a rate-limit log): add
  `is_suspended(auth.uid())` → `not_allowed`, like block_user.
- **h2** replaces create/redeem_connect_token: the migration needs nothing. The connect_tokens
  trigger and `_connect_in_person` cover the new versions. In security.sql S/T, switch the calls
  to `create_connect_token(43.61504, -116.20207, 15)` and
  `redeem_connect_token(tok, null, 43.6151, -116.2021, 15)` (verified: 16/16 pass on all 11
  branches' migrations combined).
- **h4** also replaces `_require_admin` (same logic plus a hint about aal2). M5's migration runs
  later and wins, so re-add h4's `hint` line to M5's `_require_admin` when merging.
- Every branch's test setup (c1-c2 C, h1 H, h2 Q, h4 M, h5 P, m2 L, m4 R) must give its test users
  a current-Terms consent row, or their connect/message steps now fail with 42501 /
  `terms_not_accepted`.
