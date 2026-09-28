# Bolas: Safer Map Events: Build Plan for Claude Code

> **How to use this file:** it lives in the repo at `docs/plans/event-safety.md`. Tell Claude Code:
> *"Read docs/plans/event-safety.md and start Phase 0. Stop at each checkpoint."*

---

## 0. Read this first (instructions for Claude Code)

**Who you're working with.** Zane builds the Bolas mobile app (Expo) and learns by doing. For every phase:

1. Before changing anything, explain in plain language **what** you're about to do and **why**.
2. Work in small, reviewable steps.
3. At each **CHECKPOINT**, stop. Summarize what changed and give Zane exact steps to test it. Wait for his OK.

**Repo rules (from AGENTS.md):** read the **Expo SDK 57 versioned docs** before writing code that uses any Expo or map package (`react-native-maps` `Circle`, Expo Router). Use the official Expo plugin.

**Git:** branch off `mobile-app` as `feature/event-safety`. Commit at the end of each phase. Don't push, open PRs, or merge without asking.

**Supabase:**

- New migrations only in `supabase/migrations`. Never edit old ones.
- This project tests against the **linked (live) project**. Don't run `db push` without Zane's explicit OK.
- DB tests go in `supabase/tests/event_safety.sql`, written like `in_person_connections.sql`: everything in a transaction that **rolls back**, run with
  `npx supabase db query --linked -f supabase/tests/event_safety.sql`.
- **Grants rule:** every new table gets these grants, with RLS enabled:

  ```sql
  grant select on public.your_table to anon;
  grant select, insert, update, delete on public.your_table to authenticated;
  grant select, insert, update, delete on public.your_table to service_role;
  ```

  A table with RLS on and **no policies** can't be reached by clients. That's intended for the internal tables below.
- Every `SECURITY DEFINER` function sets `search_path = public`. Revoke execute from `public` and `anon`, then grant it to `authenticated` only if clients should call it. Private helpers start with `_` and aren't granted.

---

## 1. What we're changing and why

Right now anyone can post a **public** event (and public is the default), drop an **exact** pin anywhere (including a house), change the event's location or time after people RSVP, and read **who is going** to any public event. There are no reports and no admin tools.

Decisions Zane made:

| Area | Decision |
|---|---|
| **Who posts public events** | **Earned trust.** Not suspended, **and** either approved by an admin, **or** account 7+ days old **with** 3+ in-person connections. Anyone with a finished profile can still post **connections-only** events. |
| **Location** | **Approximate until you RSVP.** The map shows a fuzzy circle (~400 m). The exact pin and place name unlock for the host, people who tapped Going, and admins. |
| **Attendee list** | Everyone sees the **count**. The **host** sees the full list. Everyone else sees only **their own connections** who are going. |
| **Moderation** | A **Report** button. An event is **auto-hidden after 3 reports**. Zane and his partner are **admins**: they can restore or remove events and suspend or approve hosts. |

**Core security rule:** clients never write to `events` directly. All inserts and updates go through `SECURITY DEFINER` RPCs that enforce the rules. Deleting your own event stays a plain delete.

### Tunable rules (one place)

Put every number in a single SQL helper `public._event_rules()` that returns jsonb, so a change is one line:

| Rule | Start value |
|---|---|
| `min_account_age_days` (public hosting) | 7 |
| `min_in_person_connections` (public hosting) | 3 |
| `max_active_events` per host (not yet ended, not removed) | 3 |
| `max_creates_per_day` | 5 |
| `max_days_ahead` for `starts_at` | 90 |
| `max_duration_hours` | 24 |
| `fuzz_min_m` / `fuzz_max_m` | 150 / 350 |
| `circle_radius_m` (the app draws this) | 400 |
| `auto_hide_reports` | 3 |
| `reporter_min_account_age_days` (for a report to count toward auto-hide) | 3 |
| `max_reports_per_day` per user | 10 |
| `max_rsvps_per_day` per user | 30 |

