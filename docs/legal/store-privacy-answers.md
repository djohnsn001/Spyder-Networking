> DRAFT: not legal advice. Must be reviewed before publishing.

# Store privacy answers (Apple App Privacy + Google Play Data Safety)

Built only from [`data-inventory.md`](data-inventory.md). If that file changes, update this one.
Definitions were checked on 2026-09-28 against:
- Apple: <https://developer.apple.com/app-store/app-privacy-details/>
- Google: <https://support.google.com/googleplay/android-developer/answer/10787469>
- Google Maps SDK for Android: <https://developers.google.com/maps/documentation/android-sdk/play-data-disclosure>

These answers describe the app **as it is today** (commit `bfdbb03`). Rows marked *(after Phase N)*
only become true once that phase ships. Resubmit the forms whenever a phase changes an answer.

## Key definitions (short version)

- **Collected** (both stores): sent off the phone and kept longer than it takes to answer the
  request. Data processed only on the phone is **not** collected. That's why camera frames,
  accelerometer readings and search text are absent below.
- **Linked to the user** (Apple): tied to the account. Everything Bolas stores has a user id, so it's
  all **linked**.
- **Tracking** (Apple): combining our data with other companies' data for ads, or giving it to a data
  broker. **Bolas does no tracking, so no App Tracking Transparency prompt is needed.**
- **Shared** (Google): given to a third party. Sending data to a **service provider** that processes
  it for us (Supabase) is **not** sharing.
- **Precise vs approximate location:** Apple uses **3+ decimal places** as the line for precise.
  Google uses an **area under 3 km²** as the line for precise. Since Phase 1b the Web Map is snapped to a
  ~5 km² grid, so it's **approximate/coarse for both** stores.

---

## Apple: App Privacy ("Data Used to Track You": **none**)

All rows: **Linked to you: Yes**, **Used for tracking: No**, **Purpose: App Functionality**
(Apple's App Functionality includes authentication, features, fraud prevention and security, which
covers moderation and rate limits).

| Apple category → type | Collect? | What it is in Bolas |
|---|---|---|
| Contact Info → **Email Address** | Yes | login email |
| Contact Info → **Name** | Yes | optional full name |
| Contact Info → Phone / Physical Address / Other | No | |
| User Content → **Photos or Videos** | Yes | profile photo |
| User Content → **Emails or Text Messages** | Yes, see ambiguity A1 | chat messages |
| User Content → **Other User Content** | Yes | bio, interests, business stage, typed city, event title/description, report details |
| User Content → Customer Support | No, see A5 | support is by email, outside the app |
| User Content → Audio / Gameplay | No | |
| Location → **Precise Location** | Yes | phone-tap GPS (kept up to ~10 min); QR code owner location (~100 m, erased on use / within 1 h); event pins, see A2 |
| Location → **Coarse Location** | Yes | Web Map position (~5 km² grid, deleted after 7 days idle or when sharing is off); "met in" city |
| Identifiers → **User ID** | Yes | account UUID, username |
| Identifiers → Device ID | No | no advertising ID or device ID is read (MapKit is part of iOS) |
| **Contacts** | Yes (A3) | connections list (social graph) |
| Usage Data → **Other Usage Data** | See A4 | RSVPs, connection requests, read position |
| Usage Data → Product Interaction / Advertising Data | No | no analytics |
| Diagnostics (crash / performance / other) | No | no crash or performance SDK |
| Other Data Types | See A6 | IP address + user-agent in login sessions |
| Health, Fitness, Financial, Sensitive Info, Browsing, Search History, Purchases, Surroundings, Body | No | motion data never leaves the phone; search is filtered on the phone |

**(after Phase 2)** consent records: these are account metadata, not a user-data type; no change expected.
**(after Phase 3)** blocks and reports: covered by Other User Content / Other Usage Data.
**(after Phase 5.8)** if the store age-range APIs are used: re-check. It may be "Other Data Types"
or not collected, if the range is only checked on the phone.

### Apple ambiguities (Zane decides)

- **A1: chat messages.** Reading 1: Apple's "Emails or Text Messages" covers "contents of the …
  message", so in-app chat goes here. Reading 2: that type means SMS/email, so chat is "Other User
  Content." **Recommend reading 1**; over-disclosing a real message feature is the safer choice.
- **A2: event pins.** Reading 1: the host picks a spot on the map, not their device location, so it's
  "Other User Content." Reading 2: it's a precise place tied to a person, so "Precise Location."
  Precise Location is declared anyway because of phone taps, so the answer doesn't change. **No
  decision needed.**
- **A3: Contacts / social graph.** Apple's Contacts type literally says "… address book, **or social
  graph**." Reading 1: the Bolas connections list is a social graph, so declare Contacts. Reading 2:
  it means importing the phone's contacts, which Bolas never does, so don't declare. **Decided (Zane, 2026-09-28): declare** Contacts (linked, App Functionality).
