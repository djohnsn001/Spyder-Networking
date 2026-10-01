#!/usr/bin/env node

/**
 * Race test for member numbers (migration 20260930030000): many profiles are
 * completed at the same moment, on separate database connections, and every
 * one must get a different number with no gaps.
 *
 * supabase/tests/stats_badges.sql can't test this: it runs in one
 * transaction, so nothing is ever simultaneous. Here each profile is
 * completed by its own API request, all sent at once, so PostgREST runs them
 * on different pooled connections and they queue on the counter row.
 *
 * Two of the requests fail on purpose AFTER taking a number (an invalid
 * business_stage passes the completeness check in the trigger, then fails the
 * table's CHECK constraint). Their transactions roll back, so their numbers
 * must be handed to the next profile: the numbers still come out gap-free.
 *
 * What it checks:
 *   - the successful profiles got distinct numbers, exactly start+1..start+N
 *   - the failed ones got none, and the counter moved by exactly N
 *   - each one holds the matching Founder / Early Member badge and number
 *
 * Afterwards it deletes the test accounts (the database cascades their
 * profiles and badges) and puts the counter back, unless a real profile was
 * numbered during the run, in which case it leaves the counter alone and
 * says so.
 *
 * Needs scripts/.env.seed.local (SUPABASE_URL + SUPABASE_SECRET_KEY for the
 * DEV project); see scripts/seed-env.js. Refuses to run against production.
 *
 * Usage:
 *   node scripts/test-member-numbering-race.js            # 25 at once
 *   node scripts/test-member-numbering-race.js --count 60
 */

const crypto = require("crypto");
const { createAdminClient, loadSeedEnv } = require("./seed-env");

const EMAIL_DOMAIN = "race.bolas.invalid";
const FAILING = 2;
const FOUNDER_MAX = 200;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  return i === -1 ? fallback : Number(process.argv[i + 1]);
}

async function memberCounter(supabase) {
  const { data, error } = await supabase
    .from("badge_counters")
    .select("last_number")
    .eq("key", "member")
    .single();
  if (error) throw error;
  return data.last_number;
}