Admins skip the hosting and rate limits.

---

## Phase 0: Discovery (no code changes)

1. Read `AGENTS.md`, `CLAUDE.md`, `docs/in-person-connections-status.md`, and the events code: `supabase/migrations/20260922000000_create_events.sql`, `src/lib/events.ts`, `src/lib/types.ts` (`EventSummary`), `src/components/event-form.tsx`, `src/components/event-marker.tsx`, `src/app/event/new.tsx`, `src/app/event/[id]/index.tsx`, `src/app/event/[id]/edit.tsx`, and the event parts of `src/app/(app)/map.tsx`.
2. Confirm facts this plan relies on:
   - `connections` has `requester_id`, `addressee_id`, `status` (`'pending' | 'accepted'`), and `level` (`'acquaintance' | 'in_person'`).
   - `profiles.created_at` exists.
   - `public.handle_updated_at()` exists.
   - There's no blocks table and no admin concept yet.
3. Find **everything** that depends on `events.latitude`, `events.longitude`, `events.location_name`, or the `event_summaries` view, including the Web Map code and `docs/in-person-connections-for-web.md`. Also ask Zane whether the partner's web app reads events.
4. Count the existing events on the live DB (read-only `select count(*)`), so the backfill in Phase 2 is sized correctly.
5. Run `git status`. If there's uncommitted work, **stop and ask**.

**Output:** a short "Current state" note, including anything that conflicts with this plan.

**CHECKPOINT 0:** Zane OKs it. Create the branch.

---

## Phase 1: DB: admins, hosting trust, RPC-only writes

**Migration:** `<ts>_event_trust.sql`

### 1.1 Admins

```sql
create table public.app_admins (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;   -- no policies: unreachable from clients
-- + the 3 standard grants

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid());
$$;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;
```

Admins are added by hand in the Supabase SQL editor, never from the app. Put the insert in the checkpoint notes for Zane, with placeholder UUIDs he fills in:
`insert into app_admins (user_id) values ('<zane uuid>'), ('<partner uuid>');`

### 1.2 Host permissions

```sql
create table public.host_permissions (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  status     text not null check (status in ('approved', 'suspended')),
  note       text check (char_length(note) <= 300),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null
);
alter table public.host_permissions enable row level security;
create policy "Users can see their own host status"
  on public.host_permissions for select to authenticated using (user_id = auth.uid());
-- no insert/update/delete policies: only admin RPCs write here
-- + the 3 standard grants
```

### 1.3 `_event_rules()` and `_hosting_status(uid)`

- `_event_rules()`: `immutable`, returns the jsonb from the table above.
- `_hosting_status(p_uid uuid) returns jsonb`: security definer, **not granted**. It returns:

```json
{ "can_host": true, "can_host_public": false, "reason": "needs_in_person",
  "account_age_days": 9, "in_person_count": 1, "needed_in_person": 3, "needed_age_days": 7,
  "active_events": 1, "max_active_events": 3, "is_admin": false }
```

Logic:

- `can_host` requires a username to be set and no `suspended` row.
- `can_host_public` requires `can_host` **and** (admin **or** `approved` **or** (age ≥ min **and** accepted `in_person` connections ≥ min)).
- `reason` is one of `null | 'suspended' | 'no_profile' | 'new_account' | 'needs_in_person'`. When both age and connections are short, `new_account` wins.

Public wrapper: `get_my_hosting_status()` returns `_hosting_status(auth.uid())`. Grant it to `authenticated`.

### 1.4 New columns on `events`

```sql
alter table public.events
  add column status text not null default 'active'
    check (status in ('active', 'hidden', 'removed')),
  add column time_changed_at timestamptz;   -- set when an update moves starts_at/ends_at
create index events_status_idx on public.events (status);
```

- `active`: shown normally.
- `hidden`: auto-hidden by reports and waiting for an admin.
- `removed`: taken down by an admin.

### 1.5 Lock down direct writes

