# Legal & app store compliance: status

Companion to `docs/plans/legal-compliance.md`. Built on branch `feature/legal-compliance` (on top
of `feature/event-safety`, whose migrations were already live; Zane's call). **Both merged into
`mobile-app` on 2026-09-28** (merge `3710793`, together with the partner's `@expo/ngrok` commit),
before the Phase 5b two-account test (Zane's call).

## What's built

| Phase | What | Commit | State |
|---|---|---|---|
| 0 | Discovery: FK/cascade table, SDK list, permissions, conflicts | — | Done |
| 1 | `docs/legal/data-inventory.md` (single source of truth) + `store-privacy-answers.md` | `b6ca875` | Done; minimization flags decided |
| 1b | Cleanup job every minute (pg_cron); map sharing opt-in, ~5 km² grid, 7-day expiry | `b969168` | **Live on Supabase** |
| 2 | Consent records (`user_consents`), `accept_terms`, `get_my_consent_status`, sign-up trigger | `456f788` | **Live** |
| 3 | Blocking, suspensions, user reports (with server snapshot), shared `blocked_terms` content filter, admin RPCs | `487e5e7` | **Live** |
| 4 | Account deletion: cascades, `delete-account` Edge Function, Settings screen, old-photo cleanup, private avatar listing | `4ac580c`, `44153b7` | **Live; deletion tested on a device ✓** |
| 5a | Sign-up checkbox, terms gate, Legal settings, licenses screen, PGRST303 retry | `1bad6a2` | Built; clock-skew fix confirmed on device |
| 5b | Report/Block (profile, chat, match card), Blocked users, suspended screen, Admin → User reports | `c307a5f` | Built, **not yet tested on two devices** |
| 5.8 | App-store age signals | — | Researched only (`expo-age-range`); nothing installed |
| 6 | Policy drafts (`docs/legal/drafts/`) + `docs/legal/web-pages-handoff.md` | `18ffc33` | Drafts; **not yet reviewed by Zane or a lawyer** |
| 7 | Contrast fixes (`npm run contrast`), Reduce Motion, large text, tap targets, permissions, privacy manifest, `store-submission.md`, `email-templates.md` | `25b0389` | Built; `app.json` changes need a **new native build** |
| 8 | `docs/legal-compliance-for-web.md` + this doc | this commit | Done |

Database tests: `supabase/tests/legal_compliance.sql`, **56 checks** (A consent, L location,
R retention, B blocking, C reports/admin/suspension, E content filter, D deletion cascade). All
passed on the live project on 2026-09-28, and `supabase/tests/event_safety.sql` (64) still passes
on top. They always roll back:

```
npx supabase db query --linked -f supabase/tests/legal_compliance.sql
```

Also: `npx tsc --noEmit` is clean, `npm run contrast` passes every pair, and `npm run licenses`
regenerates the licenses list. (`npx expo lint` still fails because ESLint isn't installed; this
was already true before this work.)

## Still to test (manual QA)

From the plan's QA table:

- [ ] 1. Sign-up without checking the box → button stays disabled
- [ ] 2. An existing account opens the updated app → terms screen once, then normal
- [ ] 3. Report a profile, then block → thanks message; the blocked user disappears everywhere
- [ ] 4. Blocked user tries the old profile / chat / QR → generic "not available" / "invalid"
- [ ] 5. Admin suspends a user → after reopening the app they see the suspended screen; others
      can't find them. Lift → back to normal
- [x] 6. Delete account from Settings → signed out, can't sign in, gone from the other user's list
      (confirmed 2026-09-28; avatar-URL 404 not separately checked)
- [ ] 7. Legal links in Settings and on sign-up → "Coming soon" until the pages are live, then the
      right pages
- [ ] 8. VoiceOver / TalkBack on sign-up, profile, report → every control announced sensibly
- [ ] 9. Largest text size → sign-up, report, delete screens still usable (they scroll now)
- [ ] 10. Web sign-up and profile → n/a today (the web is landing page + waitlist only)
- [ ] Long-press a chat message → report shows the message text in Admin → User reports
- [ ] Light mode: red "Log out / Delete account" and error messages look right with the new colors
- [ ] Android (untested throughout): checkbox, ⋯ menus, report sheet, keyboard on Delete account
- [ ] A **real build** (not Expo Go): permission prompts show the new wording; no microphone prompt

## Placeholders still unfilled

`src/lib/legal/config.ts` was filled in on 2026-09-30: Bolas Networking LLC, admin@bolasnetworking.com
(contact and support), and https://bolasnetworking.com for the 5 page URLs.

| Where | Placeholder |
|---|---|
| `config.ts` + `_current_terms_version()` | `TERMS_VERSION` `'2026-10-01'` is a placeholder date; set it to the real effective date **in both** (new migration for the DB) |
| `docs/legal/drafts/*` | `{{MAILING_ADDRESS}}` (Privacy, Terms, DMCA agent) and `{{EFFECTIVE_DATE}}` (set on publish day, with `TERMS_VERSION`). The rest were filled 2026-09-30; Terms §15 = Idaho law, Ada County courts |
| `docs/legal/store-submission.md` | demo account emails/passwords (two accounts) |
| `docs/legal/email-templates.md` | `{{SUPPORT_EMAIL}}`, `{{LEGAL_ENTITY_NAME}}`, Site URL |

## Promises the app and drafts make (keep them true)

| Promise | Where | What keeps it true |
|---|---|---|
| Reports reviewed **within 24 hours** | Report screens, Terms, Guidelines, Safety Tips, App Review notes | Someone checks **Admin → User reports** and **Flagged events** daily |
| Email deletion requests done **within 30 days** | Delete-account page | Delete in the Supabase dashboard (Auth → Users), then delete `avatars/<user id>/` in Storage |
| Data access/correction requests answered **within 30 days** | Privacy policy §7 | Handle by email |
| Tap GPS deleted **within minutes** | Settings, Privacy policy | The `bolas-retention-sweep` cron job (check `cron.job_run_details`) |
| Location **off by default**, ~2 km grid | Privacy policy, store answers | `location_sharing` default + `update_my_location` |
| **No tracking, no ads, no selling** | Everywhere | Don't add analytics or ad SDKs without updating all the docs first |

## Tuning knobs

| Knob | Where | Value |
|---|---|---|
| User reports per day | `report_user`: `c_max_per_day` (new migration to change) | 10 |
| Event reports per day, auto-hide threshold | `_event_rules()` | 10, 3 |
| Blocked terms | `public.blocked_terms` table. Add in the SQL editor: `insert into public.blocked_terms (term) values ('lowercase phrase');` Usernames match **anywhere** (after removing `_` and digits), so avoid very short terms | starter list from event safety |
| Retention | `_retention_sweep()` | stuck taps 1 min · tap rows 10 min · QR codes 1 h · map spots 7 days idle · events 30 days after end (unless an open report) · creation/RSVP logs 7 days |
| Map grid | `_coarsen_location()` | 0.02° lat × 0.03° lng (~5 km² at Boise) |
| Terms version | `TERMS_VERSION` + `_current_terms_version()` | `'2026-10-01'` (placeholder) |
| Report promise text | `LEGAL.REPORT_REVIEW_PROMISE` | "within 24 hours" |
| PGRST303 retries | `src/lib/supabase.ts` | 3 × 1 s |

## Decisions made

| Question | Decision |
|---|---|
| Branch base | `feature/event-safety` (its migrations were live) |
| Minimization flags M1–M11 | All fixes accepted except M9 (hidden read time, left as is) |
| Existing users' map sharing | Kept as they were; only new accounts start off |
| Map "you're hidden" banner | Yes, dismissible |
| Consent storage | Own table (`user_consents`), not `profiles` columns |
| Blocking and RSVPs (open question 3) | Remove RSVPs both ways |
| Chats on account deletion (open question 2) | Delete the whole conversation for both people |
| Report promise (open question 6) | "within 24 hours" |
| Licenses list | Own script, no new dependency |
| Admin UI for user reports | Added to the existing Admin screen |
| Launch area (open question 1) | United States only |
| Apple EULA | Apple's standard EULA |
| Store forms: Contacts/social graph (Apple), Maps SDK shared with Google | Declare both |
| Contrast fixes | All applied |
| Suspension also bans sign-in (open question 4) | **Open.** Not built; suspended users can still sign in (to delete their account) |
| App-store age signals (open question 5) | **Open.** Add `expo-age-range` once there's an Apple Developer account and dev builds |

## Not in scope (and why)

- **Refund policy:** Bolas has no payments.
- **Cookie banner:** the app uses no cookies. The website only needs one if it adds tracking or
  advertising cookies (see the web handoff, step 4).
- **Marketing email unsubscribe:** Bolas sends no marketing email. Supabase's auth emails are
  transactional. Any future newsletter needs consent, a working unsubscribe link, and a mailing
  address (CAN-SPAM).

## Later / recommended (not built)

- **Forgot password** on the login screen. Today every lockout is a support email.
- **Custom SMTP** for Supabase auth emails before launch (the built-in sender is for testing), and
  set the Supabase **Site URL** to the real site.
- **Google Maps API key** before any Android release, then declare the Maps SDK data (G1).
- **`expo-age-range`** for the store age signals (open question 5).
- **Column-limited profile view** and paging in Discover (M1 follow-up). Every signed-in user can
  still read every profile column.
- A dashboard tool for **email deletion requests** (today it's manual; see Promises).
- Admin **notes** on dismiss/suspend (the RPCs accept one; the Admin screen doesn't ask yet).
- ESLint setup (`npx expo lint`), and Jest for client unit tests.

## Zane's non-code checklist

- [ ] **Form an LLC** with your partner, and sign an operating agreement covering the ownership
      split, what happens if someone leaves, and **assignment of the code and brand to the company**
      (the repo is in your partner's account today).
- [ ] Get a **business email** and a **mailing address that isn't a home address** (a virtual
      mailbox works). Fill in the `config.ts` placeholders.
- [ ] Have a **lawyer review** the Terms and Privacy Policy before launch (a university
      entrepreneurship or law clinic may do this free for students). Decide governing law and
      dispute resolution with them.
- [ ] Register a **DMCA designated agent** with the U.S. Copyright Office, so user-uploaded photos
      don't expose the company to copyright liability.
- [x] Decide launch countries: **U.S. only** (2026-09-28).
- [ ] Fill in the **App Store Connect** and **Play Console** privacy forms, the age rating, URLs,
      and review notes from `docs/legal/store-submission.md`.
- [ ] Before hosting any official Bolas-run events, ask about **general liability insurance**.
- [ ] Know your duties if you ever see **child sexual abuse material** or evidence a user is a
      minor: remove it, preserve it, and report it (NCMEC for CSAM). Ask the lawyer to explain the
      process.
- [ ] Re-check the **state app store age laws** before launch; their status keeps changing.
- [ ] Confirm the **splash image** is yours to use (source unknown in Phase 0).
- [ ] Make sure someone checks **Admin → User reports** every day (the 24-hour promise).

## Heads-ups

- The `app.json` changes (permissions, privacy manifest, export compliance) only take effect in a
  **new native build**. Expo Go shows its own permission wording.
- The Supabase project is on the **Free** plan (~1 day of logs). Upgrading changes the log
  retention stated in the inventory and privacy policy.
- Merged into `mobile-app` before the 5b two-account test. If that test finds a bug, fix it on a
  new branch off `mobile-app`.
