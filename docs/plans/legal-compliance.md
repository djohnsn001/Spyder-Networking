# Bolas: Legal & App Store Compliance: Build Plan for Claude Code

> **How to use this file:** save it in the repo at `docs/plans/legal-compliance.md`, then tell Claude Code:
> *"Read docs/plans/legal-compliance.md and start Phase 0. Stop at each checkpoint."*

---

## 0. Read this first (instructions for Claude Code)

**Who you're working with.** Zane builds the Bolas mobile app (Expo) and learns by doing. For every phase:

1. Before changing anything, explain in plain language **what** you're about to do and **why** (including which legal or store rule it satisfies).
2. Work in small, reviewable steps.
3. At each **CHECKPOINT**, stop. Summarize what changed and give Zane exact steps to test it. Wait for his OK.

**You are not a lawyer, and neither is Zane.**

- Any policy text you write is a **draft**. Start every draft file with: `> DRAFT: not legal advice. Must be reviewed before publishing.`
- **Never invent facts** about the business (legal name, address, state of formation, governing law, contact emails). Use the placeholders in `src/lib/legal/config.ts` (Phase 5) and list every placeholder in your checkpoint notes.
- Policies must describe what the code **actually** does. If the code and a draft disagree, the code wins and the draft gets fixed, or you flag it to Zane.

**Repo rules (from AGENTS.md):** read the **Expo SDK 57 versioned docs** before writing code that uses any Expo package (`expo-web-browser`, `expo-router`, app config / privacy manifests, etc.). Use the official Expo plugin.

**Git:** branch off `mobile-app` as `feature/legal-compliance`. Commit at the end of each phase. Don't push, open PRs, or merge without asking.

**Supabase:**

- New migrations only in `supabase/migrations`. Never edit old ones.
- This project tests against the **linked (live) project**. Don't run `db push` or `functions deploy` without Zane's explicit OK.
- DB tests go in `supabase/tests/legal_compliance.sql`, written like `event_safety.sql`: everything in a transaction that **rolls back**, run with
  `npx supabase db query --linked -f supabase/tests/legal_compliance.sql`.
- **Grants rule** (mandatory after Oct 30, 2026): every new table gets these grants, with RLS enabled:

  ```sql
  grant select on public.your_table to anon;
  grant select, insert, update, delete on public.your_table to authenticated;
  grant select, insert, update, delete on public.your_table to service_role;
  ```

  A table with RLS on and **no policies** can't be reached by clients. That's intended for internal tables.
- Every `SECURITY DEFINER` function sets `search_path = public`. Revoke execute from `public` and `anon`, then grant to `authenticated` only if clients should call it. Private helpers start with `_` and aren't granted.

---

## 1. What we're adding and why

Bolas is a social app for adults that collects profiles, photos, location (briefly), and lets strangers message and **meet in person**. The legal risk isn't cookies or refunds (the app has neither yet). It's app store rejection, privacy promises that don't match the code, minors getting in, and harm from in-person meetups.

