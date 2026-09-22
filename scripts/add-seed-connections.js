#!/usr/bin/env node

/**
 * Adds any connections from seed-data.js's SEED_TO_SEED_EDGES that don't
 * already exist between the fake accounts created by seed-map-data.js.
 * Safe to run more than once — it only inserts pairs that are missing,
 * so it won't error on connections that are already there.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY in .env (same as seed-map-data.js).
 *
 * Usage:
 *   node scripts/add-seed-connections.js            # dry run: shows what would be added
 *   node scripts/add-seed-connections.js --confirm   # actually adds them
 */

const fs = require("fs");
const path = require("path");
const { SEED_EMAIL_DOMAIN, SEED_TO_SEED_EDGES } = require("./seed-data");

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

function pairKey(a, b) {
  return [a, b].sort().join("::");
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
    const key = user.email.split("@")[0];
    idByKey[key] = user.id;
  }

  const missingKeys = SEED_TO_SEED_EDGES.flat().filter((key, i, arr) => arr.indexOf(key) === i && !idByKey[key]);
  if (missingKeys.length > 0) {
    console.error(
      `Couldn't find seed accounts for: ${missingKeys.join(", ")}. Run seed-map-data.js first.`,
    );
    process.exit(1);
  }

  const seedIds = Object.values(idByKey);
  const { data: existingConnections, error: connectionsError } = await supabase
    .from("connections")
    .select("requester_id, addressee_id")
    .in("requester_id", seedIds)
    .in("addressee_id", seedIds);
  if (connectionsError) throw connectionsError;

  const existingPairs = new Set(
    existingConnections.map((c) => pairKey(c.requester_id, c.addressee_id)),
  );

  const toInsert = [];
  const seenInBatch = new Set();
  for (const [a, b] of SEED_TO_SEED_EDGES) {
    const idA = idByKey[a];
    const idB = idByKey[b];
    const key = pairKey(idA, idB);
    if (existingPairs.has(key) || seenInBatch.has(key)) continue;
    seenInBatch.add(key);
    toInsert.push({ requester_id: idA, addressee_id: idB, status: "accepted" });
  }

  console.log(`${toInsert.length} connection(s) to add (${SEED_TO_SEED_EDGES.length - toInsert.length} already exist).`);

  if (!confirmed) {
    console.log("Dry run only — nothing was created. Re-run with --confirm to actually add them.");
    return;
  }

  if (toInsert.length === 0) {
    console.log("Nothing to do.");
    return;
  }

  const { error: insertError } = await supabase.from("connections").insert(toInsert);
  if (insertError) throw insertError;

  console.log(`Added ${toInsert.length} connection(s).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
