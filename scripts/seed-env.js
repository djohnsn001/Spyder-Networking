/**
 * Shared setup for the seed / maintenance scripts in this folder.
 *
 * Admin credentials come from `.env.seed.local` (git-ignored by `.env*.local`),
 * NOT from `.env`. `.env` holds the app's public EXPO_PUBLIC_ values, which get
 * bundled into the app; the service key must never sit next to them.
 *
 *   # .env.seed.local — used only by scripts/*.js, never by the app
 *   SUPABASE_URL=https://<dev-project-ref>.supabase.co
 *   SUPABASE_SECRET_KEY=sb_secret_...   (that project's secret key)
 *
 * Only new-style secret keys (sb_secret_...) are accepted, not the legacy
 * service_role JWT, so the legacy keys can be switched off (item H3).
 *
 * Every script calls loadSeedEnv() before doing anything, which refuses to
 * run against the production project unless the command includes
 * --i-know-this-is-production.
 */

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SEED_ENV_FILE = ".env.seed.local";
const PRODUCTION_REF = "fhevoocpcnrjxyjvitai";
const PRODUCTION_FLAG = "--i-know-this-is-production";

// KEY=VALUE lines; ignores blanks, comments, and an optional "export ".
function parseEnvFile(filePath) {
  const vars = {};
  if (!fs.existsSync(filePath)) return vars;
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const trimmed = line.trim().replace(/^export\s+/, "");
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
  return vars;
}

function fail(message) {
  console.error(`\n✖ ${message}\n`);
  process.exit(1);
}

/**
 * Returns { url, serviceKey } for the target project, or exits with code 1:
 * missing file / values, a key that isn't sb_secret_..., or the target is
 * production without the flag. Shell variables with the same names override
 * the file (handy for CI).
 */
function loadSeedEnv() {
  const fileVars = parseEnvFile(path.join(ROOT, SEED_ENV_FILE));
  const url = process.env.SUPABASE_URL || fileVars.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY || fileVars.SUPABASE_SECRET_KEY;
  const legacyKeySet = Boolean(process.env.SUPABASE_SERVICE_ROLE_KEY || fileVars.SUPABASE_SERVICE_ROLE_KEY);

  if (!url || !serviceKey) {
    fail(
      `Missing SUPABASE_URL or SUPABASE_SECRET_KEY.\n` +
        (legacyKeySet
          ? `  SUPABASE_SERVICE_ROLE_KEY (the legacy JWT) isn't used any more: replace it with\n` +
            `  SUPABASE_SECRET_KEY=sb_secret_... (Supabase dashboard -> Project Settings -> API Keys).\n`
          : "") +
        `  Put both in ${SEED_ENV_FILE} at the project root (it's git-ignored):\n` +
        `    SUPABASE_URL=https://<dev-project-ref>.supabase.co\n` +
        `    SUPABASE_SECRET_KEY=sb_secret_...   (the DEV project's secret key)\n` +
        `  Never prefix it EXPO_PUBLIC_, never put it in .env, never commit it.`
    );
  }

  // Secret keys only; the legacy service_role JWTs are being switched off.
  if (!serviceKey.startsWith("sb_secret_")) {
    fail(
      `SUPABASE_SECRET_KEY must be a secret key (starts with sb_secret_).\n` +
        `  Legacy service_role JWTs aren't accepted. Create a secret key in the Supabase\n` +
        `  dashboard -> Project Settings -> API Keys.`
    );
  }

  // Secret keys don't say which project they belong to, so the URL decides.
  // (A dev URL with a production key just fails to authenticate.)
  const isProduction = url.includes(PRODUCTION_REF);
  if (isProduction && !process.argv.includes(PRODUCTION_FLAG)) {
    fail(
      `Refusing to run: ${SEED_ENV_FILE} points at the PRODUCTION project (${PRODUCTION_REF}).\n` +
        `  Seed and maintenance scripts are for the dev project. Point SUPABASE_URL and\n` +
        `  SUPABASE_SECRET_KEY at the dev project instead.\n` +
        `  If you really mean production, re-run with ${PRODUCTION_FLAG}.`
    );
  }

  console.log(`Target Supabase project: ${url}${isProduction ? "  ⚠️  PRODUCTION" : ""}`);
  return { url, serviceKey };
}

// Admin client for scripts only: bypasses RLS, never persists a session.
function createAdminClient({ url, serviceKey }) {
  const { createClient } = require("@supabase/supabase-js");
  return createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

module.exports = { loadSeedEnv, createAdminClient, parseEnvFile, PRODUCTION_REF, PRODUCTION_FLAG };
