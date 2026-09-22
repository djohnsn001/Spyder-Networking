#!/usr/bin/env node

/**
 * Gives every seed account a random profile picture. Each run picks a
 * fresh random portrait from randomuser.me (a free placeholder-photo
 * service), matched to the name in seed-data.js, then uploads it to the
 * avatars storage bucket under that user's folder — the same place the app
 * puts real uploads — so the app never loads images from a third party.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY in .env (same as the other seed scripts).
 *
 * Usage:
 *   node scripts/update-seed-avatars.js            # dry run
 *   node scripts/update-seed-avatars.js --confirm   # actually update
 */

const fs = require("fs");
const path = require("path");
const { SEED_EMAIL_DOMAIN, PROFILES } = require("./seed-data");

// randomuser.me groups its portraits as "women" / "men", 0-99 each.
const PORTRAIT_GROUP = {
  ava: "women",
  marcus: "men",
  bella: "women",
  priya: "women",
  jordan: "men",
  liam: "men",
  sofia: "women",
  tyler: "men",
  grace: "women",
  noah: "men",
  maya: "women",
  ethan: "men",
};
const PORTRAITS_PER_GROUP = 100;

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

// Random portrait numbers with no repeats within a group, so no two seed
// accounts end up with the same face.
function pickPortraits() {
  const used = { women: new Set(), men: new Set() };
  const picks = {};
  for (const profile of PROFILES) {
    const group = PORTRAIT_GROUP[profile.key];
    if (!group) throw new Error(`No portrait group for seed profile "${profile.key}"`);
    let index;
    do {
      index = Math.floor(Math.random() * PORTRAITS_PER_GROUP);
    } while (used[group].has(index));
    used[group].add(index);
    picks[profile.key] = `https://randomuser.me/api/portraits/${group}/${index}.jpg`;
  }
  return picks;
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

  const portraits = pickPortraits();
  console.log(`${PROFILES.length} account(s) to update:`);
  for (const profile of PROFILES) {
    console.log(`  ${profile.full_name} -> ${portraits[profile.key]}`);
  }

  if (!confirmed) {
    console.log("\nDry run only — nothing was changed. Re-run with --confirm to actually update.");
    return;
  }

  for (const profile of PROFILES) {
    const userId = idByKey[profile.key];

    const response = await fetch(portraits[profile.key]);
    if (!response.ok) {
      throw new Error(`Failed to download portrait for ${profile.key}: HTTP ${response.status}`);
    }
    const image = Buffer.from(await response.arrayBuffer());

    // Clear out this account's previous seed avatars so re-running doesn't
    // pile up files. Only touches files this script created (seed-*).
    const { data: existing, error: listFilesError } = await supabase.storage
      .from("avatars")
      .list(userId);
    if (listFilesError) throw listFilesError;
    const oldSeedFiles = (existing ?? [])
      .filter((file) => file.name.startsWith("seed-"))
      .map((file) => `${userId}/${file.name}`);
    if (oldSeedFiles.length > 0) {
      const { error: removeError } = await supabase.storage.from("avatars").remove(oldSeedFiles);
      if (removeError) throw removeError;
    }

    // A new file name each run, so the app's image cache can't keep showing
    // the previous picture.
    const storagePath = `${userId}/seed-${Date.now()}.jpg`;
    const { error: uploadError } = await supabase.storage
      .from("avatars")
      .upload(storagePath, image, { contentType: "image/jpeg" });
    if (uploadError) throw uploadError;

    const { data: publicUrlData } = supabase.storage.from("avatars").getPublicUrl(storagePath);
    const { error: profileError } = await supabase
      .from("profiles")
      .update({ avatar_url: publicUrlData.publicUrl })
      .eq("id", userId);
    if (profileError) throw profileError;

    console.log(`  ✓ ${profile.full_name}`);
  }

  console.log(`\nUpdated ${PROFILES.length} avatar(s).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
