#!/usr/bin/env node

/**
 * Updates the already-created seed accounts' locations to match the
 * current lat/lng values in seed-data.js. Use this when the fixture
 * positions change (e.g. re-arranging the layout) without wanting to
 * delete and recreate the accounts and their connections.
 *
 * Needs .env.seed.local (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY for the DEV
 * project), never .env; see scripts/seed-env.js. The service key bypasses
 * Row Level Security, so it's never used by the app, never prefixed
 * EXPO_PUBLIC_, and never committed. Refuses to run against production
 * (fhevoocpcnrjxyjvitai) unless --i-know-this-is-production is passed.
 *
 * Usage:
 *   node scripts/update-seed-locations.js            # dry run
 *   node scripts/update-seed-locations.js --confirm   # actually update
 */

const { createAdminClient, loadSeedEnv } = require("./seed-env");
const { SEED_EMAIL_DOMAIN, PROFILES } = require("./seed-data");


async function main() {
  // Reads .env.seed.local and exits unless the target is safe (see seed-env.js).
  const { url, serviceKey } = loadSeedEnv();
  const confirmed = process.argv.includes("--confirm");



  const supabase = createAdminClient({ url, serviceKey });

  const { data: users, error: listError } = await supabase.auth.admin.listUsers({ perPage: 1000 });
  if (listError) throw listError;

  const idByKey = {};
  for (const user of users.users) {
    if (!user.email?.endsWith(`@${SEED_EMAIL_DOMAIN}`)) continue;
    idByKey[user.email.split("@")[0]] = user.id;
  }

  const missing = PROFILES.filter((p) => !idByKey[p.key]);
  if (missing.length > 0) {
    console.error(
      `Couldn't find seed accounts for: ${missing.map((p) => p.key).join(", ")}. Run seed-map-data.js first.`,
    );
    process.exit(1);
  }

  console.log(`${PROFILES.length} account(s) to update:`);
  for (const profile of PROFILES) {
    console.log(`  ${profile.full_name} (${profile.city}) -> ${profile.lat}, ${profile.lng}`);
  }

  if (!confirmed) {
    console.log("\nDry run only — nothing was changed. Re-run with --confirm to actually update.");
    return;
  }

  for (const profile of PROFILES) {
    const { error: locationError } = await supabase
      .from("user_locations")
      .update({ lat: profile.lat, lng: profile.lng })
      .eq("user_id", idByKey[profile.key]);
    if (locationError) throw locationError;

    const { error: profileError } = await supabase
      .from("profiles")
      .update({ city: profile.city })
      .eq("id", idByKey[profile.key]);
    if (profileError) throw profileError;
  }

  console.log(`\nUpdated ${PROFILES.length} account(s).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