async function main() {
  const count = argValue("--count", 25);
  if (!Number.isInteger(count) || count < 2 || count > 200) {
    throw new Error("--count must be a whole number from 2 to 200");
  }

  const supabase = createAdminClient(loadSeedEnv());
  const users = [];
  let passed = false;

  try {
    const start = await memberCounter(supabase);
    console.log(`Member counter before: ${start}`);

    // Accounts (handle_new_user makes each a bare, incomplete profile).
    const total = count + FAILING;
    for (let i = 0; i < total; i++) {
      const { data, error } = await supabase.auth.admin.createUser({
        email: `${crypto.randomUUID()}@${EMAIL_DOMAIN}`,
        password: crypto.randomUUID(),
        email_confirm: true,
      });
      if (error) throw error;
      users.push({ id: data.user.id, fails: i % Math.ceil(total / FAILING) === 1 });
    }
    console.log(`Created ${total} test accounts (${FAILING} set up to fail)`);

    // Complete them all at once.
    const tag = crypto.randomBytes(3).toString("hex");
    const started = Date.now();
    const results = await Promise.all(
      users.map((user, i) =>
        supabase
          .from("profiles")
          .update({
            username: `race_${tag}_${i}`,
            full_name: `Race ${i}`,
            city: "Testville",
            business_stage: user.fails ? "not_a_stage" : "idea",
          })
          .eq("id", user.id)
      )
    );
    console.log(`Sent ${total} simultaneous profile updates in ${Date.now() - started} ms`);

    const problems = [];
    results.forEach((result, i) => {
      if (users[i].fails && !result.error) problems.push(`update ${i} should have failed but didn't`);
      if (!users[i].fails && result.error) problems.push(`update ${i} failed: ${result.error.message}`);
    });

    const { data: rows, error: rowsError } = await supabase
      .from("profiles")
      .select("id, member_number, profile_completed_at")
      .in("id", users.map((u) => u.id));
    if (rowsError) throw rowsError;
    const { data: badges, error: badgesError } = await supabase
      .from("user_badges")
      .select("user_id, badge_key, number")
      .in("user_id", users.map((u) => u.id));
    if (badgesError) throw badgesError;

    const byId = new Map(rows.map((r) => [r.id, r]));
    const ok = users.filter((u) => !u.fails).map((u) => byId.get(u.id));
    const failed = users.filter((u) => u.fails).map((u) => byId.get(u.id));

    const numbers = ok.map((r) => r.member_number).sort((a, b) => a - b);
    const expected = Array.from({ length: count }, (_, i) => start + 1 + i);
    if (numbers.join() !== expected.join()) {
      problems.push(`numbers aren't exactly ${start + 1}..${start + count}: got ${numbers.join(", ")}`);
    }
    if (failed.some((r) => r.member_number != null || r.profile_completed_at != null)) {
      problems.push("a rolled-back profile kept a number");
    }

    const end = await memberCounter(supabase);
    if (end !== start + count) problems.push(`counter moved by ${end - start}, expected ${count}`);

    for (const row of ok) {
      const expectedKey = row.member_number <= FOUNDER_MAX ? "founder" : "early_member";
      const mine = badges.filter((b) => b.user_id === row.id);
      if (mine.length !== 1 || mine[0].badge_key !== expectedKey || mine[0].number !== row.member_number) {
        problems.push(`#${row.member_number} has badges ${JSON.stringify(mine)}, expected ${expectedKey}`);
      }
    }
    if (failed.some((r) => badges.some((b) => b.user_id === r.id))) {
      problems.push("a rolled-back profile got a badge");
    }

    // How much the transactions overlapped: now() is each one's start time.
    const times = ok.map((r) => Date.parse(r.profile_completed_at)).sort((a, b) => a - b);
    console.log(
      `Transactions started within ${times[times.length - 1] - times[0]} ms of each other ` +
        `(numbers ${numbers[0]}..${numbers[numbers.length - 1]})`
    );

    if (problems.length) {
      console.error(`\n✖ FAILED\n  - ${problems.join("\n  - ")}\n`);
      process.exitCode = 1;
    } else {
      passed = true;
      console.log(
        `\n✔ PASSED: ${count} distinct, gap-free numbers with matching badges; ` +
          `${FAILING} rolled-back numbers were reused\n`
      );
    }
  } finally {
    await cleanUp(supabase, users, passed);
  }
}

async function cleanUp(supabase, users, passed) {
  if (!users.length) return;
  const numbered = await supabase
    .from("profiles")
    .select("member_number")
    .in("id", users.map((u) => u.id))
    .not("member_number", "is", null);

  for (const user of users) {
    const { error } = await supabase.auth.admin.deleteUser(user.id);
    if (error) console.error(`Couldn't delete test account ${user.id}: ${error.message}`);
  }
  console.log(`Deleted ${users.length} test accounts`);

  // Hand the numbers back only if they were the last ones given out, i.e.
  // nobody real completed a profile during the run.
  const taken = (numbered.data ?? []).map((r) => r.member_number);
  if (!taken.length) return;
  const low = Math.min(...taken);
  const high = Math.max(...taken);
  let reset = false;
  if (high - low + 1 === taken.length) {
    const { data, error } = await supabase
      .from("badge_counters")
      .update({ last_number: low - 1 })
      .eq("key", "member")
      .eq("last_number", high)
      .select("last_number");
    if (error) throw error;
    reset = data.length > 0;
  }
  if (reset) {
    console.log(`Member counter reset to ${low - 1}`);
  } else {
    console.warn(
      `⚠ Left the member counter alone: another profile was numbered during the run` +
        (passed ? "" : " (or the numbers had gaps)") +
        `, so numbers ${low}..${high} now have gaps.`
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