- **Drop** the insert policy `"Users can create their own events"` and the update policy `"Creators can update their events"`. With no insert or update policy, clients can't write, and the definer RPCs still can.
- **Keep** the delete policy (creators delete their own). **Add** an admin delete policy: `using (public.is_admin())`.
- **Replace** the select policy:

```sql
using (
  public.is_admin()
  or creator_id = auth.uid()                           -- hosts always see their own, even hidden/removed
  or (status = 'active' and (visibility = 'public' or public.is_connected_to(creator_id)))
)
```

### 1.6 `create_event(...)` → jsonb

Arguments: `p_title, p_description, p_location_name, p_latitude, p_longitude, p_starts_at, p_ends_at, p_visibility`.

1. Require `auth.uid()`. `v_status := _hosting_status(uid)`. If not `can_host`, return `{outcome: 'not_allowed', reason}`.
2. If `p_visibility = 'public'` and not `can_host_public`, return `{outcome: 'public_locked', ...hosting status}`.
3. Validate on the server (the same rules the form checks, and now the real guard):
   - title 1–60 characters after trim, description ≤ 500, location name ≤ 100
   - coordinates in range
   - `starts_at` between `now() - 5 min` and `now() + max_days_ahead`
   - `ends_at` null, or after `starts_at` and ≤ `starts_at + max_duration_hours`

   On failure, return `{outcome: 'invalid', field}`.
4. **Content check:** normalize the title and description (lowercase) and reject if they contain any phrase from `public.event_blocked_terms` (see 1.8). Return `{outcome: 'blocked_content'}`.
5. **Rate limits** (skipped for admins):
   - active events ≥ `max_active_events` → `{outcome: 'too_many_active'}`
   - events created in the last 24 h ≥ `max_creates_per_day` → `{outcome: 'rate_limited'}`

   Count removed events too, so deleting and recreating doesn't get around the limit.
6. Insert the event row (plus the location row, see Phase 2). The existing `handle_new_event` trigger adds the host as attending.
7. Return `{outcome: 'created', event_id}`.

### 1.7 `update_event(p_event_id, p_title, p_description, p_starts_at, p_ends_at, p_visibility)` → jsonb

- Caller must be the creator, and the event must not be `removed`.
- **Location can never change.** It's not an argument. (The app already says to delete and re-pin.)
- Same validation and content check as create. `starts_at` may be in the past only if it's unchanged.
- Visibility: going `connections` → `public` requires `can_host_public`. Going to `connections` is always allowed.
- If `starts_at` or `ends_at` changed, set `time_changed_at = now()`.
- Return `{outcome: 'updated'}` or an error outcome as above.

### 1.8 Blocked terms (a speed bump, not a wall)

```sql
create table public.event_blocked_terms (term text primary key check (term = lower(term)));
alter table public.event_blocked_terms enable row level security;   -- no policies
-- + the 3 standard grants
insert into public.event_blocked_terms (term) values
  ('passive income'), ('dm me'), ('cash app'), ('cashapp'), ('venmo me'),
  ('crypto signals'), ('forex'), ('make money fast'), ('mlm'), ('onlyfans');
```

Admins manage the list in the SQL editor. Keep the list short: reports are the main defense.

**CHECKPOINT 1:** write test sections **A (trust)** and **B (write lock)** (see Testing) and run them. Show Zane:

- a direct `insert into events` as a user **fails**
- a 1-day-old account gets `public_locked` for a public event but can create a connections-only one

Commit.

---

## Phase 2: DB: approximate location until RSVP

**Migration:** `<ts>_event_approx_location.sql`

### 2.1 Split exact from approximate

