#!/usr/bin/env node

/**
 * Checks the "Looking For" tag config (LookingForTags in
 * src/lib/looking-for.ts) against the database's list
 * (public.looking_for_tag_pairs() in the newest migration that defines it),
 * and checks the pairing rules themselves:
 *   - both sides have the same tags with the same partner;
 *   - every pair goes both ways (hiring <-> open_to_work), and a tag that
 *     pairs with itself (looking_for_partners) is allowed;
 *   - every tag has a label and reason-line phrases;
 *   - the 3-tag limit and the 90-day stale window match the database.
 * The database rejects unknown tags, so drift means save errors.
 *
 * Usage: npm run check:looking-for
 */

const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const configFile = path.join(root, "src/lib/looking-for.ts");
const migrationsDir = path.join(root, "supabase/migrations");

// The newest migration whose text defines `fnName`, and that text.
function newestDefinition(fnName) {
  const files = fs.readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort().reverse();
  const definition = new RegExp(`create\\s+(or\\s+replace\\s+)?function\\s+public\\.${fnName}\\(`, "i");
  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), "utf8");
    const found = definition.exec(sql);
    if (found) return { file, sql, start: found.index };
  }
  throw new Error(`No migration defines public.${fnName}()`);
}

// The body of the function starting at `start`: between the first two $$.
function functionBody(sql, start) {
  const open = sql.indexOf("$$", start);
  const close = sql.indexOf("$$", open + 2);
  return sql.slice(open + 2, close);
}

const errors = [];
const fail = (message) => errors.push(message);

// ---- the app's config ----
const config = fs.readFileSync(configFile, "utf8");
const appTags = [...config.matchAll(/\{\s*key:\s*'([a-z_]+)',\s*label:\s*'([^']+)',\s*pairsWith:\s*'([a-z_]+)',\s*theyPhrase:\s*(['"])(.+?)\4,\s*youPhrase:\s*(['"])(.+?)\6\s*\}/g)].map(
  (m) => ({ key: m[1], label: m[2], pairsWith: m[3], theyPhrase: m[5], youPhrase: m[7] }),
);
const typeKeys = [
  ...(config.match(/export type LookingForTag =([\s\S]*?);/)?.[1] ?? "").matchAll(/'([a-z_]+)'/g),
].map((m) => m[1]);
const appLimit = Number(config.match(/export const LookingForLimit = (\d+);/)?.[1]);
const appStaleDays = Number(config.match(/export const LookingForStaleDays = (\d+);/)?.[1]);

if (appTags.length === 0) fail("Couldn't read LookingForTags from src/lib/looking-for.ts");

// ---- the database ----
const pairsDef = newestDefinition("looking_for_tag_pairs");
const dbPairs = [...functionBody(pairsDef.sql, pairsDef.start).matchAll(/\('([a-z_]+)',\s*'([a-z_]+)'\)/g)].map(
  (m) => ({ key: m[1], pairsWith: m[2] }),
);
const validDef = newestDefinition("profile_looking_for_valid");
const dbLimit = Number(functionBody(validDef.sql, validDef.start).match(/cardinality\(p_tags\)\s*<=\s*(\d+)/)?.[1]);
const freshDef = newestDefinition("looking_for_is_fresh");
const dbStaleDays = Number(functionBody(freshDef.sql, freshDef.start).match(/interval\s+'(\d+)\s+days'/)?.[1]);

// ---- compare ----
const appMap = new Map(appTags.map((t) => [t.key, t]));
const dbMap = new Map(dbPairs.map((t) => [t.key, t.pairsWith]));

for (const tag of appTags) {
  if (!dbMap.has(tag.key)) fail(`${tag.key}: in the app but not in ${pairsDef.file}`);
  else if (dbMap.get(tag.key) !== tag.pairsWith)
    fail(`${tag.key}: pairs with ${tag.pairsWith} in the app but ${dbMap.get(tag.key)} in the database`);
}
for (const key of dbMap.keys()) {
  if (!appMap.has(key)) fail(`${key}: in ${pairsDef.file} but not in the app`);
}
if (appTags.length !== new Set(appTags.map((t) => t.key)).size) fail("A tag appears twice in the app config");
if (dbPairs.length !== dbMap.size) fail("A tag appears twice in the database list");
for (const key of typeKeys) if (!appMap.has(key)) fail(`${key}: in the LookingForTag type but not in LookingForTags`);
for (const key of appMap.keys()) if (!typeKeys.includes(key)) fail(`${key}: in LookingForTags but not in the LookingForTag type`);

// ---- pairing rules ----
for (const tag of appTags) {
  const partner = appMap.get(tag.pairsWith);
  if (!partner) fail(`${tag.key} pairs with unknown tag ${tag.pairsWith}`);
  else if (partner.pairsWith !== tag.key)
    fail(`${tag.key} -> ${tag.pairsWith}, but ${tag.pairsWith} -> ${partner.pairsWith} (pairs must go both ways)`);
  if (!tag.label.trim() || !tag.theyPhrase.trim() || !tag.youPhrase.trim())
    fail(`${tag.key}: missing label or reason phrase`);
}

if (appLimit !== dbLimit) fail(`Tag limit: app ${appLimit}, database ${dbLimit}`);
if (appStaleDays !== dbStaleDays) fail(`Stale window: app ${appStaleDays} days, database ${dbStaleDays} days`);

if (errors.length) {
  console.error(`✗ Looking For tags (app: src/lib/looking-for.ts, database: ${pairsDef.file})`);
  for (const message of errors) console.error(`  ${message}`);
  process.exit(1);
}

const symmetric = appTags.filter((t) => t.pairsWith === t.key).map((t) => t.key);
console.log(
  `✓ Looking For tags: app and ${pairsDef.file} match (${appTags.length} tags, ` +
    `every pair goes both ways; self-pairing: ${symmetric.join(", ") || "none"}; ` +
    `limit ${appLimit}; stale after ${appStaleDays} days)`,
);
