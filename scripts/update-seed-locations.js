#!/usr/bin/env node

/**
 * Updates the already-created seed accounts' locations to match the
 * current lat/lng values in seed-data.js. Use this when the fixture
 * positions change (e.g. re-arranging the layout) without wanting to
 * delete and recreate the accounts and their connections.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY in .env (same as the other seed scripts).
 *
 * Usage:
 *   node scripts/update-seed-locations.js            # dry run
 *   node scripts/update-seed-locations.js --confirm   # actually update
 */

const fs = require("fs");
const path = require("path");
const { SEED_EMAIL_DOMAIN, PROFILES } = require("./seed-data");

function loadEnv() {
  const envPath = path.join(__dirname, "..", ".env");
  const vars = {};
  if (fs.existsSync(envPath)) {
    for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq === -1) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      ) {
        value = value.slice(1, -1);
      }
      vars[key] = value;
    }
  }
  return { ...vars, ...process.env };
}

async function main() {
  const env = loadEnv();
  const url = env.EXPO_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY;
  const confirmed = process.argv.includes("--confirm");

  if (!url) {
    console.error("Missing EXPO_PUBLIC_SUPABASE_URL in .env");
    process.exit(1);
  }
  if (!serviceKey) {
    console.error("Missing SUPABASE_SERVICE_ROLE_KEY in .env.");
    process.exit(1);
  }

  console.log(`Target Supabase project: ${url}`);

  const { createClient } = require("@supabase/supabase-js");
  const supabase = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

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
