#!/usr/bin/env node

/**
 * Seeds ~12 fake profiles spread around Boise, Meridian, Nampa, Eagle, and
 * Caldwell, with a mix of connections to your own account and to each
 * other, so the Web Map has something to draw during development.
 *
 * Every seed account uses an @bolas-seed.local email and is tagged
 * { seed: true } in its auth metadata, so it's easy to find and delete
 * later and easy to tell apart from real users at a glance.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY in .env (get it from the Supabase
 * dashboard: Project Settings -> API -> service_role key). That key
 * bypasses Row Level Security entirely, so it is never used by the app
 * itself and must never be prefixed EXPO_PUBLIC_ or committed.
 *
 * Usage:
 *   node scripts/seed-map-data.js            # dry run: shows target + plan, does nothing
 *   node scripts/seed-map-data.js --confirm   # actually creates the data
 */

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { SEED_EMAIL_DOMAIN, PROFILES, SEED_TO_SEED_EDGES } = require("./seed-data");

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

const YOUR_EMAIL = "zanemechling07@gmail.com";

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
    console.error(
      "Missing SUPABASE_SERVICE_ROLE_KEY in .env.\n" +
        "Add it from the Supabase dashboard: Project Settings -> API -> service_role key.\n" +
        "Do NOT prefix it EXPO_PUBLIC_ (it must never ship in the app bundle) and never commit it."
    );
    process.exit(1);
  }

  console.log(`Target Supabase project: ${url}`);
  console.log(`This will create ${PROFILES.length} fake profiles + connections to ${YOUR_EMAIL} and each other.`);

  if (!confirmed) {
    console.log("\nDry run only — nothing was created. Re-run with --confirm to actually seed data.");
    return;
  }

  const { createClient } = require("@supabase/supabase-js");
  const supabase = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Guard against double-seeding: bail out if seed accounts already exist.
  const { data: existingUsers, error: listError } = await supabase.auth.admin.listUsers({ perPage: 1000 });
  if (listError) throw listError;

  const alreadySeeded = existingUsers.users.some((u) => u.email?.endsWith(`@${SEED_EMAIL_DOMAIN}`));
  if (alreadySeeded) {
    console.error(
      "Seed accounts already exist (found an @" +
        SEED_EMAIL_DOMAIN +
        " user). Delete them first (Supabase dashboard -> Authentication -> filter by email) before reseeding."
    );
    process.exit(1);
  }

  const you = existingUsers.users.find((u) => u.email === YOUR_EMAIL);
  if (!you) {
    console.error(`Could not find your own account (${YOUR_EMAIL}) in auth.users — check the email is right.`);
    process.exit(1);
  }

  const idByKey = {};

  for (const profile of PROFILES) {
    const email = `${profile.key}@${SEED_EMAIL_DOMAIN}`;
    const { data: created, error: createError } = await supabase.auth.admin.createUser({
      email,
      password: crypto.randomUUID(),
      email_confirm: true,
      user_metadata: { seed: true, full_name: profile.full_name },
    });
    if (createError) throw createError;

    idByKey[profile.key] = created.user.id;

    // handle_new_user already inserted a bare profiles row for us — fill it in.
    const { error: updateError } = await supabase
      .from("profiles")
      .update({
        username: profile.username,
        full_name: profile.full_name,
        bio: profile.bio,
        interests: profile.interests,
        business_stage: profile.business_stage,
        city: profile.city,
        location_sharing: "connections",
      })
      .eq("id", created.user.id);
    if (updateError) throw updateError;

    const { error: locationError } = await supabase
      .from("user_locations")
      .insert({ user_id: created.user.id, lat: profile.lat, lng: profile.lng });
    if (locationError) throw locationError;

    console.log(`Created ${profile.full_name} (${profile.city})`);
  }

  const connectionRows = [
    // You <-> every seed profile, already accepted.
    ...PROFILES.map((p) => ({
      requester_id: you.id,
      addressee_id: idByKey[p.key],
      status: "accepted",
    })),
    // Mutual connections among seed profiles.
    ...SEED_TO_SEED_EDGES.map(([a, b]) => ({
      requester_id: idByKey[a],
      addressee_id: idByKey[b],
      status: "accepted",
    })),
  ];

  const { error: connectionsError } = await supabase.from("connections").insert(connectionRows);
  if (connectionsError) throw connectionsError;

  console.log(`\nDone. Created ${PROFILES.length} profiles and ${connectionRows.length} connections.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
