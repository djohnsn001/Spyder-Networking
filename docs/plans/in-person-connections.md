# Bolas: In-Person Connections (Tap + QR): Build Plan for Claude Code

> **How to use this file:** Save it in the repo at `docs/plans/in-person-connections.md`, then tell Claude Code:
> *"Read docs/plans/in-person-connections.md and start Phase 0. Stop at each checkpoint."*

---

## 0. Read this first (instructions for Claude Code)

**Who you're working with.** Zane is building the Bolas mobile app (Expo) and learns by doing. For every phase:

1. Before changing anything, explain in plain language **what** you're about to do and **why**.
2. Do the work in small, reviewable steps.
3. At each **CHECKPOINT**, stop. Summarize what changed and give Zane the exact steps to test it. Wait for his OK before moving on.

**Repo rules (from AGENTS.md):**

- Read the **Expo SDK 57 versioned docs** before writing code that uses any Expo package: `expo-camera`, `expo-location`, `expo-sensors`, `expo-haptics`, and Expo Router. Don't rely on memory of older SDKs. APIs change.
- The official Expo plugin for Claude Code is enabled. Use it.

**Git:**

- Branch off `mobile-app` (the default branch). Name the branch `feature/in-person-connections`.
- Commit at the end of every phase with a clear message.
- Don't push, open PRs, or merge without asking Zane.

**Supabase:**