```sql
create table public.event_locations (
  event_id      uuid primary key references public.events (id) on delete cascade,
  latitude      double precision not null check (latitude between -90 and 90),
  longitude     double precision not null check (longitude between -180 and 180),
  location_name text check (char_length(location_name) <= 100)
);
alter table public.event_locations enable row level security;
-- + the 3 standard grants

-- Exact spot: host, admins, and people who are going. No recursion: the
-- events and event_attendees policies never read event_locations.
create policy "Exact location for host, admins and attendees"
  on public.event_locations for select to authenticated
  using (
    public.is_admin()
    or exists (select 1 from public.events e where e.id = event_locations.event_id and e.creator_id = auth.uid())
    or exists (select 1 from public.event_attendees a where a.event_id = event_locations.event_id and a.user_id = auth.uid())
  );
-- no insert/update/delete policies: only create_event writes
```

On `events`: add `approx_latitude` and `approx_longitude` (not null after backfill), and an index on `(approx_latitude, approx_longitude)`.

### 2.2 Fuzzing (`_fuzz_point(lat, lng) returns table(lat, lng)`)

A random bearing plus a random distance between `fuzz_min_m` and `fuzz_max_m`:

```sql
-- b = random() * 2π, d = fuzz_min + random() * (fuzz_max - fuzz_min)
-- dlat = d * cos(b) / 111320
-- dlng = d * sin(b) / (111320 * cos(radians(lat)))
```

- It runs **once**, when the event is created, and the result is stored. Because the location can never change, nobody can re-fuzz an event and average the results to find the real spot.
- The circle the app draws (400 m) is larger than the maximum offset (350 m), so the real spot is always inside it.

### 2.3 Backfill and cleanup (same migration, in this order)

1. Drop the `event_summaries` view, since it depends on the old columns.
2. Copy `latitude`, `longitude`, and `location_name` from every event into `event_locations`.
3. Fill `approx_*` with `_fuzz_point` for every existing event. Set `approx_*` to not null.
4. Drop `events.latitude`, `events.longitude`, `events.location_name`, and the old `events_lat_lng_idx`.
5. Update `create_event` to insert the `event_locations` row and the fuzzed `approx_*` values.

### 2.4 Rebuild `event_summaries` (still `security_invoker = true`)

It has the same columns as before, **except**:

| Old | New |
|---|---|
| `latitude`, `longitude` | `approx_latitude`, `approx_longitude` (always present) |
| `location_name` | `location_name` from `event_locations`: **null unless you can see the exact spot** |
| n/a | `exact_latitude`, `exact_longitude` (left join on `event_locations`, so RLS turns them into nulls) |
| n/a | `status`, `time_changed_at` |
| `attendee_count` (subquery) | `going_count` (column, see Phase 3) |

Keep `effective_ends_at`, the creator fields, and `is_going`. Keep `revoke all ... from anon`.

**CHECKPOINT 2:** run test section **C (location)**. Commit.

---

## Phase 3: DB: attendee privacy

**Migration:** `<ts>_event_attendee_privacy.sql`

### 3.1 A counter instead of a count query

Once attendee rows are private, a `count(*)` run by the viewer would only count the rows they can see. So store the count:

- Add `events.going_count integer not null default 0` and backfill it from `event_attendees`.
- Add a `SECURITY DEFINER` trigger on `event_attendees` (after insert/delete) that adds or subtracts 1 on the event's `going_count`. It isn't granted to clients.

### 3.2 Replace the attendee select policy

```sql
drop policy "Users can view attendees of visible events" on public.event_attendees;
create policy "Attendees visible to self, host, admins, and your connections"
  on public.event_attendees for select to authenticated
  using (
    user_id = auth.uid()
    or public.is_admin()
    or (
      exists (select 1 from public.events e where e.id = event_attendees.event_id)   -- still must be a visible event
      and (
        exists (select 1 from public.events e where e.id = event_attendees.event_id and e.creator_id = auth.uid())
        or public.is_connected_to(user_id)
      )
    )
  );
```

`is_connected_to` counts **both** levels (acquaintance and in-person). See open question 1.

### 3.3 RSVP rules

Replace the RSVP insert policy's check with: the event is visible **and** `status = 'active'` **and** it hasn't ended (`coalesce(ends_at, starts_at + interval '3 hours') > now()`).