| # | Requirement | Why it's required | Where it's handled |
|---|---|---|---|
| 1 | Privacy policy, linked in the app and the store listing | Apple and Google both require it. The FTC treats a policy that doesn't match reality as deception. | Phases 1, 6 |
| 2 | Terms of service accepted at sign-up, with a record of acceptance | Terms are only enforceable if users clearly agreed (clickwrap). Apple requires terms saying there's no tolerance for objectionable content or abusive users. | Phases 2, 5, 6 |
| 3 | 18+ only, confirmed at sign-up, plus app store age signals | Bolas is 18+ (Zane's decision). State "App Store Accountability Acts" (Texas in effect; Utah, Louisiana, California, Alabama in 2027) apply to **all** apps and expect developers to use app store age data. | Phases 2, 5 |
| 4 | Report users, profiles and messages; block users; filter objectionable content; admin review | Apple Guideline 1.2 for apps with user-generated content. Also the main real-world safety tool. | Phase 3 |
| 5 | In-app account deletion that actually deletes | Apple Guideline 5.1.1(v). Google Play also requires a **web** way to request deletion without reinstalling. | Phases 4, 6 |
| 6 | Data inventory and minimization | Feeds the privacy policy, Apple privacy labels, and Google's Data Safety form. All three must match. | Phase 1 |
| 7 | iOS privacy manifest, accurate permission prompts, no unused permissions | Apple rejects apps without required-reason declarations or with vague permission strings. | Phase 7 |
| 8 | Open-source license notices | MIT/BSD/Apache licenses require including their notices when you ship the code. | Phase 5 |
| 9 | Accessibility basics | Low cost, reduces ADA exposure, and required by good store review. | Phase 7 |
| 10 | Meetup safety tips and community guidelines | Reduces harm and supports the terms' assumption-of-risk language. | Phases 5, 6 |
| 11 | Legal pages on the web (privacy, terms, guidelines, safety, delete-account) | Store listings need public URLs. | Phase 6 (separate `bolas-web` repo) |

**Not in scope yet (document why in the status doc):** refund policy (no payments), cookie banner (the app uses no cookies; the web only needs one if tracking/analytics cookies are added), marketing email unsubscribe (no marketing emails yet; Supabase auth emails are transactional).

**Things only Zane can do** are listed at the end ("Zane's non-code checklist"). Mention them in the final summary; don't try to do them.

---

## Phase 0: Discovery (no code changes)

1. Read `AGENTS.md`, `CLAUDE.md`, `app.json` / `app.config.*`, `package.json`, `eas.json`, and every doc in `docs/` (especially `in-person-connections-status.md`, `event-safety-status.md` if it exists, and both plans in `docs/plans/`).
2. Find out which earlier features are **actually built**: in-person connections (levels, bump, QR), event safety (`app_admins`, `is_admin()`, `event_reports`, admin screen, `event_blocked_terms`). This plan reuses them if they exist and builds the minimum if they don't.
3. Read **every** migration. Write down:
   - every table, and every foreign key to `auth.users` or `profiles` with its `on delete` behavior (cascade, set null, restrict, or none)
   - the `handle_new_user` (profile auto-create) trigger and what it reads from `raw_user_meta_data`
   - the select policy on `profiles` (who can see whom)
   - the chat/messages tables and their policies (does chat exist? what's the table name?)
   - the avatars bucket: public or private, and the file path pattern (e.g. `<user_id>/avatar.jpg`)
   - whether any Edge Functions exist (`supabase/functions/`)
4. Find the sign-up and sign-in screens, the auth/route gate that forces profile setup, the Settings screen, public profile screens, and chat screens.
5. **SDK inventory:** list every dependency in `package.json` that sends data off the device or touches personal data (Supabase, Expo Updates, expo-location, expo-camera, image picker, any analytics, crash reporting, or push). For each: what it sends and to whom.
6. List every permission the built app will request (iOS Info.plist strings from config plugins; Android permissions, including ones added automatically, like `RECORD_AUDIO` from camera).
7. Check `supabase/config.toml` and the dashboard-managed email templates (ask Zane if they aren't in the repo): do they name Bolas and include a support contact?
8. List custom fonts, images, and illustrations in `assets/` and where they came from (ask Zane if unknown).
9. Run `git status`. If there's uncommitted work, **stop and ask**.

**Output:** a "Current state" note for Zane including the FK/cascade table, the SDK list, the permission list, what's built from earlier plans, and any conflicts with this plan.

**CHECKPOINT 0:** Zane OKs it. Create the branch.

---

## Phase 1: Data inventory and minimization (docs, small fixes only)

Create `docs/legal/data-inventory.md`. This is the **single source of truth** for the privacy policy and both store privacy forms.

For each piece of data, one row:

| Data | Source | Where stored | Why we need it | Who can see it | How long we keep it | Sent to |
|---|---|---|---|---|---|---|
| Email | sign-up | `auth.users` | login, account emails | only the user | until account deletion | Supabase |
| Precise location | device, only on the Tap tab | `bump_events` | matching phone taps | nobody (server only) | ≤ 10 minutes | Supabase |
| … | | | | | | |

Cover at least: email, password (hashed by Supabase), username, full name, avatar, bio, interests, business stage, city, notification setting, connections (+ `met_city`, `met_at`), bump events, QR tokens, events (exact and approximate location), RSVPs, chat messages, reports, blocks, consent records (Phase 2), device/diagnostic data from any SDK.

Then:

1. **Minimization review:** flag anything collected but not used, or kept longer than needed. **Don't remove anything yourself.** List it for Zane with a recommendation.
2. Create `docs/legal/store-privacy-answers.md`: map the inventory to
   - Apple App Privacy categories (Contact Info, User Content, Location: Precise/Coarse, Identifiers, Usage Data, Diagnostics), each marked linked-to-user / used-for-tracking (should be **no tracking** anywhere)
   - Google Play Data Safety categories (collected / shared / optional / purpose / encrypted in transit / deletable)

   Read the current Apple and Google definitions before answering. Where a category is ambiguous, write down both readings for Zane.

**CHECKPOINT 1:** Zane reviews the inventory and decides on each minimization flag. Commit.

---

## Phase 2: DB: consent records and age confirmation

**Migration:** `<ts>_legal_consent.sql`

### 2.1 Columns on `profiles`

```sql
alter table public.profiles
  add column terms_version     text,
  add column terms_accepted_at timestamptz,
  add column age_confirmed_at  timestamptz;
```

We store **that** the user confirmed they're 18+, not their birth date. That's data minimization.

### 2.2 Current version (one place)

```sql
create or replace function public._current_terms_version()
returns text language sql immutable as $$ select '2026-10-01' $$;   -- placeholder date; bump when terms change
```

The client mirrors this in `src/lib/legal/config.ts` as `TERMS_VERSION`. Add a comment in both places saying they must match.

### 2.3 Record consent at sign-up

The sign-up call passes `options.data = { terms_version, age_confirmed: true }`. Write a **new** migration that replaces `handle_new_user` (don't edit the old migration) so that, when `age_confirmed` is true and `terms_version` matches `_current_terms_version()`, it sets all three columns using the **server's** `now()`. Keep everything the trigger already does.

### 2.4 `accept_terms(p_version text, p_age_confirmed boolean)` → jsonb

For existing users and for future terms updates:

- Require `auth.uid()`.
- `p_version` must equal `_current_terms_version()`, otherwise `{outcome: 'stale_version'}`.
- `p_age_confirmed` must be true, otherwise `{outcome: 'age_required'}`.
- Sets the three columns with `now()`. Returns `{outcome: 'accepted'}`.

### 2.5 Guard

Clients must not write these three columns directly (no backdating, no faking consent). Add a `before update` trigger on `profiles`, using the same trusted-flag pattern as `connections_guard`: if the flag isn't on and any of the three columns changed, raise `42501`. `accept_terms` and `handle_new_user` set the flag. Check that the existing edit-profile flow still works.

### 2.6 Helper

`get_my_consent_status()` → `{ current_version, accepted_version, needs_acceptance: bool }`. Grant to `authenticated`.

**CHECKPOINT 2:** run test section **A (consent)**. Commit.

---

## Phase 3: DB: blocking, user reports, filtering, moderation

**Migration:** `<ts>_user_safety.sql`

### 3.1 Blocks

```sql
create table public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.user_blocks enable row level security;
create policy "Users see their own blocks"
  on public.user_blocks for select to authenticated using (blocker_id = auth.uid());
-- no insert/update/delete policies: block_user / unblock_user RPCs only
-- + the 3 standard grants

create or replace function public.is_blocked_between(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = p_a and blocked_id = p_b) or (blocker_id = p_b and blocked_id = p_a)
  );
$$;
-- grant to authenticated (policies call it); revoke from public, anon
```

**`block_user(p_user_id)`** → jsonb: insert the block (idempotent), **delete any connection row between the two** (any status, any level; use the trusted flag if the guard requires it), delete pending requests, and remove the blocked user's RSVPs from the blocker's events only if Zane says so (open question 3). Returns `{outcome: 'blocked'}`.
**`unblock_user(p_user_id)`** → deletes the block. It does **not** restore the connection.
**`get_my_blocked_users()`** → id, username, full_name, avatar_url for the Settings list.

**Effects of a block (both directions). Update these policies/functions in the same migration:**

| Where | Change |
|---|---|
| `profiles` select policy | hide profiles where `is_blocked_between(auth.uid(), id)` (a user can always see their own) |
| Discover, mutuals, search queries/views | same filter (check views are `security_invoker` so RLS applies) |
| `connections` insert policy | can't request someone blocked either way |
| Chat/messages insert policy (if chat exists) | can't message someone blocked; existing threads hidden |
| `_connect_in_person` | the `blocks` placeholder from the in-person plan: return `{outcome: 'unavailable'}` |
| `redeem_connect_token`, bump matching | pass through `unavailable`; never reveal that a block exists |
| Events select / attendees (if event safety is built) | hide the blocked user's events and attendance from the blocker and vice versa |

The blocked person is **never told** they were blocked. Every message they see is generic ("This profile isn't available").

Check query performance: `is_blocked_between` runs per row. The primary key covers one direction; add an index on `(blocked_id, blocker_id)` for the other.

### 3.2 Account restrictions (app-wide)

If `app_admins` / `is_admin()` don't exist yet, create them exactly as in `event-safety.md` §1.1.

```sql
create table public.account_restrictions (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  status     text not null check (status in ('suspended')),
  reason     text check (char_length(reason) <= 300),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null
);
alter table public.account_restrictions enable row level security;
create policy "Users can see their own restriction"
  on public.account_restrictions for select to authenticated using (user_id = auth.uid());
-- + the 3 standard grants

create or replace function public.is_suspended(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.account_restrictions where user_id = p_uid);
$$;
```

A suspended user:
- is hidden from everyone else (add `not is_suspended(id)` to the profiles select policy, next to the block check)
- can't send connection requests, messages, RSVPs, reports, or create events (add `not is_suspended(auth.uid())` to those insert policies / RPCs)
- can still sign in, see a "Your account is suspended" screen, read the terms, contact support, and **delete their account**

(Whether to also ban them at the auth level is open question 4. Don't build it now.)

### 3.3 User reports

```sql
create table public.user_reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid references public.profiles (id) on delete set null,   -- keep the report if the reporter deletes their account
  reported_user_id uuid references public.profiles (id) on delete set null,   -- keep the evidence if the reported user deletes theirs
  context          text not null check (context in ('profile', 'message', 'in_person', 'other')),
  context_id       uuid,          -- e.g. message id
  reason           text not null check (reason in ('spam', 'scam_or_selling', 'harassment', 'hate', 'sexual_content', 'impersonation', 'underage', 'unsafe_meetup', 'other')),
  details          text check (char_length(details) <= 500),
  snapshot         jsonb,         -- copy of the reported profile fields / message text at report time
  status           text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at       timestamptz not null default now()
);
alter table public.user_reports enable row level security;   -- no policies; RPCs only
-- + the 3 standard grants
```

**`report_user(p_user_id, p_context, p_context_id, p_reason, p_details)`** → jsonb:

1. Require auth. Not yourself (`self`). Rate limit: 10 reports per day (`rate_limited`).
2. The caller must be able to see the user, or (for `message`) be a participant in that message's conversation. Check explicitly: definer functions skip RLS.
3. Build `snapshot` server-side (username, full_name, bio, avatar path; or the message text and sent time). Never trust the client for evidence.
4. Insert. Return `{outcome: 'reported'}`. The app also offers "Block @name too?" right after.
5. `underage` reports get flagged as priority in the admin list (see below).

### 3.4 Content filter (Apple 1.2 "method for filtering objectionable material")

- If `event_blocked_terms` exists, **generalize** it: create `public.blocked_terms` (same shape), copy the rows over, and point the event check at the new table in a new migration. Otherwise create `blocked_terms` with the starter list from `event-safety.md` §1.8.
- Add a `before insert or update` trigger on `profiles` that rejects a `username`, `full_name`, or `bio` containing a blocked term (errcode `P0001`, message `blocked_content`). Match on normalized lowercase text; for usernames also strip underscores and digits before checking.
- Don't filter chat messages. Report + block covers chat, and filtering private messages causes false positives.
- Zane adds terms (including slurs) himself in the SQL editor. Put the insert statement in the checkpoint notes.

### 3.5 Admin RPCs (each starts with `if not is_admin() then raise ... errcode '42501'`)

| RPC | What it does |
|---|---|
| `admin_list_user_reports(p_status default 'open')` | Reports grouped by reported user: counts by reason, latest snapshot, reporter usernames, `underage` first, then newest. |
| `admin_resolve_user_report(p_report_id, p_status, p_note)` | Marks `dismissed` or `actioned`. |
| `admin_set_account_status(p_user_id, p_status, p_reason)` | `'suspended'` inserts the restriction (and, if event safety is built, sets their upcoming events to `removed`). `null` lifts it. Marks their open reports `actioned` when suspending. |

**CHECKPOINT 3:** run test sections **B (blocking)**, **C (reports and admin)**, **E (filter)**. Show Zane that a blocked user can't see, message, request, or in-person-connect with the blocker, and gets only generic messages. Commit.

---

## Phase 4: Account deletion

### 4.1 Make deletion complete (DB)

**Migration:** `<ts>_account_deletion_cascades.sql`

Using the FK table from Phase 0, make sure deleting a row in `auth.users` removes or detaches **everything**:

| Data | On user deletion |
|---|---|
| profile, connections, blocks (both sides), RSVPs, QR tokens, bump events, consent columns | deleted (cascade) |
| events they host | deleted (cascade), which also removes RSVPs and locations |
| their chat messages | ask Zane (open question 2). Default: delete them. |
| reports they filed / reports about them | kept, with the user id set to null (§3.3) |
| `host_permissions`, `account_restrictions`, `app_admins` rows | deleted (cascade) |

Fix any FK that's missing an `on delete` rule by dropping and re-adding the constraint in the new migration. Check the connection-count trigger still leaves the **other** user's count correct after a cascade delete.

### 4.2 Edge Function `delete-account`

Deleting from `auth.users` and from Storage needs the service role, so this runs server-side in `supabase/functions/delete-account/index.ts`. Read the current Supabase Edge Functions docs first.

1. Accept only `POST` with the user's JWT. Get the user from the JWT (`auth.getUser()`); never take a user id from the request body.
2. Require the body `{ confirm: "<their username>" }` to match their username, as a last guard against accidents.
3. Delete their files in the avatars bucket **through the Storage API** (list the user's folder, then remove). Don't delete rows from `storage.objects` in SQL.
4. `auth.admin.deleteUser(user.id)`. The cascades do the rest.
5. Return `{ outcome: 'deleted' }`. Log failures without personal data.

The service role key comes from the function's built-in environment. Never put it in the app.

Deploying: give Zane the exact `npx supabase functions deploy delete-account` command and wait for his OK.

### 4.3 App

- Settings → **Account** → **Delete account**. It must be easy to find (Apple rejects deletion hidden behind support emails or many screens).
- Screen explains, in plain words, what gets deleted, what's kept (reports, anonymized), and that it can't be undone. The user types their username, then taps a red **Delete my account** button.
- Call the function with `supabase.functions.invoke('delete-account', ...)`, then sign out locally, clear cached state, and go to the welcome screen with "Your account was deleted."
- A suspended user can still delete their account.

**CHECKPOINT 4:** run test section **D (deletion cascade)**. Then, after Zane deploys the function, delete a throwaway account on a device and show the rows and avatar are gone. Commit.

---

## Phase 5: In-app legal surfaces

### 5.1 `src/lib/legal/config.ts`

```ts
// Placeholders: Zane fills these in. Every legal screen and draft reads from here.
export const LEGAL = {
  ENTITY_NAME: '{{LEGAL_ENTITY_NAME}}',       // e.g. "Bolas LLC" once formed
  CONTACT_EMAIL: '{{CONTACT_EMAIL}}',
  SUPPORT_EMAIL: '{{SUPPORT_EMAIL}}',
  PRIVACY_URL: '{{SITE}}/privacy',
  TERMS_URL: '{{SITE}}/terms',
  GUIDELINES_URL: '{{SITE}}/guidelines',
  SAFETY_URL: '{{SITE}}/safety',
  DELETE_ACCOUNT_URL: '{{SITE}}/delete-account',
  TERMS_VERSION: '2026-10-01',                // must match public._current_terms_version()
  MIN_AGE: 18,
} as const;
```

Add a dev-only warning (only in `__DEV__`) if any value still contains `{{`.

### 5.2 Sign-up (clickwrap)

- Add an **unchecked** checkbox: "I'm 18 or older and I agree to the **Terms** and **Privacy Policy**." The links open with `expo-web-browser`.
- The sign-up button stays disabled until it's checked. Don't pre-check it (that's a dark pattern and weakens enforceability).
- Pass `terms_version` and `age_confirmed` in `options.data` (Phase 2.3).

### 5.3 Consent gate for existing users and new terms versions

In the same place the app forces profile setup, add a check with `get_my_consent_status()`. If `needs_acceptance`, route to `app/legal/accept.tsx`: a short "We've updated our Terms" (or "Before you continue") screen, the same checkbox, and a button calling `accept_terms`. Include a "Delete my account instead" link, so nobody is trapped.

### 5.4 Settings

- **Legal:** Terms, Privacy Policy, Community Guidelines, Safety Tips (open the URLs), Open-source licenses (5.6), Contact support (`mailto:`).
- **Privacy & safety:** Blocked users (list from `get_my_blocked_users()`, with Unblock).
- **Account:** Delete account (Phase 4).
- Show the app version at the bottom.

### 5.5 Report and block entry points

- Public profile: a "⋯" menu with **Report** and **Block** (hidden on your own profile).
- Chat thread (if chat exists): report a message by long-pressing it, and block from the thread header.
- Match card from in-person connect: a small "Report" link, since this is where unsafe meetups surface (context `in_person`).
- Report sheet: the reason list, optional details, then "Thanks, we'll review this within 24 hours" and an offer to block.
- Block confirmation: "They won't be able to find your profile, message you, or connect with you. They won't be notified."

### 5.6 Open-source licenses

- Generate `src/lib/legal/licenses.json` from production dependencies with a script in `scripts/`. **Ask Zane before adding a dev dependency** for this (e.g. a license-checker package).
- A simple screen listing each package, its license, and the license text.

### 5.7 Suspended screen

If `account_restrictions` has a row for the user, show "Your account is suspended" with the contact email, links to the terms, and Delete account. Hide the tabs.

### 5.8 App store age signals (research first, then stop)

State App Store Accountability Acts expect apps to read the age range from the app store (Apple's Declared Age Range API, Google Play's Age Signals API). Before writing code:

1. Check the Expo SDK 57 docs and the Expo ecosystem for a supported module for each API, and whether it works in Expo Go or needs a development build.
2. Report to Zane: what exists, what it needs (dev build, Apple Developer account, entitlements), and a proposal: if the store says the user is under 18, block sign-up and show "Bolas is for adults 18+."

**Don't install anything for this until Zane decides** (open question 5).

**CHECKPOINT 5a:** sign-up checkbox, consent gate, Settings sections, licenses screen, working on a device.
**CHECKPOINT 5b:** report, block, blocked-users list, and suspended screen tested with two accounts. Commit after each.

---

## Phase 6: Policy drafts and web pages

### 6.1 Drafts (in this repo): `docs/legal/drafts/`

Write plain-English drafts, using **only** facts from `data-inventory.md` and placeholders from `config.ts`. Each starts with the DRAFT banner.

**`privacy-policy.md`** must cover: who we are (placeholder); what we collect and why (from the inventory); location specifics (only while tapping phones, precise location deleted within 10 minutes, only the city is kept; exact event locations shown only to the host and attendees); who can see what (profiles, connections, event attendance); service providers (Supabase, Expo/EAS, Apple, Google); **no selling, no ads, no tracking**; retention; account deletion and how to request it on the web; user rights (access, correction, deletion) and how to use them; 18+ only, and what we do if we learn a user is under 18 (delete the account); security (in general terms, no overpromising); changes to the policy; contact.

**`terms-of-service.md`** must cover: eligibility (18+, one account, accurate info); community guidelines with **no tolerance for objectionable content or abusive users**; what happens to reports (reviewed within 24 hours) and our right to remove content and suspend or delete accounts; the user's license to us to display content they post (limited to running the app); **in-person meetings** (Bolas doesn't screen or background-check users, meet in public places, users are responsible for their own safety, assumption of risk); events are organized by users, not Bolas; prohibited uses (selling, scams, spam, scraping, harassment); disclaimers, limitation of liability, indemnity; termination; dispute resolution and governing law as **placeholders for the lawyer** (don't pick arbitration or a state); copyright complaints contact (placeholder for the DMCA agent); app store terms (Apple and Google aren't parties and have no support obligations; include Apple's minimum EULA terms if Zane will upload a custom EULA; look up Apple's current list); changes to the terms; contact.

**`community-guidelines.md`:** short, friendly, concrete: be real, no selling or pitching strangers, no harassment or hate, no sexual content, meet safely, report and block.

**`safety-tips.md`:** meet in public places, tell a friend where you're going, arrange your own transport, don't share your home address or financial info, trust your instincts, how to report and block, call 911 in an emergency.

**`delete-account-page.md`:** for Google Play's web requirement: how to delete in the app (steps), and a way to request deletion without the app (email the support address from the account's email), what's deleted, what's kept, and the timeline.

### 6.2 Web pages (separate repo, separate session)

The landing page lives in `~/Code Apps/bolas-web` (its own repo, hosted on Cloudflare). **Don't touch that repo from this session.** Write `docs/legal/web-pages-handoff.md` with instructions for a Claude Code session opened in `bolas-web`:

- Add `/privacy`, `/terms`, `/guidelines`, `/safety`, `/delete-account` from the reviewed drafts, with a "Last updated" date.
- Footer on every page: legal entity name, contact email, links to all legal pages.
- Check the landing page copy for unsupported claims (user numbers, testimonials, "safest", "#1"), and list anything that isn't true yet.
- Cookies: list any scripts that set cookies or track visitors. If only cookieless analytics (or none) are used, no banner is needed; write that down. If tracking cookies exist, stop and ask.
- Nothing goes live until Zane says the drafts have been reviewed.

**CHECKPOINT 6:** Zane reads the drafts. Commit.

---

## Phase 7: Accessibility, permissions, store prep

### 7.1 Accessibility pass

- Every icon-only button, avatar, and map marker gets `accessibilityLabel` and `accessibilityRole`. Decorative images get `accessible={false}`.
- **Contrast:** write a small script that reads the theme color tokens and prints the contrast ratio of each text/background pair in light and dark mode. Flag anything under 4.5:1 (normal text) or 3:1 (large text and UI parts). Propose fixes; Zane picks.
- Respect Reduce Motion (`AccessibilityInfo.isReduceMotionEnabled`) for the match-card and map animations.
- Check that large Dynamic Type sizes don't break the sign-up, report, and delete screens.
- Tap targets at least 44×44 pt.

### 7.2 Permissions and privacy manifest

- Compare the Phase 0 permission list to what the app uses. Remove anything unused (e.g. block `RECORD_AUDIO` on Android if camera added it; confirm there's no background location).
- Permission strings must match the inventory and be specific.
- Add or update the iOS privacy manifest through app config, following the Expo SDK 57 docs on privacy manifests. Declare required-reason APIs used by the app and its libraries. Note: this needs a new build.

### 7.3 `docs/legal/store-submission.md`

Draft, for Zane to paste into App Store Connect and Play Console:
- privacy label and Data Safety answers (from Phase 1)
- age rating questionnaire answers, aiming for 18+ (user-generated content, messaging, meeting strangers, location)
- privacy policy URL, support URL, account deletion URL
- **App Review notes:** a demo account placeholder, and how the reviewer can find report, block, delete account, and the terms (Apple checks these for social apps)

### 7.4 Emails

- List the Supabase auth email templates. Draft Bolas-branded versions that name the app and include the support contact.
- Confirm the app sends no marketing emails. Add a note in the status doc: any future newsletter needs an unsubscribe link, a mailing address, and consent.

**CHECKPOINT 7:** show the contrast report, the permission diff, and the store-submission draft. Commit.

---

## Phase 8: Docs

- `docs/legal-compliance-for-web.md` for the partner: blocking rules the web must respect (it gets them for free through RLS, but web-only queries and views must be checked), `report_user`, account deletion (the web should link to or call the same Edge Function), the consent gate (web sign-up must pass `terms_version` and `age_confirmed`, and respect `get_my_consent_status`), the profile content filter errors, and suspended accounts.
- `docs/legal-compliance-status.md` in the same format as the other status docs: what's built, what's tested, every placeholder still unfilled, the tuning knobs (report rate limit, blocked terms), and Zane's non-code checklist below with checkboxes.

---

## Testing

### DB tests: `supabase/tests/legal_compliance.sql` (rolls back)

Simulate users with `set local role authenticated; set local request.jwt.claims = '{"sub":"<uuid>"}';`.

**A. Consent**
- Sign-up metadata with the current version and `age_confirmed` → all three columns set with server time.
- Sign-up without `age_confirmed` → columns null, and `get_my_consent_status` says `needs_acceptance`.
- `accept_terms` with an old version → `stale_version`; without age → `age_required`; correct → `accepted`.
- A direct `update profiles set terms_accepted_at = ...` as the user fails. A normal profile edit (bio) still works.

**B. Blocking**
- After A blocks B: B can't select A's profile and A can't select B's; neither can send a connection request or message; any connection between them is gone.
- `_connect_in_person` / QR redeem / bump between them → `unavailable`.
- Events and attendance hidden both ways (if event safety is built).
- A sees B in `get_my_blocked_users`; B can't see the block row.
- Unblock restores visibility but not the connection.

**C. Reports and admin**
- Can't report yourself; can't report a message you're not part of; the 11th report in a day → `rate_limited`.
- The snapshot is built by the server and matches the profile/message at report time.
- A non-admin calling any admin RPC → 42501.
- Suspending a user hides them from others and blocks their writes; they can still read their own restriction. Lifting restores them.

**D. Deletion cascade** (as `postgres`, inside the rolled-back transaction)
- Create a user with a profile, connections at both levels, a pending request, a block each way, an event with RSVPs, a message, a filed report, and a received report.
- `delete from auth.users where id = ...` → no rows left anywhere referencing that id, except the two reports with the id set to null. The other user's connection count is correct.

**E. Content filter**
- A username, full name, or bio containing a blocked term is rejected; `fo_rex99` style evasions of a username are caught; normal text passes.

### Manual QA (two accounts, at least one on a real phone)

| # | Scenario | Expected |
|---|---|---|
| 1 | New sign-up without checking the box | Button disabled |
| 2 | Existing account opens the updated app | Consent screen once, then normal |
| 3 | Report a profile, then block | Thanks message; blocked user disappears everywhere |
| 4 | Blocked user tries the old profile link / QR | Generic "not available" |
| 5 | Admin suspends a user | They see the suspended screen; others can't find them |
| 6 | Delete account from Settings | Signed out; sign-in fails; avatar URL 404s; other user's list updates |
| 7 | Legal links in Settings and sign-up | Open the right pages |
| 8 | VoiceOver / TalkBack on sign-up, profile, report | Every control is announced sensibly |
| 9 | Largest text size | Key screens still usable |
| 10 | Web app sign-up and profile | Still works (or the partner has the doc) |

---

## Zane's non-code checklist (Claude Code: list these in the final summary, don't do them)

- [ ] **Form an LLC** with the partner, and sign an operating agreement that covers ownership split, what happens if someone leaves, and **assignment of the code and brand to the company** (the repo is in the partner's account today).
- [ ] Get a business email and a mailing address that isn't a home address (a virtual mailbox works). Fill in the `config.ts` placeholders.
- [ ] Have a lawyer review the terms and privacy policy before launch (a university entrepreneurship or law clinic may do this free for students). Decide governing law and dispute resolution with them.
- [ ] Register a DMCA designated agent with the U.S. Copyright Office, so user-uploaded photos don't expose the company to copyright liability.
- [ ] Decide launch countries. **U.S. only** at first keeps you out of GDPR until you're ready.
- [ ] Fill in App Store Connect and Play Console privacy forms, the age rating (18+), URLs, and review notes from `store-submission.md`.
- [ ] Before hosting any official Bolas-run events, ask about general liability insurance.
- [ ] Know your duties if you ever see child sexual abuse material or evidence a user is a minor: remove it, preserve it, and report it (NCMEC for CSAM). Ask the lawyer to explain the process.
- [ ] Re-check the state app store age laws before launch; their status keeps changing.

## Open questions for Zane (ask when they come up, don't decide alone)

1. Launch countries (U.S. only?), since it changes what the privacy policy must say.
2. When a user deletes their account, delete their chat messages, or keep them for the other person as "Deleted user"? (Default: delete.)
3. Should blocking also remove the blocked user's RSVP from the blocker's events?
4. Should suspension also ban the account at the auth level (can't sign in at all)?
5. App store age signals: add now (may need a development build and the Apple Developer account) or right before launch?
6. Wording of the report reasons and the "reviewed within 24 hours" promise. Only promise what you and your partner can actually do.

## Definition of done

- [ ] New users must check an unchecked 18+ and terms box; acceptance and version are stored with server time and can't be faked from the client. Existing users are gated once.
- [ ] Report (profile, message, in-person) and block work everywhere, blocks are invisible to the blocked user, and admins can review, dismiss, and suspend.
- [ ] Profile text is filtered against the blocked-terms list.
- [ ] Account deletion from Settings removes the user, their files, and their data, keeping only anonymized reports.
- [ ] `data-inventory.md` matches the code, and the policy drafts and store answers match the inventory.
- [ ] Settings has Legal, Blocked users, Delete account, and Open-source licenses.
- [ ] Unused permissions removed, privacy manifest in place, contrast report done, key screens labeled for screen readers.
- [ ] All DB tests pass on the linked project (rolled back). No TypeScript errors, lint passes.
- [ ] Web handoff, partner doc, and status doc written. One commit per phase on `feature/legal-compliance`, not pushed until Zane says so.
