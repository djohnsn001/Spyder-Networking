// https://docs.expo.dev/guides/using-eslint/
const { defineConfig } = require('eslint/config');
const expoConfig = require("eslint-config-expo/flat");

module.exports = defineConfig([
  expoConfig,
  {
    // supabase/functions is Deno code (npm: imports), not part of the app.
    ignores: ["dist/*", ".expo/*", "supabase/functions/*"],
  },
  {
    // Seed and helper scripts run in Node, not in the app.
    files: ["scripts/**/*.js"],
    languageOptions: {
      globals: { __dirname: "readonly", __filename: "readonly", Buffer: "readonly" },
    },
  },
]);
