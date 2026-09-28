> DRAFT: not legal advice. Must be reviewed before publishing.

# Bolas data inventory

This is the **single source of truth** for what data Bolas collects. The privacy policy, Apple's App
Privacy label, and Google Play's Data Safety form must all match this file, and this file must match
the code. When the code changes what it collects, stores, shows, or keeps, update this file in the
same commit.

- **Checked against:** branch `feature/legal-compliance`, migrations through
  `20260928010000_legal_consent.sql` (Phase 2), 2026-09-28. Sections describe the state **after**
  that migration is pushed.
- **Scope:** the mobile app (iOS and Android) and the shared Supabase project. The partner's website
  only writes to `waitlist` (see section I).
- "Signed-in users" means anyone with a Bolas account. Today every signed-in user can read every
  profile (see flag M1).

---

## A. Account and profile

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Email | sign-up | `auth.users.email` (+ `auth.identities`) | login, password reset, account emails | only the user (and the team via the Supabase dashboard) | until account deletion | Supabase |
| Password | sign-up | `auth.users.encrypted_password` (bcrypt hash; the plain password is never stored) | login | nobody | until account deletion | Supabase |
| Account ID (UUID) | created by Supabase at sign-up | `auth.users.id` = `profiles.id` | links every row to the account | signed-in users (it's in every profile row and deep link) | until account deletion | Supabase |
| Sign-up and sign-in times, email-confirmed time | Supabase Auth | `auth.users` (`created_at`, `last_sign_in_at`, `email_confirmed_at`, …) | auth; account age for hosting and report trust | only the team | until account deletion | Supabase |
| Session IP address and device user-agent | Supabase Auth, on each sign-in / token refresh | `auth.sessions.ip`, `auth.sessions.user_agent` | keeping the login session; security | only the team | while the session exists (deleted on log-out or session expiry) | Supabase |
| Username | profile setup (**required**) | `profiles.username` | identity in the app, search, @mentions in UI | all signed-in users | until account deletion | Supabase |
| Full name | profile (optional) | `profiles.full_name` | shown on profile | all signed-in users | until account deletion | Supabase |
| Profile photo | photo library via image picker (optional) | Storage bucket `avatars`, path `<user_id>/<timestamp>.<ext>`; URL in `profiles.avatar_url` | shown on profile, map, chat | **anyone on the internet with the URL** (public bucket) | **forever today**: old photos are never deleted, even when replaced or on account deletion (flags M3, M4) | Supabase |
| Bio | profile (optional, ≤160 chars) | `profiles.bio` | "what I'm building" | all signed-in users | until account deletion | Supabase |
| Interests | profile (optional, fixed list of 12) | `profiles.interests` | discovery | all signed-in users | until account deletion | Supabase |
| Business stage | profile (optional: idea / building / launched) | `profiles.business_stage` | discovery | all signed-in users | until account deletion | Supabase |
| City (typed by the user) | profile (optional, free text, e.g. "Boise, ID") | `profiles.city` | shown on profile; fallback for "met in" city | all signed-in users | until account deletion | Supabase |
| Notifications setting | Settings toggle | `profiles.notifications_enabled` | nothing yet: no notifications exist (flag M6) | all signed-in users (flag M1) | until account deletion | Supabase |
| Map sharing setting | Settings toggle ("Show me on the map") | `profiles.location_sharing` (`connections` / `off`; **defaults to `off`** since migration `20260928000000`; accounts created earlier kept their setting, usually `connections`) | controls the Web Map | all signed-in users (flag M1) | until account deletion | Supabase |
| Profile created/updated times | automatic | `profiles.created_at`, `profiles.updated_at` | housekeeping | all signed-in users (flag M1) | until account deletion | Supabase |
| Admin flag | added by hand in the SQL editor | `app_admins` | moderation tools | nobody (RPC `is_admin()` answers only for yourself) | until removed or account deletion | Supabase |

## B. Connections and meeting in person

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Connection (who, status pending/accepted, level acquaintance/in_person, method request/qr/bump/legacy, created_at) | connection requests; QR scan; phone tap | `connections` | the core network | the two people in it. Others learn **that** you're connected through: mutuals (`get_mutuals`), your connection count (`get_connection_count`), map lines between two of their in-person connections (`get_connection_edges`), and event attendee lists | until either person removes it or either account is deleted | Supabase |
| Where/when you met (`met_city`, `met_at`) | in-person connect; city comes from the phone's reverse-geocode, else either person's profile city | `connections` | "Met in Boise, Sep 2026" | the two people in it | as long as the connection | Supabase (the phone asked Apple/Google for the city name; see G) |
| Undo snapshot | in-person connect | `connections.undo_until`, `undo_snapshot` | 30-second undo | the two people | cleared ~1 minute after the undo window ends (cleanup job) | Supabase |
| QR code token + result | "My code" screen | `connect_tokens` (token, owner, who scanned, result incl. both people's username/full name/avatar URL) | one-time 60 s QR codes | nobody directly (owner reads status through an RPC) | deleted after 1 hour (cleanup job runs every minute) | Supabase |
| Phone-tap ("bump") event | accelerometer on device detects the tap; phone sends **precise GPS lat/lng**, GPS accuracy, city name | `bump_events` | matching two phones that tapped together | nobody (server only) | coordinates erased as soon as the tap stops waiting (matched / ambiguous / no match), and within ~1 minute if the app never checks back; rows deleted after 10 minutes (cleanup job runs every minute) | Supabase |

## C. Location

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| **Web Map position** (snapped server-side to a 0.02° × 0.03° grid ≈ 2.2 km × 2.4 km ≈ 5 km² around Boise) | device GPS, each time the Map tab opens, **only while sharing is on** | `user_locations` (one row per user, overwritten) | Web Map pins | your **in-person** connections, only while your sharing is `connections` | deleted immediately when sharing is turned off; deleted after **7 days** without an update; the server refuses to store one while sharing is off | Supabase |
| Bump coordinates | see B | `bump_events` | see B | nobody | see B | Supabase |
| Event exact spot + place name | host picks it on the map | `event_locations` | so attendees can find the event | host, people who tapped Going, admins | as long as the event (30 days after it ends) | Supabase |
| Event approximate spot (moved 150–350 m at random) | server, at create time | `events.approx_latitude/longitude` | map circle | anyone who can see the event | as long as the event | Supabase |
| "Met in" city | see B | `connections.met_city` | see B | the two people | as long as the connection | Supabase |
| Your blue dot on the map | device GPS | **on the phone only** (`showsUserLocation`) | "you are here" | only you | not stored | Apple Maps (iOS) / Google Maps SDK (Android) draw it on the device |

## D. Events

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Event (title, description, start/end, visibility public/connections, status, going count) | host | `events` | map events | public events: all signed-in users; connections-only: host + their connections; hidden/removed: host + admins | deleted **30 days after it ends** (with its exact spot and RSVPs), or earlier by the host / account deletion. Events with any report are kept until Phase 4 (flag M10) | Supabase |
| RSVP ("Going") | tap Going | `event_attendees` | attendance, unlocks exact spot | you, the host, admins, and your own connections | until you un-RSVP, the event is deleted, or account deletion | Supabase |
| RSVP log | automatic | `event_rsvp_log` | 30-RSVPs-per-day limit | nobody | deleted after 7 days (cleanup job) | Supabase |
| Event creation log | automatic | `event_creation_log` | 5-creates-per-day limit | nobody | deleted after 7 days (cleanup job) | Supabase |
| Host permission (approved / suspended + admin note) | admins | `host_permissions` | hosting trust override | the user themselves, admins | until an admin clears it or account deletion | Supabase |

## E. Messages

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Conversation (the two people, last-message time) | first message to a connection | `conversations`, `conversation_participants` | chat | the two participants | until either account is deleted | Supabase |
| Message text (≤2000 chars) + sent time | user | `messages` | chat | the two participants (and the team via the dashboard) | **forever**: nobody can edit or delete a message; the whole conversation is deleted for **both** people when **either** account is deleted | Supabase (delivered live through Supabase Realtime) |
| Read position | opening a chat | `conversation_participants.last_read_at` | unread badges | you, **and technically the other participant** (RLS lets them read it, though the app never shows "seen"; flag M9) | as long as the conversation | Supabase |

Messages are **not end-to-end encrypted**. They're encrypted in transit (HTTPS/WSS) and at rest by
Supabase's disk encryption, and readable by anyone with database access (the team).

## F. Safety and moderation

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Event report (event, reporter, reason, details ≤500) | user | `event_reports` | moderation, auto-hide | admins | **deleted if the reporter's account or the event is deleted** (flag M10) | Supabase |
| Moderation log (admin, action, event/user, note) | admin actions | `moderation_log` | accountability between admins | nobody in-app (SQL editor) | forever; user ids become null on account deletion | Supabase |
| Blocked terms list | admins | `event_blocked_terms` | spam speed bump | nobody | until changed | Supabase |
| Consent record: terms version, accepted at, 18+ confirmed at (**no birth date**) | sign-up checkbox (Phase 5) or the consent screen | `user_consents`, one row per version accepted, server time | proof the user agreed (clickwrap) and confirmed 18+ | only the user (and the team) | until account deletion | Supabase |
| Sign-up metadata (`terms_version`, `age_confirmed`) | sign-up call | `auth.users.raw_user_meta_data` | read once by the sign-up trigger | only the team | until account deletion | Supabase |
| *Planned (Phase 3):* blocks | user | `user_blocks` | safety | the blocker only | until unblocked or either account deleted | Supabase |
| *Planned (Phase 3):* user reports incl. a server-made snapshot of the profile/message | user | `user_reports` | moderation | admins | **kept after either account is deleted** (ids set null) | Supabase |
| *Planned (Phase 3):* account suspension (+ reason) | admins | `account_restrictions` | enforcement | the user, admins | until lifted or account deletion | Supabase |

## G. Device and technical data

| Data | Source | Where stored | Why | Who can see it | How long | Sent to |
|---|---|---|---|---|---|---|
| IP address + user-agent | every login session | `auth.sessions` | auth/security | the team | life of the session | Supabase |
| API / auth / Realtime request logs (IP, path, time, status) | every request | Supabase's logging (not our tables) | platform operations | the team (dashboard) | about 1 day (the project is on Supabase's **Free** plan, confirmed 2026-09-28; Pro keeps 7 days) | Supabase |
| Coordinates → city name | phone, on the Tap/Scan screens only | not stored by the geocoder call itself | "met in" city | — | — | **Apple** (iOS `CLGeocoder`) / **Google** (Android geocoder), through `expo-location` |
| Map tiles / map usage | viewing the map | not by us | draw the map | — | — | **Apple Maps** (iOS, part of iOS); **Google Maps SDK for Android**, which Google says collects request metadata, crash stack traces, **IP address** and a **Maps SDK identifier** to improve Google services ([Google's disclosure page](https://developers.google.com/maps/documentation/android-sdk/play-data-disclosure)) |
| Crash reports | — | — | — | — | — | **none**: no crash reporting, analytics, ads, push notifications or over-the-air-update SDKs are installed |

## H. On the phone only (not "collected" under Apple's or Google's definitions)

- **Camera frames**: QR scanning happens on the device (`expo-camera`); nothing is uploaded.
- **Accelerometer / motion**: tap detection happens on the device (`expo-sensors`). Only the fact that a tap happened, plus location, is sent (see B).
- **Photo library**: only the one photo the user picks is uploaded; the library itself is never read or sent.
- **Discover search text**: filtered on the phone and never sent. (Discover downloads every profile first; see flag M1.)
- **Login session token**: stored on the phone in AsyncStorage.
- **Theme preference**: AsyncStorage.
- **A pending `bolas://connect/...` link**: held in memory until sign-in.

## I. Website (partner's site, same Supabase project)

| Data | Source | Where stored | Why | Who can see it | How long | Sent to |
|---|---|---|---|---|---|---|
| Waitlist email | website form | `waitlist` | launch list | only the team | no expiry set | Supabase (+ whatever the website host/analytics collect; check in the `bolas-web` handoff) |

## Service providers (who we send data to)

| Provider | What they get | Role |
|---|---|---|
| **Supabase** | everything in A–F and I, plus request logs | database, auth, file storage, realtime (processor acting for Bolas) |
| **Apple** | coordinates for city lookup; map tile requests (iOS) | OS services |
| **Google** | coordinates for city lookup; Maps SDK data listed in G (Android) | OS services + Maps SDK. **Google Maps Platform terms require our Terms to point users to Google's terms and privacy policy** (for Phase 6). **No Google Maps API key exists yet** (confirmed 2026-09-28), so the Android map won't load in a real build until one is added. Once it is, the Maps SDK data above applies. |
| **Expo / EAS** | the app code at build time; no user data at runtime (no `expo-updates` or EAS Insights installed) | build service |
| **Apple App Store / Google Play** | purchase-free install data, their own crash reports if the user opts in | stores |

Not used: analytics, advertising, data brokers, cross-app tracking. **Bolas does no tracking** (in
Apple's sense) and sells no data.

---

## Minimization review

These are the places where Bolas collects something it doesn't need, keeps it longer than needed, or
exposes more than intended. **Nothing here has been changed.** Each flag needs a decision from Zane.

| # | Finding | Why it matters | Recommendation |
|---|---|---|---|
| **M1** | The profiles select policy is `using (true)` and the app reads `select('*')`. Every signed-in user can read every column of every profile, including `notifications_enabled`, `location_sharing`, and timestamps. Discover downloads **all** profiles at once. Phase 2 plans to add consent timestamps to `profiles`, which would make them public too. | Over-exposure; easy scraping; the Phase 2 columns would leak. | In Phase 2, keep consent in its **own table** (`user_consents`, RLS: see only your own) instead of `profiles`. Later, consider a column-limited view for other people's profiles and paging in Discover. |
| **M2** | Cleanup of bump coordinates, bump rows, and QR tokens is **lazy**. It only runs when someone taps again or polls. If the app is closed mid-tap, precise GPS can sit in `bump_events` until the next tap by anyone. Settings already tells users it's "deleted within minutes." | The promise in Settings (and the future privacy policy) isn't guaranteed. | Add a scheduled cleanup job (Supabase `pg_cron`, every minute or five) that nulls stale coordinates and deletes rows older than 10 min / QR tokens older than 1 h. Small migration. |
| **M3** | Replacing your photo uploads a new file and **never deletes the old one**. All old photos stay public. | Keeps photos users think they removed. | Delete the previous file after a successful upload (client, through the Storage API; the storage policy already allows owners to delete). |
| **M4** | The `avatars` bucket has a select policy with no role limit, so **anyone with the app's public key can list every file** in the bucket, not just open known URLs. Public buckets don't need a select policy to serve URLs. | Makes it possible to bulk-download everyone's photos (including old ones). | Drop that select policy in a migration. Public URLs keep working. Also covered by the deletion Edge Function in Phase 4. |
| **M5** | Opening the Map tab saves your ~1 km location to `user_locations` **every time, even when sharing is off**. The row is kept **forever**. Sharing is **on by default**. CLAUDE.md says "location sharing off until the user opts in." | Contradicts the product principle and the planned privacy wording. Stale location is kept indefinitely. The rounded cell (~0.9 km²) counts as **precise** under Google's definition (<3 km²). | (a) Default `location_sharing` to `off` and ask on first Map visit. (b) Don't call `update_my_location` when sharing is off, and delete the row when the user turns sharing off. (c) Expire rows after N days of no update (e.g. 7). (d) Optionally coarsen to a ≥3 km² cell (0.02° rounding) so Google counts it as approximate. |
| **M6** | `notifications_enabled` is stored, but no notifications exist. | Collecting a setting for nothing; the policy shouldn't mention notifications. | Keep the column (harmless) but hide the Settings toggle until push exists, or leave it and say nothing in the policy. |
| **M7** | Past events (and their exact locations) are kept forever. | Exact meetup spots stay attached to people long after the event. | Delete events (cascades to locations and RSVPs) 30 days after they end, with a cron job. |
| **M8** | `event_creation_log` is kept until account deletion, but only the last 24 h matter. | Unneeded history. | Prune rows older than 7 days in the same cron job as M2/M7. |
| **M9** | The other chat participant can read your `last_read_at` through the API, although the app never shows it. | Hidden read receipts. | Low priority. Either accept it (and never promise "no read receipts"), or split read state into a table only you can read. |
| **M10** | `event_reports` rows are deleted when the reporter or the event is deleted. | Evidence disappears; a bad actor can delete their event to wipe reports against it. | Change both FKs to `on delete set null` (and snapshot the event title/description into the report) in the Phase 4 deletion migration. |
| **M11** | The `connections.undo_snapshot` / `undo_until` fields stay on the row after the 30 s window. | Minor: an old state snapshot is kept. | Low priority. Clear them in the M2 cleanup job. |

### Decisions (Zane, 2026-09-28)

All recommendations accepted, except M9 (left as-is for now). Where each fix lands:

| Flag | Fix | Lands in |
|---|---|---|
| M1 | Consent stored in its own private table, not on `profiles`. A column-limited profile view and Discover paging are deferred. | Phase 2 |
| M2, M7, M8, M11 | One scheduled cleanup job (Supabase Cron): stale bump coords/rows, old QR tokens, events 30 days after they end, creation log > 7 days, expired undo fields | **Phase 1b** (new, small) |
| M5 | Map sharing defaults to off; no location save while off; row deleted when sharing is turned off; rows expire after 7 days; round to a ≥3 km² cell (optional part d) | **Phase 1b** |
| M3 | Delete the previous photo after a new upload | Phase 4 |
| M4 | Drop the storage policy that lets anyone list the `avatars` bucket | Phase 4 |
| M10 | `event_reports` FKs become `on delete set null`, plus a snapshot of the event | Phase 4 |
| M6 | Hide the notifications toggle until push exists | Phase 5.4 |
| M9 | No change for now; the privacy policy must not promise "no read receipts" | — |