Add a `before insert` trigger that enforces `max_rsvps_per_day`. This stops a scraper from tapping Going on every event just to collect exact locations. Admins are exempt.

### 3.4 Helper for the detail screen

`get_event_attendees(p_event_id uuid)` → a table of `(user_id, username, full_name, avatar_url, is_connection boolean)`. It's a plain SQL function, **not** security definer, so the new RLS decides who's returned. The host gets everyone; others get themselves plus their connections.

**CHECKPOINT 3:** run test section **D (attendees)**. Commit.

---

## Phase 4: DB: reports, auto-hide, admin RPCs

**Migration:** `<ts>_event_reports.sql`

```sql
create table public.event_reports (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events (id) on delete cascade,
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reason      text not null check (reason in ('spam', 'selling_or_scam', 'unsafe_location', 'harassment', 'inappropriate', 'fake', 'other')),
  details     text check (char_length(details) <= 500),
  status      text not null default 'open' check (status in ('open', 'dismissed', 'actioned')),
  created_at  timestamptz not null default now(),
  unique (event_id, reporter_id)
);
alter table public.event_reports enable row level security;   -- no policies; RPCs only
-- + the 3 standard grants
```

### 4.1 `report_event(p_event_id, p_reason, p_details)` → jsonb

1. Require auth. The caller must be able to **see** the event: check with the same rule as the events select policy, because definer functions skip RLS. You can't report your own event (`self`).
2. Rate limit: `max_reports_per_day`, then return `rate_limited`.
3. Insert. If the caller already reported this event, return `already_reported`.
4. Count **open** reports on this event from reporters whose accounts are at least `reporter_min_account_age_days` old. If the count is ≥ `auto_hide_reports` and the event is `active`, set `status = 'hidden'`.
5. Return `{outcome: 'reported', hidden: bool}`. Always tell the reporter "Thanks, we'll take a look," whether or not it was hidden.

### 4.2 Admin RPCs (each starts with `if not is_admin() then raise ... errcode '42501'`)

| RPC | What it does |
|---|---|
| `admin_list_flagged_events()` | Events that are `hidden` **or** have open reports. Returns the event, host, exact location, report counts by reason, and the latest report details. Newest first. |
| `admin_set_event_status(p_event_id, p_status, p_note)` | Sets `active` or `removed`. Restoring (`active`) marks that event's open reports `dismissed`. Removing marks them `actioned`. |
| `admin_set_host_status(p_user_id, p_status, p_note)` | Sets `approved`, `suspended`, or clears the row (`p_status = null`). Suspending also sets the user's upcoming `active` events to `removed`. |
| `admin_find_user(p_username)` | Looks up a user by username so an admin can approve or suspend them. |

**CHECKPOINT 4:** run test section **E (reports/admin)**. Commit.

---

## Phase 5: Mobile app

### 5.1 `src/lib/events.ts`, `src/lib/types.ts`

- Update `EventSummary` to the new view columns (Phase 2.4). Regenerate the Supabase types if the project generates them.
- `createEvent` / `updateEvent` call the RPCs. Map every `outcome` to a TypeScript union with friendly messages in one place:
  - `public_locked` → "Public events unlock after you've met 3 people in person."
  - `too_many_active` → "You can have up to 3 upcoming events."
  - `blocked_content` → "Something in your title or description isn't allowed. Selling and money-making pitches aren't allowed."
  - `rate_limited` → "Slow down a sec and try again later."
- `fetchEventsInRegion` filters on `approx_latitude` / `approx_longitude`.
- Add `getMyHostingStatus()`, `getEventAttendees(id)`, `reportEvent(...)`, and the admin wrappers.
- Keep the client validation (it gives fast feedback), but the server is the real guard.

### 5.2 Create/edit form (`event-form.tsx`, `event/new.tsx`)

