#!/usr/bin/env node

/**
 * Fails (exit 1) if a secret looks like it's about to ship in the app.
 * The app should only ever have the publishable key
 * (EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...).
 *
 * Anything named EXPO_PUBLIC_* is compiled into the app bundle, where anyone
 * can read it. This checks every EXPO_PUBLIC_ variable in .env, every .env.*
 * file at the project root, and the current process environment, and fails
 * if its name or value contains "service", "secret" or "sb_secret_", or if
 * its value is a Supabase JWT whose role is service_role (legacy service keys
 * don't spell "service" in the raw string).
 *
 * Runs automatically before `npm start` and `npm run build` (prestart /
 * prebuild). Run by hand: npm run check-env
 *
 * Only file and variable NAMES are printed, never values.
 */

const fs = require("fs");
const path = require("path");
const { parseEnvFile } = require("./seed-env");

const ROOT = path.resolve(__dirname, "..");
const PUBLIC_PREFIX = "EXPO_PUBLIC_";
const FORBIDDEN = ["service", "secret", "sb_secret_"];

function jwtRole(value) {
  const parts = String(value).split(".");
  if (parts.length !== 3) return null;
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")).role ?? null;
  } catch {
    return null;
  }
}

// Why this variable is unsafe, or null if it's fine. The two exact key
// checks come first so the message says precisely what leaked.
function problem(name, value) {
  if (String(value ?? "").startsWith("sb_secret_")) return "value is a Supabase secret key (sb_secret_...)";
  if (jwtRole(value) === "service_role") return "value is a service_role key";
  const lowerName = name.toLowerCase();
  const lowerValue = String(value ?? "").toLowerCase();
  for (const word of FORBIDDEN) {
    if (lowerName.includes(word)) return `name contains "${word}"`;
    if (lowerValue.includes(word)) return `value contains "${word}"`;
  }
  return null;
}

const sources = fs
  .readdirSync(ROOT)
  .filter((file) => file === ".env" || file.startsWith(".env."))
  .filter((file) => fs.statSync(path.join(ROOT, file)).isFile())
  .map((file) => ({ label: file, vars: parseEnvFile(path.join(ROOT, file)) }));
sources.push({ label: "process.env", vars: process.env });

const findings = [];
for (const { label, vars } of sources) {
  for (const [name, value] of Object.entries(vars)) {
    if (!name.startsWith(PUBLIC_PREFIX)) continue;
    const why = problem(name, value);
    if (why) findings.push(`${label}: ${name} (${why})`);
  }
}

if (findings.length > 0) {
  console.error("\n✖ check-env: a secret looks like it would ship in the app bundle.\n");
  for (const finding of findings) console.error(`  - ${finding}`);
  console.error(
    `\n  ${PUBLIC_PREFIX}* variables are public: they're compiled into the app.\n` +
      "  Service/secret keys belong in .env.seed.local (scripts only) or the Edge\n" +
      "  Function environment, never with an EXPO_PUBLIC_ prefix.\n"
  );
  process.exit(1);
}

console.log(`check-env: OK (${sources.map((s) => s.label).join(", ")})`);