- The schema lives in `supabase/migrations`.
- Write new migrations only. Never edit old ones.
- Don't apply migrations to the **hosted/production** Supabase project (for example with `supabase db push`) without Zane's explicit OK. Figure out whether a local Supabase stack is used (`supabase start`) and prefer testing there.
- **Grants rule:** every new table gets explicit grants (Zane's standing rule; it becomes mandatory after Oct 30, 2026):

  ```sql
  grant select on public.your_table to anon;
  grant select, insert, update, delete on public.your_table to authenticated;
  grant select, insert, update, delete on public.your_table to service_role;
  ```

  RLS stays **enabled** on those tables. A table with RLS on and no policies is unreachable from the client even with these grants. That's what we want for the internal tables below.

**Names in this plan are placeholders.** The SQL below is a *reference implementation*. The real `connections` table may use different column names, for example `requester_id` / `addressee_id` / `status` versus `user_a` / `user_b`. Phase 0 finds the real names, and every snippet must be adapted to them.

---

## 1. What we're building (product summary)

Bolas gets **two levels of connection**:

| Level | DB value | UI label (working name) | How you get it |
|---|---|---|---|
| Lower | `acquaintance` | "Acquaintance" | The existing remote flow: send request → pending → accepted. Works from Discover, profiles, anywhere. |
| Higher | `in_person` | "Map connection" (**final name TBD**) | **Only** by meeting in person: tapping phones (**Bump**) or scanning a rotating **QR code**. |

Decisions already made by Zane:

- **Instant + Undo.** When two phones match, the in-person connection is created right away. Both people see a "You met @name" card with an **Undo** button (~10 s in the UI; the server allows 30 s to cover lag).
- **Keep existing data.** Every current connection becomes `level = 'acquaintance'`, `method = 'legacy'`. Pending requests stay pending. Nothing is deleted.
- **Chat stays.** Don't change the chat feature's behavior or permissions. If chat access is currently gated on "is connected", make sure `acquaintance` still counts (see Phase 4.7).
- **Location privacy: store the city name only.** Raw GPS is used only to match bumps. It's stored for at most ~10 minutes and then deleted. The connection stores `met_city` (for example "Boise") and `met_at`. It never stores coordinates.
- **The map / spider web shows only `in_person` connections.**
- **The label "Map connection" will change.** Keep every user-facing level name in one constants file so renaming is a one-line change.

Meeting in person can also **upgrade** an existing acquaintance, or a pending request, to `in_person`.

### Why not real NFC?

Two iPhones can't swap data by tapping. Apple limits phone-to-phone NFC to its own features and to payment/wallet apps under special agreements. So "tap" is built from:

- **Bump:** both phones detect the physical tap with the accelerometer and send it to the server. The server pairs two bumps that are close in **time (~2 s)** and **place (~100–500 m)**.
- **QR:** one phone shows a short-lived code that rotates. The other phone scans it in the app.

Both work iPhone ↔ Android.

---

## 2. Architecture overview

```
┌──────────── Phone A ────────────┐        ┌──────────── Supabase ────────────┐        ┌──────── Phone B ────────┐
│ Connect screen                  │        │                                  │        │ Connect screen          │
│  • Tap tab: accelerometer ──────┼─bump──▶│ submit_bump()  ─┐                │◀─bump──┼── accelerometer         │
│    (location prefetched)        │        │ bump_events     ├─ match (±2 s,  │        │                         │
│  • My code tab: QR (rotates 30s)│        │                 │   ≤ ~150 m)    │        │                         │
│    token from create_connect_   │        │                 ▼                │        │  • Scan tab: camera ────┼─ redeem_connect_token()
│    token(); polls status        │        │ _connect_in_person() ───────────▶│ connections (level=in_person)
│  • Match card + Undo            │◀─poll──│ get_bump_result() /              │──poll─▶│  • Match card + Undo    │
│                                 │        │ get_connect_token_status()       │        │                         │
└─────────────────────────────────┘        └──────────────────────────────────┘        └─────────────────────────┘
```

**Core security rule:** the client can never set `level = 'in_person'` itself. Only `SECURITY DEFINER` functions can. A guard trigger enforces this, so it also covers the partner's web app and any hand-crafted API call.

**Result delivery:** use short **polling** of RPCs, not Supabase Realtime. It's simpler, it respects RLS without extra setup, and it's easy to debug. Realtime can be a later optimization.

---

## Phase 0: Discovery (no code changes)

**Goal:** understand the current code so every later step fits it.

1. Read `AGENTS.md`, `app.json` / `app.config.*`, `package.json`, `eas.json`.
2. List the Expo Router structure under `app/`: route groups, tabs (Home, Discover, Map, Profile), and any modal stacks.
3. Read **every** file in `supabase/migrations`. Write down:
   - the exact `connections` columns, the status type (enum or text?) and its values, and the unique constraint for "one connection per pair regardless of direction" (probably an index on `least()` / `greatest()`)
   - the self-connection check
   - all RLS policies on `connections`
   - any triggers: connection counting, `profiles` auto-create, anything else
   - whether a **blocks** table exists
   - whether a **chat/messages** table exists, and how its access is gated
   - which extensions are enabled (`pgcrypto`, `pg_cron`)
4. Find all client code that reads or writes `connections`: sending, accepting, declining, canceling, removing, the Discover buttons, mutuals, counts, the (possibly uncommitted) Connections screen, and public profile pages.
5. Find where Supabase types live (for example `types/supabase.ts`) and how they're generated.
6. Run `git status`. If there's **uncommitted work** (the Connections screen), **stop and ask Zane** whether to commit it first. Don't stash or discard it.
7. Check whether the app runs in **Expo Go** or needs a **development build** (any custom native modules?). All new packages in this plan work in Expo Go, which matters for testing on two real phones (see §Testing).
8. Confirm the local Supabase workflow (`supabase start`? `supabase db reset`?) versus remote-only.

**Output:** a short "Current state" note to Zane. It should list the real column names and a mapping table from this plan's placeholder names to the real ones, plus any conflicts with this plan.

**CHECKPOINT 0:** Zane confirms the mapping. Create the branch.

---

## Phase 1: Database: connection levels + write guard

**Goal:** add levels to `connections` and make `in_person` impossible to set from the client.

**Migration:** `supabase/migrations/<timestamp>_connection_levels.sql`

### 1.1 Types and columns

```sql
create type public.connection_level  as enum ('acquaintance', 'in_person');
create type public.connection_method as enum ('request', 'qr', 'bump', 'legacy');

alter table public.connections
  add column level         public.connection_level  not null default 'acquaintance',
  add column method        public.connection_method not null default 'request',
  add column met_at        timestamptz,
  add column met_city      text,
  add column undo_until    timestamptz,
  add column undo_snapshot jsonb;   -- previous state, used to revert an upgrade on Undo

-- Existing rows = legacy acquaintances (pending rows stay pending)
update public.connections set method = 'legacy';

alter table public.connections
  add constraint connections_in_person_is_accepted
    check (level <> 'in_person' or (status = 'accepted' and met_at is not null)),
  add constraint connections_met_city_len
    check (met_city is null or char_length(met_city) <= 80);

create index if not exists connections_level_idx on public.connections (level);
```

*Adapt `status = 'accepted'` to the real status column and type.*

### 1.2 Guard trigger (the core security piece)

Trusted server functions set a transaction-local flag. Every other write is forced to stay an acquaintance.

```sql
create or replace function public.connections_guard()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('bolas.trusted_write', true), '') = 'on' then
    return new;  -- called from our SECURITY DEFINER functions
  end if;

  if tg_op = 'INSERT' then
    new.level := 'acquaintance';
    new.method := 'request';
    new.met_at := null; new.met_city := null;
    new.undo_until := null; new.undo_snapshot := null;
  elsif tg_op = 'UPDATE' then
    if new.level        is distinct from old.level
    or new.method       is distinct from old.method
    or new.met_at       is distinct from old.met_at
    or new.met_city     is distinct from old.met_city
    or new.undo_until   is distinct from old.undo_until
    or new.undo_snapshot is distinct from old.undo_snapshot then
      raise exception 'Connection level can only change through an in-person connect'
        using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

create trigger connections_guard
  before insert or update on public.connections
  for each row execute function public.connections_guard();
```

Why this is safe: clients talk to Supabase through PostgREST, which only exposes functions in exposed schemas. Clients can't call `set_config` directly. Only our functions set the flag, and it resets at the end of the transaction.

Existing policies stay as they are: sending a request, accepting, and deleting (decline, cancel, remove) keep working. Removing an in-person connection by delete stays allowed (that's "remove connection").

### 1.3 Check existing triggers

- **Connection count trigger:** make sure it still counts correctly when a row is inserted directly as `accepted` (a new in-person connection) and when a row goes pending → accepted through an upgrade. If it only fires on specific transitions, extend it. Optional: add `profiles.map_connection_count`. Ask Zane.
- **Mutuals queries:** keep counting both levels for now and note it for Zane.

### 1.4 Distance helper

```sql
create or replace function public._distance_m(lat1 float8, lng1 float8, lat2 float8, lng2 float8)
returns float8 language sql immutable as $$
  select 2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;
```

(No PostGIS needed.)

### 1.5 Shared internal function `_connect_in_person`

Every in-person path (QR and bump) calls this. It isn't granted to clients.

```sql
create or replace function public._connect_in_person(
  p_a uuid, p_b uuid, p_method public.connection_method, p_city text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_conn    public.connections%rowtype;
  v_outcome text;
  v_city    text := nullif(left(trim(coalesce(p_city, '')), 80), '');
begin
  if p_a = p_b then raise exception 'self_connect' using errcode = 'P0001'; end if;

  -- If a blocks table exists: refuse when either user blocked the other.
  -- if exists (select 1 from blocks where ...) then return jsonb_build_object('outcome','unavailable'); end if;

  perform set_config('bolas.trusted_write', 'on', true);

  select * into v_conn from public.connections
   where (requester_id = p_a and addressee_id = p_b)
      or (requester_id = p_b and addressee_id = p_a)
   for update;

  if not found then
    begin
      insert into public.connections
        (requester_id, addressee_id, status, level, method, met_at, met_city, undo_until, undo_snapshot)
      values
        (p_a, p_b, 'accepted', 'in_person', p_method, now(), v_city, now() + interval '30 seconds', null)
      returning * into v_conn;
      v_outcome := 'created';
    exception when unique_violation then
      -- Both phones raced: the other call created it. Re-read and treat as already connected.
      select * into v_conn from public.connections
       where (requester_id = p_a and addressee_id = p_b)
          or (requester_id = p_b and addressee_id = p_a);
      v_outcome := 'already_connected';
    end;

  elsif v_conn.level = 'in_person' then
    v_outcome := 'already_connected';

  else
    update public.connections set
      undo_snapshot = jsonb_build_object(
        'status', v_conn.status, 'level', v_conn.level, 'method', v_conn.method,
        'met_at', v_conn.met_at, 'met_city', v_conn.met_city),
      status = 'accepted', level = 'in_person', method = p_method,
      met_at = now(), met_city = v_city,
      undo_until = now() + interval '30 seconds'
    where id = v_conn.id
    returning * into v_conn;
    v_outcome := 'upgraded';
  end if;

  perform set_config('bolas.trusted_write', 'off', true);

  return jsonb_build_object(
    'outcome', v_outcome,
    'connection_id', v_conn.id,
    'met_city', v_conn.met_city,
    'undo_until', v_conn.undo_until
  );
end $$;

revoke all on function public._connect_in_person(uuid, uuid, public.connection_method, text) from public, anon, authenticated;
```

*(Adapt the column names. If the pair-uniqueness index is on `least` / `greatest`, the lookup above still works.)*

### 1.6 `undo_in_person_connection(p_connection_id uuid)`

Callable by either person in the pair while `now() <= undo_until`:

- `undo_snapshot is null` (the connection was new) → **delete** the row.
- Otherwise → restore `status`, `level`, `method`, `met_at`, `met_city` from the snapshot.

In both cases, clear `undo_until` / `undo_snapshot` (set the trusted flag first), and return `{ outcome: 'undone' | 'too_late' | 'not_found' }`.

```sql
grant execute on function public.undo_in_person_connection(uuid) to authenticated;
```

### 1.7 Types

Regenerate the Supabase TypeScript types.

**CHECKPOINT 1:** apply locally and run the SQL tests in §Testing → DB, sections A and B. Show Zane that:

- a direct `update connections set level = 'in_person'` as a normal user **fails**
- sending and accepting a request still works

Commit.

---

## Phase 2: Database: QR tokens

**Migration:** `<timestamp>_connect_tokens.sql`

```sql
create table public.connect_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at    timestamptz,
  used_by    uuid references auth.users(id) on delete set null,
  result     jsonb
);
create index connect_tokens_user_idx on public.connect_tokens (user_id, created_at desc);
alter table public.connect_tokens enable row level security;
-- No policies on purpose: only SECURITY DEFINER functions touch this table.
grant select on public.connect_tokens to anon;
grant select, insert, update, delete on public.connect_tokens to authenticated;
grant select, insert, update, delete on public.connect_tokens to service_role;
```

### 2.1 `create_connect_token()` → jsonb `{ token, expires_at }`

- Requires `auth.uid()`.
- **Rate limit:** at most 6 tokens per user per minute. (The UI rotates every 30 s and on each use.)
- Housekeeping: delete this user's expired tokens, plus any token older than 1 hour globally.
- Token = `encode(extensions.gen_random_bytes(16), 'hex')`: 128 bits, impossible to guess. Check which schema `pgcrypto` lives in (Supabase: `extensions`) and set `search_path = public, extensions`.
- `expires_at = now() + interval '60 seconds'`.
- Return JSON, not `returns table (...)`: output column names like `token` clash with table columns inside plpgsql.

### 2.2 `redeem_connect_token(p_token text, p_city text default null)` → jsonb

1. Require auth. Look up the token with `select ... for update`.
2. If not found, return `{outcome:'invalid'}`. If used, return `'used'`. If expired, return `'expired'`. If the owner is the caller, return `'self'`.
3. Mark `used_at = now()`, `used_by = auth.uid()`.
4. `v := _connect_in_person(auth.uid(), token.user_id, 'qr', p_city)`.
5. If `p_city` is null, fall back to the scanner's `profiles.city`, then the code owner's.
6. Save `result = v || {other_user_id: auth.uid()}` on the token row, so the **code owner's** phone can read who scanned it.
7. Return `v || { other_user_id: token.user_id, other_profile: {id, username, full_name, avatar_url} }`.

### 2.3 `get_connect_token_status(p_token text)` → jsonb

- Owner only; otherwise return `{status:'not_found'}`.
- Returns `{status:'active'|'expired'|'used', result, other_profile}`. The code owner's phone polls this every ~1 s while the QR is on screen, so **both** people get the match card.

Grant `execute` on the three public functions to `authenticated` only (revoke from `public` and `anon`).

**CHECKPOINT 2:** run SQL tests section C. Commit.

---

## Phase 3: Database: bump matching

**Migration:** `<timestamp>_bump_events.sql`

```sql
create table public.bump_events (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default clock_timestamp(),
  lat             double precision not null check (lat between -90 and 90),
  lng             double precision not null check (lng between -180 and 180),
  accuracy_m      real not null check (accuracy_m > 0),
  city            text check (city is null or char_length(city) <= 80),
  status          text not null default 'waiting'
                  check (status in ('waiting', 'matched', 'ambiguous', 'no_match')),
  matched_user_id uuid,
  result          jsonb
);
create index bump_events_waiting_idx on public.bump_events (created_at) where status = 'waiting';
create index bump_events_user_idx    on public.bump_events (user_id, created_at desc);
alter table public.bump_events enable row level security;  -- no policies
-- + the standard 3 grants
```

### 3.1 Matching rules (tunable constants at the top of the function)

| Constant | Start value | Meaning |
|---|---|---|
| `WINDOW` | 2 seconds | Max gap between the two bumps' **server receive times**. Use server time, not phone clocks, because phone clocks drift. |
| `MIN_RADIUS_M` | 100 | Always allow at least this distance. |
| `MAX_RADIUS_M` | 500 | Never allow more than this. |
| radius used | `clamp(acc_a + acc_b, MIN, MAX)` | GPS indoors is poor, so trust the reported accuracy within limits. |
| `MAX_ACCURACY_M` | 1000 | If accuracy is worse than this, reject with `poor_location`. |
| `RESULT_WAIT` | 3 seconds | How long an unmatched bump waits before `no_match`. |
| Rate limit | 10 bumps / user / min | |

### 3.2 `submit_bump(p_lat, p_lng, p_accuracy_m, p_city)` → jsonb

1. Require auth. Apply the rate limit. Validate inputs (return `{status:'poor_location'}` if accuracy exceeds the max).
2. **Privacy housekeeping:** `delete from bump_events where created_at < now() - interval '10 minutes'`. Raw GPS never lives longer than this. (Optional: also schedule it with `pg_cron` if that's enabled. Ask Zane.)
3. `perform pg_advisory_xact_lock(hashtext('bolas_bump_match'));` serializes matching so two bumps can't both claim the same partner. One global lock is fine at this scale. Add a comment noting that, at large scale, this should become a lock per geographic grid cell.
4. Insert your own row (`status = 'waiting'`, `created_at = clock_timestamp()`).
5. Find **candidates**: rows with `status = 'waiting'`, `user_id <> me`, `created_at >= my.created_at - WINDOW`, and distance within the radius.
6. Then:
   - **0 candidates:** return `{status:'waiting', bump_id}`. The client polls `get_bump_result`.
   - **1 candidate:**
     1. `v := _connect_in_person(me, other, 'bump', coalesce(p_city, other.city))`.
     2. Update **both** rows to `status = 'matched'`, set `matched_user_id`, and store `result` (each row gets the *other* person's id and profile).
     3. Null out `lat` and `lng` on both rows right away. If NOT NULL gets in the way, delete the rows after copying the result, or allow nulls after matching.
     4. Return `{status:'matched', ...v, other_profile}`.
   - **2 or more candidates:** set my row and all candidates to `'ambiguous'`, and return `{status:'ambiguous'}`. The UI says: "Lots of people tapping nearby. Use your QR code instead."

### 3.3 `get_bump_result(p_bump_id uuid)` → jsonb

- Owner only.
- If `waiting` and older than `RESULT_WAIT`, set it to `no_match` and return that.
- Otherwise return the status and result.

**Known limitation (write it in a code comment):** if a third person bumps within the window *after* A and B already matched, it can't be detected. The match card's Undo covers rare mistakes.

**CHECKPOINT 3:** SQL tests section D, simulating bumps as different users. Commit.

---

## Phase 4: Mobile app

### 4.1 Install packages

Always use `npx expo install` so the versions match SDK 57:

```
npx expo install expo-camera expo-location expo-sensors expo-haptics react-native-svg react-native-qrcode-svg
```

(Check whether `react-native-svg` / `expo-haptics` are already installed. Read the SDK 57 docs for each package first.)

### 4.2 `app.json` config plugins and permission text

- **`expo-camera`:** `cameraPermission`: "Bolas uses your camera to scan a friend's code when you meet in person." Turn off microphone permission if the plugin supports it (we don't record video).
- **`expo-location`:** `locationWhenInUsePermission`: "Bolas uses your location only while you're tapping phones, to match you with the person you're with and note the city you met in." **No background location.**
- **`expo-sensors`:** `motionPermission` (iOS `NSMotionUsageDescription`), if the docs say the accelerometer needs it: "Bolas detects when you tap phones with someone."

Any change here needs a **new development build** if the app uses dev builds. Tell Zane.

### 4.3 Shared code: `lib/connect/`

| File | Purpose |
|---|---|
| `labels.ts` | `CONNECTION_LEVEL_LABEL = { acquaintance: 'Acquaintance', in_person: 'Map connection' }` plus the plural and short forms. **Every** user-facing level name comes from here, so renaming is one line. |
| `api.ts` | Typed wrappers: `createConnectToken`, `getConnectTokenStatus`, `redeemConnectToken`, `submitBump`, `getBumpResult`, `undoInPersonConnection`. Map the RPC `outcome` / `status` strings to a TypeScript discriminated union. Put friendly error messages in one place. |
| `location.ts` | `useConnectLocation()`: asks for foreground permission, then keeps a **fresh fix while the Connect screen is open** (`watchPositionAsync`, balanced accuracy). Reverse-geocodes **once** to get a city (`reverseGeocodeAsync`, using the `city`, `subregion`, `district` fields in that order). Falls back to `profiles.city`. Returns `{ status, coords, accuracy, city }`. Stops watching when the screen loses focus (`useFocusEffect`). |
| `bumpDetector.ts` | A **pure function** (easy to unit-test) that takes accelerometer samples and returns "bump detected" events. |
| `useBumpDetector.ts` | Hook: subscribes to `Accelerometer` (~50–60 Hz via `setUpdateInterval`) only while armed, feeds samples to `bumpDetector`, and fires `onBump()`. |
| `useRotatingToken.ts` | Creates a token when mounted, again every **30 s**, and right after a use. Polls `getConnectTokenStatus` every **1 s** and fires `onMatched(result)` when it's used. Pauses when the app goes to the background (`AppState`) or the screen loses focus. |
| `parseConnectUrl.ts` | Accepts `bolas://connect/<token>` (and later `https://<landing-domain>/c/<token>`). Validates a 32-char hex token. |

**Bump detection algorithm (`bumpDetector.ts`), starting point:**

1. `mag = sqrt(x² + y² + z²)`. Check in the SDK 57 docs that units are **g** on both platforms.
2. `delta = |mag − 1|` removes gravity. Also track the change between consecutive samples (jerk).
3. Trigger when `delta > SPIKE_G` (start at **1.3 g**) **and** jerk exceeds `JERK_G` (start at **1.0 g** per sample). This catches a sharp tap, not a slow wave.
4. **Cooldown** 2.5 s after a trigger.
5. Put all thresholds in one exported `BUMP_TUNING` object.
6. Add a **dev-only debug overlay** (only when `__DEV__`) that shows live `delta` / jerk and the trigger count, so Zane can tune on real phones.

When a bump is detected:

1. Light haptic.
2. Show "Matching…".
3. Call `submitBump` with the **already-prefetched** location. Never wait for GPS after the tap.
4. If the status is `waiting`, poll `getBumpResult` every 400 ms for up to ~3.5 s.

### 4.4 Connect screen (new route)

- Route: `app/connect/index.tsx` (or the modal-stack equivalent in the existing route groups), shown with `presentation: 'modal'`.
- Top: a segmented control with three tabs: **Tap** · **My code** · **Scan**.

**Tap tab**

- Big illustration and the copy "Hold your phones and tap them together".
- Location permission states:
  - not asked → an explain screen, then the prompt
  - denied → "Tap needs your location to find the person you're with" with **Open Settings** and **Use QR instead**
- While active: a subtle "Ready" pulse. After a tap: "Matching…".
- Result messages:
  - `no_match` → "Didn't catch that. Tap again at the same time."
  - `ambiguous` → "Lots of people tapping nearby. Use your code instead." (switches to My code)
  - `poor_location` → "Can't get a good location. Try My code."
- Dev-only "Simulate bump" button that calls `submitBump` without a physical tap. It makes testing possible on a simulator paired with a real phone.

**My code tab**

- The user's QR (`react-native-qrcode-svg`, value `bolas://connect/<token>`), their avatar, @username, and "Have them scan this in Bolas".
- A thin countdown bar for the rotation. The QR refreshes seamlessly.
- Keep the screen awake while it's visible, if that's easy (`expo-keep-awake`, optional). Consider raising brightness (optional, skip if awkward).

**Scan tab**

- `CameraView` with barcode scanning limited to `qr`, plus a camera permission gate (explain first, then prompt; if denied, show Open Settings).
- On scan: haptic, then **ignore further scans until this one resolves**. If it's not a Bolas code, show "That's not a Bolas code". Otherwise call `redeemConnectToken(token, city)`.
- City comes from `useConnectLocation`. If location was denied, send null and the server falls back to the profile city. **Scanning never requires location permission.**
- Result messages:
  - `expired` → "That code expired. Ask them to refresh."
  - `used` → "That code was just used. Scan their new one."
  - `self` → "That's your own code 🙂"

### 4.5 Match card (shared component)

`components/connect/MatchCard.tsx`, shown as a sheet or overlay on **both** phones:

- Success haptic and a quick animation (a strand connecting two avatars, a nice nod to the spider web).
- The other person's avatar, full name, @username, and "You're now **{in_person label}** · Met in {city}".
  - `outcome = 'upgraded'` → "You were acquaintances. Now you've met!"
  - `outcome = 'already_connected'` → "You're already connected with @name." No Undo button.
- **Undo** with a 10 s countdown ring. It calls `undoInPersonConnection`. On `too_late`, show "Too late to undo. You can remove them from their profile."
- Buttons: **View profile**, **Message** (opens the existing chat), **Done** (returns to the Connect screen, ready for the next person, which suits events).

### 4.6 Deep link route

- Expo Router maps `bolas://connect/<token>` to `app/connect/[token].tsx` automatically.
- **Check for conflicts** with `app/connect/index.tsx` and route groups.
- Behavior:
  - signed in → redeem, then show the MatchCard
  - signed out → store the token in memory, run the normal auth flow, then redeem (it may have expired, which shows the "expired" message)
  - profile setup not finished → finish setup first (the existing gate)
- Scanning with the phone's own camera app may or may not offer to open a `bolas://` link. The in-app scanner is the main path. Universal links (`https://...`) need the Apple Developer account and are **out of scope** (see Phase 6).

### 4.7 Updates to existing screens

- **Entry points to Connect:**
  - an icon or button in the Home header
  - a "Connect in person" button on the Profile tab
  - on another user's public profile when you're not in-person connected: "Met in real life? **Tap phones** to add them to your map" (opens Connect)
  - a Map tab placeholder CTA: "Your map grows when you meet people. **Connect in person**"
- **Discover / public profiles:** relabel the existing "Connect / Send request" button to "Add as {acquaintance label}". The request flow itself doesn't change.
- **Connection badges:** a small chip on list rows and profile headers showing the level. For `in_person`, add "Met {Mon D} · {city}".
- **Connections screen** (including the uncommitted work from Phase 0):
  - add a filter or sections for **Map connections** and **Acquaintances**, plus the existing Pending
  - the existing remove / decline / cancel actions still work
- **Mutuals:** show them as before. Optionally mark which mutuals you've met in person.
- **Map data helper:** add `getMapConnections(userId)` that returns only `level = 'in_person'`, ready for the upcoming spider-web map. Don't build the map itself now.
- **Chat:** no behavior change. If Phase 0 found chat gated on "connected", confirm acquaintances still qualify. If chat depends on anything this plan changes, flag it to Zane rather than deciding.
- **Settings (optional):** a "Location & tapping" help row explaining that only the city is kept.

### 4.8 Error handling and offline

- Every RPC call has a timeout (~8 s) and a friendly offline message: "You're offline. Connecting in person needs internet on both phones."
- Show `rate_limited` as "Slow down a sec and try again."
- Never show raw Supabase or Postgres error text to users. Log it in `__DEV__` only.

**CHECKPOINT 4a** (after the QR flow works end to end on two devices). Commit.
**CHECKPOINT 4b** (after Bump works end to end on two phones). Commit.

---

## Phase 5: Partner / web app coordination

Write `docs/in-person-connections-for-web.md` for Zane's partner. It should cover:

- the new `connections` columns and types, and the regenerated types
- that the guard trigger means the web **can still** send and accept acquaintance requests unchanged, but **can't** create `in_person`
- the RPC list and what each returns
- an optional web idea: a "Show my code" page (the QR only; the web can't bump)
- the label constants approach, so both apps use the same level names

---

## Phase 6: Later / out of scope (list it, don't build it)

- Universal links (`https://<landing>/c/<token>`), so the system camera opens the app. Needs the Apple Developer account plus `apple-app-site-association` and `assetlinks.json` on the Cloudflare landing page.
- Supabase Realtime instead of polling.
- Physical Bolas NFC stickers or cards (phones *can* read NFC tags).
- Geographic-cell locking for bump matching at scale.
- Push notification "You met @x", for when a phone locks mid-match.
- A final name for the "Map connection" level (it's just a label change).
- The intro-request flow via mutuals.

---

## Testing

### DB tests

Put these in `supabase/tests/in_person_connections.sql`. Use pgTAP if it's already set up (`supabase test db`). Otherwise write a plain SQL script. To simulate users, use `set local role authenticated; set local request.jwt.claims = '{"sub":"<uuid>"}';` inside transactions. Create 3–4 test users.

**A. Guard**

- A user can't insert with `level = 'in_person'`: it's forced to acquaintance.
- A user can't update `level`, `method`, `met_*`, or `undo_*`.
- Sending, accepting, declining, canceling, and removing requests still work.

**B. `_connect_in_person` via the public RPCs**

- A new pair → `created`, with status accepted, met_at, and city set.
- An existing accepted acquaintance → `upgraded`, with the snapshot saved.
- A pending request → `upgraded`, and Undo restores pending.
- Already in person → `already_connected`, with no changes.
- Undo inside 30 s: a new connection is deleted, and an upgrade is reverted.
- Undo after 30 s → `too_late`.
- Undo by a third user → `not_found`.
- Connection counts stay correct through every path.

**C. QR**

- Token is 32 hex characters and expires in 60 s.
- Redeem: works once; `used` the second time; `expired` after it expires; `self` for your own token; `invalid` for junk.
- The owner sees `used` plus the scanner's profile via `get_connect_token_status`. A non-owner gets `not_found`.
- More than 6 tokens a minute is rate limited.
- The anon role can't call any of these.

**D. Bump**

- Two users 50 m apart, 1 s apart → matched, and the connection is created once.
- 3 s apart → the first gets `no_match`.
- 2 km apart → no match.
- Three users within the window → `ambiguous`.
- Rows older than 10 minutes are purged on the next call, and matched rows have no coordinates.
- Rate limit.
- A user can't read other users' `bump_events` directly (RLS).

### Client unit tests (if Jest is configured; if not, ask Zane before adding it)

- `bumpDetector`: synthetic sample arrays covering a sharp tap (detects), walking or a gentle shake (doesn't detect), two taps within the cooldown (one event).
- `parseConnectUrl`: valid and invalid inputs.

### Manual QA on two real phones

| # | Scenario | Expected |
|---|---|---|
| 1 | A shows code, B scans | Both see the match card within ~1–2 s; city is right |
| 2 | B scans A's code again | "Already connected" |
| 3 | Undo within 10 s, on either phone | Connection gone or reverted on both after refresh |
| 4 | A and B are acquaintances, then tap | "Now you've met" (upgraded) |
| 5 | Tap phones (both on Tap tab) | Match within ~2 s |
| 6 | Wave phone / walk around | No false bumps |
| 7 | Deny location, then use Tap | Friendly gate plus a "Use QR" button |
| 8 | Deny location, then Scan | Still works; city comes from the profile |
| 9 | Deny camera | Gate plus Open Settings |
| 10 | Screenshot of a QR scanned 2 min later | "Expired" |
| 11 | Airplane mode | Offline message, no crash |
| 12 | Signed out, open a `bolas://connect/...` link | Login, then redeem (or "expired") |
| 13 | iPhone ↔ Android, both directions | Works |
| 14 | Web app: send and accept an acquaintance request | Still works |

**Testing on two physical phones:**

- If the app runs in **Expo Go**, everything in this plan works there. That's the easiest path, and no paid Apple account is needed.
- If it needs a **development build**:
  - Android: an EAS dev build APK installs free.
  - iPhone: EAS device builds need the paid Apple Developer Program, which Zane hasn't bought yet. Alternative: `npx expo run:ios --device` with a free Apple ID in Xcode (the app expires after 7 days).
- A simulator can't bump or scan a real camera. Use the dev-only "Simulate bump" button, and scan a QR shown on the simulator screen with a real phone.

---

## Definition of done

- [ ] All migrations apply cleanly on a fresh local database (`supabase db reset`) and all DB tests pass.
- [ ] A client **can't** create or upgrade an `in_person` connection except through the QR and bump RPCs.
- [ ] QR and bump both work end to end, iPhone ↔ Android, with a match card and Undo on **both** phones.
- [ ] Existing connections show as acquaintances (`legacy`), and the request flow still works on mobile and web.
- [ ] No coordinates are stored on `connections`, and `bump_events` coordinates are gone within 10 minutes.
- [ ] All level names come from `lib/connect/labels.ts`.
- [ ] No TypeScript errors, and lint passes.
- [ ] Web-partner doc written.
- [ ] One commit per phase on `feature/in-person-connections`, not pushed until Zane says so.
- [ ] A final summary for Zane covering what was built, what to test, the tuning knobs (`BUMP_TUNING`, server constants), and the open questions.

## Open questions to raise with Zane when they come up (don't decide alone)

1. The final name for the `in_person` level.
2. Whether chat should be limited by level. (Current plan: no change.)
3. Whether to add a separate `map_connection_count` on profiles.
4. Whether to use `pg_cron` for cleanup (if it's enabled) or just the opportunistic cleanup inside the RPCs.
5. Whether removing an in-person connection should drop it back to acquaintance or remove it entirely. (Current plan: remove entirely, same as today.)