- **Default visibility is `connections`.**
- Load `getMyHostingStatus()`. If `can_host_public` is false, show the Public option **locked** with a progress hint, for example: "🔒 Public events unlock when you've met 3 people in person (1/3)", or "…your account is 7 days old (2 days to go)". The hint links to the Connect screen.
- If `can_host` is false because the account is suspended, don't open the form. Show "Hosting is paused on your account." instead.
- Change the location hint to: "Pick a public place like a café, library, or coworking space. People see the general area until they tap Going."

### 5.3 Map (`(app)/map.tsx`, `event-marker.tsx`)

- An event **you can see exactly** (you're the host or you're going) → the current calendar-tile pin, at `exact_*`.
- Any other event → a `Circle` (radius `circle_radius_m`, soft accent fill) at `approx_*`, plus the calendar tile at the circle's **center**, with no pointer tail, so it doesn't look like an exact spot.
- Keep the performance tricks already in `event-marker.tsx` (`tracksViewChanges` off after the first paint).

### 5.4 Event detail (`event/[id]/index.tsx`)

- **Location section:**
  - Not going → "📍 Exact spot shows when you tap Going", plus a small static map of the circle.
  - Going or host → the place name, the exact pin, and an "Open in Maps" button.
- **Who's going:**
  - Always show the count (`going_count`).
  - Non-host → "*N of your connections are going*" with their avatars, from `getEventAttendees`.
  - Host → the full list, with a small "You're the host: only you can see everyone" note.
- `time_changed_at` set → a "🕒 Time changed" badge near the time.
- **Report** in a "⋯" menu (not shown on your own event). It opens a sheet with the reasons plus optional details, and afterwards shows a "Thanks, we'll take a look" toast.
- **Host view of a `hidden` or `removed` event:** a banner reading "This event is under review and isn't visible to others" (hidden) or "This event was removed" (removed). Editing is disabled when it's removed.

### 5.5 Admin screen

- Route `app/admin/index.tsx`. The entry row sits in Settings and appears only when `is_admin()` returns true. Also guard the route itself, so a regular user who deep-links there sees nothing.
- **Tabs:**
  - **Flagged events:** a list from `admin_list_flagged_events` with **Restore** and **Remove** buttons.
  - **Hosts:** search by username, then **Approve**, **Suspend**, or **Clear**.
- Keep it plain. It's an internal tool.

### 5.6 Error handling

Use the same patterns as the Connect feature: RPC timeouts, a friendly offline message, and raw errors logged only in `__DEV__`.

**CHECKPOINT 5a:** create, edit, and hosting status work on a device (new account locked, trusted account unlocked).
**CHECKPOINT 5b:** map circles, the exact location unlocking on Going, the attendee list, report, and the admin screen, tested with two accounts. Commit after each.

---

## Phase 6: Docs

- Update `docs/in-person-connections-for-web.md`, or write `docs/event-safety-for-web.md`, for the partner. Cover:
  - the web **can't** insert or update `events` directly anymore; use `create_event` / `update_event`
  - the new view columns (`approx_*`, `exact_*` nullable, `going_count`, `status`)
  - the attendee privacy rule
  - `report_event`
- Add `docs/event-safety-status.md` in the same format as the in-person status doc: what's built, what's tested, and the tuning knobs (`_event_rules()`).

---

## Testing

### DB tests: `supabase/tests/event_safety.sql` (rolls back)

Create test users with controlled `profiles.created_at` and in-person connections, and simulate them with `set local role authenticated; set local request.jwt.claims = '{"sub":"<uuid>"}';`.

**A. Trust**

- A new account (1 day old, 0 in-person) → `create_event` public = `public_locked`, connections = `created`.
- 8 days old + 3 in-person → public `created`.
- 8 days old + 3 **acquaintances** only → `public_locked`.
- `approved` host (1 day old) → public `created`.
- `suspended` → `not_allowed` for both kinds.
- The admin skips the limits.
- `get_my_hosting_status` returns the right `reason` and progress numbers.

**B. Write lock and validation**