- **A4: RSVPs / connection activity.** Reading 1: "Other Usage Data" ("any other data about user
  activity in the app"). Reading 2: part of Other User Content, already declared. **Recommend adding
  Other Usage Data**; it costs nothing.
- **A5: support emails.** Not collected in the app. If an in-app support form is added later, it
  becomes "Customer Support."
- **A6: IP address.** Apple has no IP type. Its own example says an IP "sent on a server call and
  not retained" needn't be disclosed, but Supabase **retains** it in `auth.sessions` for the life of
  the session, and in request logs for ~1 day (Free plan). Reading 1: it's incidental to authentication and
  security, so don't declare (common practice). Reading 2: declare it under "Other Data Types."
  **Recommend reading 1**, with the privacy policy mentioning IP addresses in logs either way.

---

## Google Play: Data Safety

Global answers:
- **Is all user data encrypted in transit?** **Yes**: the app talks to Supabase only over `https://`
  (and WSS for Realtime).
- **Do you provide a way for users to request that their data be deleted?** **No, today.**
  **Yes (after Phase 4)**: in-app deletion plus the web request page (Phase 6). Play requires the web
  URL before this can be Yes.
- **Does your app collect or share any of the required user data types?** Yes.
- **Shared with third parties:** **No** for everything Bolas stores (Supabase is a service provider).
  The Google Maps SDK is the open question (G1).

| Google category → type | Collected | Shared | Optional? | Purposes | Notes |
|---|---|---|---|---|---|
| Location → **Precise location** | Yes | No | **Optional** (the app works without location permission) | App functionality | phone taps (raw GPS); QR codes (~100 m, erased on use); event pins |
| Location → **Approximate location** | Yes | No | Optional | App functionality | Web Map position (~5 km² grid); "met in" city; typed profile city |
| Personal info → **Name** | Yes | No | Optional | App functionality | |
| Personal info → **Email address** | Yes | No | **Required** | App functionality, Account management | |
| Personal info → **User IDs** | Yes | No | Required | App functionality, Account management | UUID + username |
| Messages → **Other in-app messages** | Yes | No | Optional (you can use Bolas without chatting) | App functionality | |
| Photos and videos → **Photos** | Yes | No | Optional | App functionality | profile photo |
| App activity → **Other user-generated content** | Yes | No | Optional | App functionality; Fraud prevention, security, and compliance (reports) | bio, interests, stage, events, report details |
| App activity → **Other actions** | Yes | No | Optional | App functionality; Fraud prevention, security, and compliance (rate limits) | connections, RSVPs, (after Phase 3) blocks |
| Contacts | See G2 | | | | |
| App info and performance → Crash logs / Diagnostics | See G1 | | | | Bolas itself: No |
| Device or other IDs | See G1 | | | | Bolas itself: No |
| Financial, Health, Files, Calendar, Web browsing, Audio | No | | | | |

### Google ambiguities (Zane decides)

- **G1: Google Maps SDK for Android.** No Maps API key exists yet, so this only applies once one is added before the Android launch. It's an SDK in our app. Google says it collects request
  metadata, crash stack traces, IP address and a Maps SDK identifier "to improve Google services,"
  and Google's own page marks them as shared. Reading 1: declare **App info and performance → Crash
  logs + Diagnostics** and **Device or other IDs**: collected, shared with Google, required, purpose
  Analytics. Reading 2: treat Google as a service provider and declare them collected but not
  shared. **Decided (Zane, 2026-09-28): reading 1**, declare as shared with Google. Confirm the exact type mapping on
  that page when filling the form, since it's updated with SDK versions.
- **G2: Contacts / social graph.** Google's Contacts type describes the phone's contacts ("contact
  names, message history, and social graph information like usernames, contact recency…"). Reading
  1: our connections list fits "social graph information," so declare it. Reading 2: it means device
  contacts, which Bolas never reads, so don't declare (connections are covered by "Other actions").
  **Recommend reading 2** for Google (connections are already disclosed under App activity), but
  keep it consistent with the A3 decision in the privacy policy wording.
- **G3: IP address.** Not a Google data type on its own. Google's guidance is to declare approximate
  location only if you **derive** location from the IP. Bolas doesn't, so **no extra row**.
  Approximate location is declared anyway.
- **G4: Web Map precision.** Resolved in Phase 1b: the ~5 km² grid is over Google's 3 km² line, so
  the Web Map counts as approximate. Precise location stays declared because of phone taps.

---

## Things that would change these answers

- Adding analytics, crash reporting (e.g. Sentry), push notifications, or OTA updates → new rows
  (Diagnostics / Device IDs / Product Interaction).
- Adding ads or marketing emails → new purposes, and possibly **tracking** on Apple.
- Launching outside the U.S. → the privacy policy changes, but these forms don't.
- Any Phase 2–5 item marked *(after Phase N)* above.
