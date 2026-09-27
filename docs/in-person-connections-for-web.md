# In-person connections: notes for the web app

The mobile app now has **two levels of connection**. This doc covers what changed in the
shared Supabase database, what the web app can and can't do, and the new RPCs, in case the
web wants to use them.

All of this is live on the hosted Supabase project. Migrations:

| Migration | What it adds |
|---|---|
| `20260927000000_connection_levels.sql` | Levels on `connections`, the guard trigger, undo |
| `20260927010000_connect_tokens.sql` | Rotating QR codes |
| `20260927020000_bump_events.sql` | Phone-bump matching |
| `20260927030000_map_in_person_only.sql` | Web Map shows only in-person connections |

Tests: `supabase/tests/in_person_connections.sql`. They always roll back, so they're safe to
run against the live database:
`npx supabase db query --linked -f supabase/tests/in_person_connections.sql`

---

## The two levels

| Level (DB value) | Label | How you get it |
|---|---|---|
| `acquaintance` | "Acquaintance" | The normal request flow: send → pending → accepted. Works anywhere, including the web. |
| `in_person` | "Map connection" (working name) | **Only** by meeting in person: scanning a QR code or tapping phones in the mobile app. |

Every connection that existed before this change is now `acquaintance` with `method = 'legacy'`.
Nothing was deleted, and pending requests are still pending.

## New columns on `public.connections`

| Column | Type | Notes |
|---|---|---|
| `level` | `connection_level` enum: `acquaintance`, `in_person` | Default `acquaintance` |
| `method` | `connection_method` enum: `request`, `qr`, `bump`, `legacy` | How the current level was reached |
| `met_at` | `timestamptz`, nullable | When they met in person |
| `met_city` | `text`, nullable, ≤ 80 chars | **City name only.** Coordinates are never stored on connections. |
| `undo_until` | `timestamptz`, nullable | Server-managed undo window (30 s) |
| `undo_snapshot` | `jsonb`, nullable | Server-managed; the previous state, used by undo |

Constraint: an `in_person` row is always `status = 'accepted'` with `met_at` set.

TypeScript types (hand-written in the mobile app, `src/lib/types.ts`):

```ts
export type ConnectionLevel = 'acquaintance' | 'in_person';
export type ConnectionMethod = 'request' | 'qr' | 'bump' | 'legacy';
// ConnectionRow gains: level, method, met_at, met_city, undo_until, undo_snapshot
```

## What the web app can still do (unchanged)

- **Send a request:** `insert into connections (requester_id, addressee_id)`. It always lands as
  a pending `acquaintance`.
- **Accept:** the addressee updates `status` to `'accepted'`.
- **Decline / cancel / remove:** delete the row. This also removes in-person connections
  entirely.
- **Chat, events, connection counts, mutuals:** all still count **both** levels.

## What the web app can't do

A trigger (`connections_guard`) makes `in_person` impossible to set from any client: web,
mobile, or a hand-crafted API call.

- An insert that asks for `level = 'in_person'` (or sets `method`, `met_*`, `undo_*`) is
  silently forced back to a plain request.
- An update that changes `level`, `method`, `met_at`, `met_city`, `undo_until` or
  `undo_snapshot` fails with error `42501`.

Only the server functions below can create `in_person` connections. If the web ever writes
those columns, expect that error.

## Web Map change

`get_connection_locations()` and `get_connection_edges()` now return **only `in_person`
connections**. Their signatures didn't change, so a web map calling them gets the filtered
results automatically.
- **Pins:** people you've met in person, plus your own pin.
- **Lines between two of your connections:** only drawn when those two have also met each
  other in person.

## RPCs

All of these require a signed-in user (`authenticated`). Signed-out users (`anon`) can't call
them. Each one returns JSON.

### QR codes

| RPC | Returns |
|---|---|
| `create_connect_token()` | `{ outcome: 'ok', token, expires_at }` or `{ outcome: 'rate_limited' }`. The token is 32 hex chars, expires in 60 s, and works once. Limit: 6 per minute. |
| `redeem_connect_token(p_token, p_city default null)` | On failure: `{ outcome: 'invalid' \| 'used' \| 'expired' \| 'self' }`. On success: `{ outcome: 'created' \| 'upgraded' \| 'already_connected', connection_id, met_city, undo_until, other_user_id, other_profile }` |
| `get_connect_token_status(p_token)` | `{ status: 'active' \| 'expired' \| 'used' \| 'not_found', result, other_profile }`. Only the code's owner can see it. The mobile app polls this every ~1 s while a code is on screen. |

The QR encodes `bolas://connect/<token>`.

### Phone bumps (mobile only)

| RPC | Returns |
|---|---|
| `submit_bump(p_lat, p_lng, p_accuracy_m, p_city default null)` | `{ status: 'waiting' \| 'matched' \| 'ambiguous', bump_id, ... }` or `{ status: 'poor_location' \| 'rate_limited' }` |
| `get_bump_result(p_bump_id)` | `{ status: 'waiting' \| 'matched' \| 'ambiguous' \| 'no_match' \| 'not_found', bump_id, ... }` |

Raw GPS lives only in `bump_events`. It's erased as soon as a bump stops waiting, and every
row is deleted after 10 minutes.

### Undo

| RPC | Returns |
|---|---|
| `undo_in_person_connection(p_connection_id)` | `{ outcome: 'undone' \| 'too_late' \| 'not_found' }`. Either person can undo within 30 s. A brand-new connection is deleted; an upgrade is restored to exactly what it was. |

`other_profile` is always `{ id, username, full_name, avatar_url }`.

## Shared level names

The mobile app keeps every user-facing level name in one file, `src/lib/connect/labels.ts`:

```ts
export const CONNECTION_LEVEL_LABEL = {
  acquaintance: 'Acquaintance',
  in_person: 'Map connection', // working name, final name TBD
};
```

If the web shows levels, please use the same names, ideally from a matching constants file,
so a rename is one line in each app.

## Optional web idea: "Show my code"

The web can't detect phone bumps, but it could show a QR code:
1. Call `create_connect_token()` every ~30 s.
2. Render `bolas://connect/<token>` as a QR code.
3. Poll `get_connect_token_status(token)` every ~1 s to show "You met @name" when a phone
   scans it.

Useful at events with a laptop on a table.
