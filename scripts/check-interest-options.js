#!/usr/bin/env node

/**
 * Checks that the interest list in the app (InterestOptions in
 * src/lib/profile-options.ts) matches the database's list
 * (public.profile_interest_options() in the newest migration that defines
 * it). Same for the reserved usernames (ReservedUsernames vs
 * public.username_is_reserved()). The database rejects anything not on its
 * lists, so if they drift apart, people get errors saving their profile.
 *
 * Usage: npm run check:interests
 */

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const optionsFile = path.join(root, "src/lib/profile-options.ts");
const migrationsDir = path.join(root, "supabase/migrations");

// The quoted strings inside the first `opener`...] after `marker`.
function quotedListAfter(text, marker, file, opener = "[") {
  const start = text.indexOf(marker);
  if (start === -1) throw new Error(`Couldn't find "${marker}" in ${file}`);
  const open = text.indexOf(opener, start) + opener.length - 1;
  const close = text.indexOf("]", open);
  return [...text.slice(open + 1, close).matchAll(/'([^']*)'|"([^"]*)"/g)].map((m) => m[1] ?? m[2]);
}

// The newest migration that (re)defines `fnName`, and the list inside it.
// Only `create [or replace] function`: other migrations may grant or revoke
// on the function without changing its list.
function newestMigrationList(fnName) {
  const files = fs.readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
  const definition = new RegExp(`create\\s+(or\\s+replace\\s+)?function\\s+public\\.${fnName}\\(`, "i");
  for (const file of files.reverse()) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), "utf8");
    const found = sql.match(definition);
    if (found) return { file, list: quotedListAfter(sql, found[0], file, "array[") };
  }
  throw new Error(`No migration defines public.${fnName}()`);
}

function compare(label, appList, db) {
  const missingInDb = appList.filter((x) => !db.list.includes(x));
  const missingInApp = db.list.filter((x) => !appList.includes(x));
  if (missingInDb.length === 0 && missingInApp.length === 0) {
    console.log(`✓ ${label}: app and ${db.file} match (${appList.length})`);
    return true;
  }
  console.error(`✗ ${label} differ (app: profile-options.ts, database: ${db.file})`);
  if (missingInDb.length) console.error(`  only in the app: ${missingInDb.join(", ")}`);
  if (missingInApp.length) console.error(`  only in the database: ${missingInApp.join(", ")}`);
  return false;
}

const options = fs.readFileSync(optionsFile, "utf8");
const ok = [
  compare(
    "Interests",
    quotedListAfter(options, "export const InterestOptions", optionsFile),
    newestMigrationList("profile_interest_options"),
  ),
  compare(
    "Reserved usernames",
    quotedListAfter(options, "export const ReservedUsernames", optionsFile),
    newestMigrationList("username_is_reserved"),
  ),
].every(Boolean);

process.exit(ok ? 0 : 1);
