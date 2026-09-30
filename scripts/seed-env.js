/**
 * Shared setup for the seed / maintenance scripts in this folder.
 *
 * Admin credentials come from `.env.seed.local` (git-ignored by `.env*.local`),
 * NOT from `.env`. `.env` holds the app's public EXPO_PUBLIC_ values, which get
 * bundled into the app; the service key must never sit next to them.
 *
 *   # .env.seed.local — used only by scripts/*.js, never by the app
 *   SUPABASE_URL=https://<dev-project-ref>.supabase.co
 *   SUPABASE_SERVICE_ROLE_KEY=<that project's service_role / secret key>
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

// Legacy service_role keys are JWTs whose payload names the project ("ref").
// New sb_secret_ keys don't, so this only catches the legacy kind.
function jwtProjectRef(key) {
  const parts = String(key).split(".");
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")).ref ?? null;
  } catch {
    return null;
  }
}

function fail(message) {
  console.error(`\n✖ ${message}\n`);
  process.exit(1);
}

/**
 * Returns { url, serviceKey } for the target project, or exits with code 1:
 * missing file / values, or the target is production without the flag.
 * Shell variables with the same names override the file (handy for CI).
 */
function loadSeedEnv() {
  const fileVars = parseEnvFile(path.join(ROOT, SEED_ENV_FILE));
  const url = process.env.SUPABASE_URL || fileVars.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || fileVars.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceKey) {
    fail(
      `Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.\n` +
        `  Put both in ${SEED_ENV_FILE} at the project root (it's git-ignored):\n` +
        `    SUPABASE_URL=https://<dev-project-ref>.supabase.co\n` +
        `    SUPABASE_SERVICE_ROLE_KEY=<the DEV project's service key>\n` +
        `  Get the key from the Supabase dashboard: Project Settings -> API keys.\n` +
        `  Never prefix it EXPO_PUBLIC_, never put it in .env, never commit it.`
    );
  }

  const isProduction = url.includes(PRODUCTION_REF) || jwtProjectRef(serviceKey) === PRODUCTION_REF;
  if (isProduction && !process.argv.includes(PRODUCTION_FLAG)) {
    fail(
      `Refusing to run: ${SEED_ENV_FILE} points at the PRODUCTION project (${PRODUCTION_REF}).\n` +
        `  Seed and maintenance scripts are for the dev project. Point SUPABASE_URL and\n` +
        `  SUPABASE_SERVICE_ROLE_KEY at the dev project instead.\n` +
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
