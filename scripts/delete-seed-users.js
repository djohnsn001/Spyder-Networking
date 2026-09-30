#!/usr/bin/env node

/**
 * Deletes every seed account (email ending in @bolas-seed.local) created by
 * seed-map-data.js, so a project can be cleaned up after testing.
 *
 * For each account it removes the avatars/<user id>/ files through the
 * Storage API (update-seed-avatars.js uploads there), then deletes the auth
 * user. The database cascades everything else: profile, connections,
 * locations, events, chats.
 *
 * Needs .env.seed.local (SUPABASE_URL + SUPABASE_SECRET_KEY for the DEV
 * project), never .env; see scripts/seed-env.js. Refuses to run against
 * production (fhevoocpcnrjxyjvitai) unless --i-know-this-is-production is
 * passed.
 *
 * Usage:
 *   node scripts/delete-seed-users.js            # dry run: lists the seed accounts
 *   node scripts/delete-seed-users.js --confirm   # actually deletes them
 */

const { createAdminClient, loadSeedEnv } = require("./seed-env");
const { SEED_EMAIL_DOMAIN } = require("./seed-data");

const PAGE_SIZE = 1000;
const AVATAR_BUCKET = "avatars";

async function listSeedUsers(supabase) {
  const seedUsers = [];
  for (let page = 1; ; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: PAGE_SIZE });
    if (error) throw error;
    seedUsers.push(...data.users.filter((u) => u.email?.endsWith(`@${SEED_EMAIL_DOMAIN}`)));
    if (data.users.length < PAGE_SIZE) break;
  }
  return seedUsers;
}

// Every file in avatars/<user id>/, listing again after each batch until empty.
async function removeAvatarFolder(supabase, userId) {
  let removed = 0;
  for (let round = 0; round < 50; round++) {
    const { data: files, error } = await supabase.storage.from(AVATAR_BUCKET).list(userId, { limit: 100 });
    if (error) throw error;
    if (!files || files.length === 0) break;
    const { error: removeError } = await supabase.storage
      .from(AVATAR_BUCKET)
      .remove(files.map((file) => `${userId}/${file.name}`));
    if (removeError) throw removeError;
    removed += files.length;
  }
  return removed;
}

async function main() {
  // Reads .env.seed.local and exits unless the target is safe (see seed-env.js).
  const { url, serviceKey } = loadSeedEnv();
  const confirmed = process.argv.includes("--confirm");

  const supabase = createAdminClient({ url, serviceKey });
  const seedUsers = await listSeedUsers(supabase);

  if (seedUsers.length === 0) {
    console.log(`No @${SEED_EMAIL_DOMAIN} accounts found. Nothing to delete.`);
    return;
  }

  console.log(`Found ${seedUsers.length} seed account(s):`);
  for (const user of seedUsers) console.log(`  - ${user.email}`);

  if (!confirmed) {
    console.log("\nDry run only — nothing was deleted. Re-run with --confirm to delete them.");
    return;
  }

  let deleted = 0;
  for (const user of seedUsers) {
    try {
      const files = await removeAvatarFolder(supabase, user.id);
      const { error } = await supabase.auth.admin.deleteUser(user.id);
      if (error) throw error;
      deleted++;
      console.log(`  ✓ ${user.email}${files ? ` (+${files} avatar file${files === 1 ? "" : "s"})` : ""}`);
    } catch (error) {
      console.error(`  ✖ ${user.email}: ${error.message ?? error}`);
    }
  }

  console.log(`\nDeleted ${deleted} of ${seedUsers.length} seed account(s).`);
  if (deleted < seedUsers.length) process.exit(1);
}

main().catch((error) => {
  console.error(error.message ?? error);
  process.exit(1);
});