- Direct `insert` / `update` on `events` as a user fails.
- Start time 1 hour ago, or 100 days out, → `invalid`. A 30-hour duration → `invalid`.
- The 4th active event → `too_many_active`. The 6th create in 24 h → `rate_limited`.
- A blocked term → `blocked_content`.
- `update_event` by a non-creator fails. Changing the time sets `time_changed_at`. Switching connections → public by an untrusted host fails.

**C. Location**

- A non-attendee sees `approx_*` but `exact_*` and `location_name` are null. Reading `event_locations` directly returns nothing.
- After RSVP → exact values are visible. After un-RSVP → hidden again.
- The host and admin always see exact values.
- The distance from approx to exact is between 150 and 350 m for every event, including the backfilled ones.

**D. Attendees**

- A stranger sees the correct `going_count` but no attendee rows except their own.
- A connection of an attendee sees that attendee. The host sees everyone.
- RSVP to a hidden, removed, or ended event fails. The 31st RSVP in a day fails.
- `going_count` stays correct through RSVP, un-RSVP, and event deletion.

**E. Reports and admin**

- You can't report your own event, an event you can't see, or the same event twice.
- 3 reports from accounts 3+ days old → `hidden`. 3 reports where one comes from a 1-day-old account → still `active`.
- A hidden event is invisible to others but visible to its host.
- A non-admin calling an admin RPC → error 42501.
- Restore → `active` and the reports are dismissed. Suspend a host → their upcoming events are removed and they get `not_allowed`.

### Manual QA (two accounts, at least one on a real phone)

| # | Scenario | Expected |
|---|---|---|
| 1 | New account opens Create event | Defaults to Connections only; Public is locked with progress |
| 2 | Trusted account creates a public event | Shows as a circle for others, a pin for the host |
| 3 | Other account taps Going | Exact pin, place name, and Open in Maps appear |
| 4 | Host opens the event | Full attendee list; others see only their connections |
| 5 | Report from 3 accounts | Event disappears for others; host sees the "under review" banner |
| 6 | Admin restores it | Visible again |
| 7 | Admin suspends the host | Their events vanish; the host sees "Hosting is paused" |
| 8 | Host changes the time | "Time changed" badge |
| 9 | Web app | Still loads events (or the partner has been told what changed) |

---

## Later / out of scope (list it, don't build it)

- **Blocking users.** There's no blocks table yet. When one exists, blocked users shouldn't see each other's events or attendance.
- **Event check-in with the rotating QR.** The host shows a code and attendees scan it. Check-ins would build host reputation ("hosted 4 events · 37 check-ins") and could replace or add to the in-person rule for public hosting.
- Capacity, a waitlist, and "host approves RSVPs" for small events.
- Push notifications when an event you're going to changes time or is removed.
- Filters on the map (interest, business stage, "Tonight" / "This week") and event types (coffee, coworking, pitch night, workshop).
- Venue search (Google/Mapbox Places) instead of free pins.
- "Featured" events added by the team, to seed the map at launch.

## Open questions for Zane (ask when they come up, don't decide alone)

1. Should **acquaintances** count for connections-only events and for "your connections going", or only in-person connections? (Current plan: both levels, which matches how `is_connected_to` works today.)
2. Final wording for the locked-Public hint and the report reasons.
3. Should an admin get a push or email when an event is auto-hidden? (Not built. For now admins check the admin screen.)

## Definition of done

- [ ] Clients can't insert or update `events` except through `create_event` / `update_event`.
- [ ] Public events require earned trust, approval, or admin. Everyone else gets connections-only.
- [ ] Only the host, attendees, and admins can read exact locations and place names, in both the API and the app.
- [ ] Attendee rows are visible only to yourself, the host, admins, and your connections, and `going_count` is correct.
- [ ] Reports auto-hide at 3, and the admin screen can restore, remove, approve, and suspend.
- [ ] All DB tests pass on the linked project (rolled back). No TypeScript errors.
- [ ] Web partner doc and status doc written. One commit per phase on `feature/event-safety`, not pushed until Zane says so.
