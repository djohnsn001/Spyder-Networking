> DRAFT: not legal advice. Must be reviewed before publishing.

# Store submission cheat sheet

What to paste into **App Store Connect** and **Google Play Console** when submitting Bolas. Every
answer comes from [`data-inventory.md`](data-inventory.md) and
[`store-privacy-answers.md`](store-privacy-answers.md); if the app changes, update those first.
Checked 2026-09-28.

Placeholders to fill first: `{{SITE}}`, `{{SUPPORT_EMAIL}}`, `{{LEGAL_ENTITY_NAME}}`, and the demo
account details below.

---

## URLs (both stores)

| Field | Value |
|---|---|
| Privacy policy URL | `{{SITE}}/privacy` |
| Terms of use / EULA | Apple: leave as **Apple's standard EULA** (Zane's call). Link `{{SITE}}/terms` in the App Description or App Review notes. |
| Support URL | `{{SITE}}` (with the support email visible), or a `{{SITE}}/support` page |
| Marketing URL (optional) | `{{SITE}}` |
| **Account deletion URL** (Google Play → Data safety) | `{{SITE}}/delete-account` |

All of these must be **live and public** before you submit. See `web-pages-handoff.md`.

---

## Apple: App Privacy ("nutrition label")

Use the table in [`store-privacy-answers.md`](store-privacy-answers.md#apple-app-privacy-data-used-to-track-you-none):

- **Data Used to Track You: none.** Tracking: No. There's no App Tracking Transparency prompt.
- **Data Linked to You** (all for **App Functionality**): Email Address, Name, Photos or Videos,
  Emails or Text Messages (chat), Other User Content, Precise Location, Coarse Location, User ID,
  Contacts (the social graph, decision A3), Other Usage Data.
- **Not collected:** Diagnostics, Device ID, Purchases, Financial, Health, Browsing, Search
  History, Sensitive Info.

## Apple: age rating questionnaire

Apple calculates the rating from your answers and **doesn't let you pick a higher one**. The
18+ rating only comes from frequent sexual content, drugs, realistic violence, or gambling, none of
which Bolas has. So expect Apple to show roughly **13+ or 16+**. That's fine: **Bolas enforces 18+
itself** (the sign-up checkbox, plus the terms screen for existing accounts). Answer honestly:

| Item | Answer | Why |
|---|---|---|
| Unrestricted Web Access | **No** | The in-app browser opens only our legal pages and package links |
| User-Generated Content | **Yes** | Profiles, photos, events |
| Social Media | **Yes** | Profiles, connections, networking |
| Messaging and Chat | **Yes** | Direct messages between connections |
| Advertising | **No** | |
| Parental Controls | **No** | |
| Age Assurance | See note | Bolas has self-declared 18+ at sign-up. Reading 1: that counts as age assurance, so answer Yes. Reading 2: Apple means real verification (for example the Declared Age Range API, which isn't built yet), so answer No until `expo-age-range` is added (open question 5). **Read Apple's current help text for this item before answering.** |
| Mature/Suggestive, Sexual Content, Violence, Profanity, Alcohol/Drugs, Horror, Medical, Health/Wellness | **None** | Not app content. Users' posts are moderated against these (Terms and Guidelines). |
| Gambling, Simulated Gambling, Contests, Loot Boxes | **No** | |

Also, **App Store Connect → Pricing and Availability**: choose **United States only** (the U.S.-only
launch).

## Apple: App Review Information

- **Sign-in required:** Yes.
- **Demo account:** `{{DEMO_EMAIL}}` / `{{DEMO_PASSWORD}}`. Create a real account with a finished
  profile, a photo, a few connections (at least one **in person**), an event, and a chat thread.
- **Second demo account** (for testing in-person features and report/block): `{{DEMO2_EMAIL}}` /
  `{{DEMO2_PASSWORD}}`.
- **Notes for the reviewer** (paste and edit):

```
Bolas is a networking app for adults (18+) who want to start businesses. It is offered in the
United States only.

Sign-in: use the demo account above. New sign-ups must check an (unchecked) box confirming
they are 18+ and agree to the Terms and Privacy Policy.

Safety features (Guideline 1.2):
- Report a user: open any profile > "⋯" (top right) > Report. In a chat, long-press a
  message to report it, or use "⋯" in the chat header.
- Block a user: profile or chat > "⋯" > Block. Manage blocks in Profile > Settings >
  Privacy & safety > Blocked users.
- Report an event: open an event on the Map > "⋯" > Report.
- Objectionable content filter: usernames, names, bios and event text are checked against a
  blocked-terms list on our server.
- Reports are reviewed by our team within 24 hours; accounts can be suspended.
- Terms and Community Guidelines (zero tolerance for objectionable content and abusive users):
  Profile > Settings > Legal.

Account deletion (Guideline 5.1.1(v)): Profile > Settings > Delete account.

Location: optional and foreground-only. "Show me on the map" is off by default; when on, only
people the user has met in person see an approximate area (~2 km). Precise location is used
only on the Tap screen to match two phones that tap together, and deleted within minutes.

Meeting in person: the "Connect" screen (Map or Profile) connects two people who are together,
via QR code (camera) or tapping phones (motion + location). This needs two devices; the second
demo account above can be used on a second device or simulator (QR).

No ads, no tracking, no in-app purchases.
```

- **Contact info:** your name, phone, and email for App Review.

## Apple: other fields

- **Export compliance:** handled. `app.json` sets `ITSAppUsesNonExemptEncryption = false`
  (standard HTTPS only), so App Store Connect won't ask each build.
- **Sign in with Apple:** not required (Guideline 4.8). Bolas only uses its own email/password
  accounts.
- **Privacy manifest:** added in `app.json` (`ios.privacyManifests`). It needs a **new build** to
  take effect. Apple emails you after upload if a reason is missing; if it does, add it to
  `app.json` and rebuild.

---

## Google Play: App content (Policy → App content)

| Section | Answer |
|---|---|
| **Privacy policy** | `{{SITE}}/privacy` |
| **Ads** | No, the app doesn't contain ads |
| **App access** | "All or some functionality is restricted" → add the demo account(s) and the same notes as for Apple |
| **Content rating (IARC questionnaire)** | Category: **Social / Communication**. Users can interact or exchange content: **Yes**. Shares user-provided personal information with other users: **Yes** (profiles). Shares user location with other users: **Yes** (approximate, opt-in). User-generated content: **Yes**. Digital purchases: **No**. No violence, sexual content, profanity, drugs, or gambling in the app's own content. |
| **Target audience and content** | Age group: **18 and over only**. Appeals to children: **No**. |
| **Restrict Minor Access** | **Turn it on** (Play hides the app from accounts Google believes are under 18). This matches the 18+ policy. |
| **Data safety** | Use [`store-privacy-answers.md` → Google Play](store-privacy-answers.md#google-play-data-safety). Encrypted in transit: **Yes**. Deletion: **Yes**, in-app, plus `{{SITE}}/delete-account`. Maps SDK data (G1): declare it once an Android Maps API key exists. |
| **News app / Health / Financial features / Government** | No / No / None / No |
| **Account deletion** | In-app: Profile → Settings → Delete account. Web: `{{SITE}}/delete-account` |

**Permissions:** camera, location (**foreground only**; no background-location declaration
needed), photos. Microphone, `SYSTEM_ALERT_WINDOW` and `WRITE_EXTERNAL_STORAGE` are **blocked** in
`app.json`, so they won't appear in the build.

**Before Android launch:** add a **Google Maps API key** (Android maps won't load without one).
Then declare the Maps SDK data in Data safety (G1), and keep the Google Maps terms line in the Terms
(already in section 16).

---

## Before you press Submit

- [ ] Legal pages live at `{{SITE}}` (after lawyer review), and `config.ts` placeholders filled in
- [ ] `TERMS_VERSION` (app) = `_current_terms_version()` (database) = effective date on the pages
- [ ] Demo accounts created, and they work on a **production build** (not Expo Go)
- [ ] Two-account test of report / block / suspend passed (Phase 5b)
- [ ] You (or your partner) check the Admin → User reports tab daily, since the app promises 24 hours
- [ ] New build made **after** the Phase 7 `app.json` changes (privacy manifest, permissions)
- [ ] App Privacy + Data safety answers match `store-privacy-answers.md`
