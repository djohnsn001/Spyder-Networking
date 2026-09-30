# In-person connections: status

Companion to `docs/plans/in-person-connections.md`. Branch: `feature/in-person-connections`
(built on `feature/map-events`, because `mobile-app` was missing migrations that are already live).

## What's built

| Phase | What | State |
|---|---|---|
| 0 | Discovery + name mapping | Done |
| 1 | `level` / `method` / `met_*` / `undo_*` on connections, guard trigger, `_connect_in_person`, undo | Live on Supabase |
| 2 | Rotating QR codes (`connect_tokens` + 3 RPCs) | Live on Supabase |
| 3 | Phone-bump matching (`bump_events` + 2 RPCs) | Live on Supabase |
| 4a | Connect screen: My code + Scan, match card with Undo, deep link, labels, level chips, split Connections screen, entry points | **Tested on two devices ✓** |
| 4a+ | Web Map shows only in-person connections | Live on Supabase |
| 4b | Tap tab: accelerometer bump detection, location gate, dev readout + Simulate bump | Built, **not yet tested on two phones** |
| 4 polish | Keep screen awake on My code; "Location & tapping" note in Settings | Built |
| 5 | Notes for the web app: `docs/in-person-connections-for-web.md` | Done |

Database tests: `supabase/tests/in_person_connections.sql` (50 checks, sections A–E). They
always roll back, so they're safe to run on the live database:

```
npx supabase db query --linked -f supabase/tests/in_person_connections.sql
```

## Still to test (manual QA on real phones)

From the plan's QA table, not yet done:

- [ ] **Tap phones** match within ~2 s (both on the Tap tab)
- [ ] Waving / walking with the phone causes **no** false bumps
- [ ] Acquaintances who tap → "Now you've met!" (upgraded)
- [ ] Deny location → Tap shows the explanation + "Use QR instead"
- [ ] Deny location → Scan still works; the city comes from a profile
- [ ] Deny camera → explanation + Open Settings
- [ ] Screenshot of a QR scanned 2+ min later → "expired"
- [ ] Airplane mode → friendly offline message, no crash
- [ ] Signed out, open a `bolas://connect/...` link → log in, then redeem. **Needs a real
      build**, because Expo Go can't open `bolas://` links.
- [ ] iPhone ↔ Android, both directions (QR and Tap)
- [ ] Web app: send and accept an acquaintance request still works

Client unit tests: Jest isn't set up, so `bumpDetector` / `parseConnectUrl` have no unit tests.
The bump detector was checked once against synthetic samples (tap, rest, wave, shake,
cooldown), and all cases behaved as intended. Adding Jest is a decision for Zane.

Lint: `npx expo lint` fails because ESLint isn't installed in the project. This was already
the case before this feature.

## Tuning knobs

**Tap detection (app):** `BUMP_TUNING` in `src/lib/connect/bump-detector.ts`

| Knob | Start | Raise it if… | Lower it if… |
|---|---|---|---|
| `SPIKE_G` | 1.3 g | waving triggers bumps | real taps don't register |
| `JERK_G` | 1.0 g | walking triggers bumps | real taps don't register |
| `COOLDOWN_MS` | 2500 | one tap fires twice | people wait too long to retry |
| `UPDATE_INTERVAL_MS` | 16 (~60 Hz) | battery matters more | quick taps get missed |

Use the dev-only readout on the Tap tab (`peak`, `jerk`, `triggers`) to pick values: tap a few
times, note the peaks, and set `SPIKE_G` / `JERK_G` a bit below them.

**Bump matching (server):** constants at the top of `submit_bump` / `get_bump_result`.
Changing them needs a **new** migration; never edit old ones.

| Constant | Value | Meaning |
|---|---|---|
| `c_window` | 2 s | Max gap between the two bumps (server time) |
| `c_min_radius_m` / `c_max_radius_m` | 100 / 500 m | Allowed distance, scaled by GPS accuracy |
| `c_max_accuracy_m` | 1000 m | Worse GPS than this → "poor location" |
| `c_max_per_minute` | 10 | Bump rate limit |
| `c_result_wait` | 3 s | A lone bump becomes "no match" after this |
| `c_retention` | 10 min | Raw GPS is deleted after this |

**QR (server):** `create_connect_token` has `c_max_per_minute = 6` and `c_lifetime = 30 s`
(was 60 s before security item H2). `redeem_connect_token` allows max(300 m, both accuracies)
and rejects accuracy worse than 1 km. The app rotates every 25 s (`TOKEN_ROTATE_MS` in
`use-rotating-token.ts`). At busy events, 6 a
minute caps you at ~5 scans a minute; raise it if that's too tight.

## Later / out of scope (not built)

- **Universal links** (`https://<landing>/c/<token>`) so the phone's own camera opens the app.
  Needs the Apple Developer account plus `apple-app-site-association` / `assetlinks.json` on
  the Cloudflare landing page.
- **Supabase Realtime** instead of polling.
- **Physical Bolas NFC stickers or cards.** Phones *can* read NFC tags.
- **Locking per geographic cell** for bump matching at scale (today it's one global lock).
- **Push notification** "You met @x", for when a phone locks mid-match.
- **A final name** for the "Map connection" level (one line in `labels.ts`).
- **Intro requests** through mutuals.
- **"Show my code" page on the web** (see the web notes).
- **Marking which mutuals you've met in person** (plan item 4.7, optional).

## Open questions

| # | Question | Answer so far |
|---|---|---|
| 1 | Final name for the `in_person` level | Open. "Map connection" for now |
| 2 | Limit chat by level? | No change. Acquaintances can still chat |
| 3 | Separate `map_connection_count` on profiles? | Not built. Counts include both levels |
| 4 | `pg_cron` for GPS cleanup? | `pg_cron` isn't enabled. Cleanup runs on every bump instead, so rows can outlive 10 min only while nobody bumps |
| 5 | Removing an in-person connection: drop to acquaintance or remove entirely? | Removes entirely (same as today) |
| 6 | Map shows only in-person connections? | Yes, decided and live. Seed accounts no longer appear on the map |

## Heads-ups

- `app.json` now has camera, location and motion permission text. These only take effect in a
  **real build**; Expo Go shows its own wording.
- Nothing is merged into `mobile-app` or `main`. That, and any pull request, is Zane's call.
