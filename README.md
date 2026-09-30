# Welcome to your Expo app 👋

This is an [Expo](https://expo.dev) project created with [`create-expo-app`](https://www.npmjs.com/package/create-expo-app).

## Get started

1. Install dependencies

   ```bash
   npm install
   ```

2. Start the app

   ```bash
   npx expo start
   ```

   `npm start` (rather than `npx expo start`) also runs `scripts/check-env.js` first, which stops
   if a service/secret key has an `EXPO_PUBLIC_` name. Pass Expo flags after `--`, e.g.
   `npm start -- --go --tunnel -c`.

In the output, you'll find options to open the app in a

- [development build](https://docs.expo.dev/develop/development-builds/introduction/)
- [Android emulator](https://docs.expo.dev/workflow/android-studio-emulator/)
- [iOS simulator](https://docs.expo.dev/workflow/ios-simulator/)
- [Expo Go](https://expo.dev/go), a limited sandbox for trying out app development with Expo

You can start developing by editing the files inside the **app** directory. This project uses [file-based routing](https://docs.expo.dev/router/introduction).

## Supabase: dev vs. production

There are two Supabase projects. **Use dev for everything except a real release.**

| | Dev | Production |
|---|---|---|
| Project ref | `ojrtebubjvkhpiryilum` | `fhevoocpcnrjxyjvitai` |
| Link the CLI | `npm run db:link` (same as `db:link:dev`) | `npm run db:link:prod` |
| Use it for | trying migrations, running `supabase/tests/*.sql`, seed data | real users; migrations only once they've passed on dev |

- `npx supabase db push`, `db:diff` and `db query --linked` all act on **whichever project is
  linked**. Check which one before running them: `cat supabase/.temp/project-ref`.
- Link production only to push a migration that already passed on dev, then run
  `npm run db:link` to go straight back to dev.

### Where each key lives

Supabase gives each project two kinds of key (Project Settings → API Keys). The legacy JWT keys
(`anon`, `service_role`) aren't used anywhere and can be switched off.

| Key | Safe to ship? | Lives in | Used by |
|---|---|---|---|
| **Publishable** `sb_publishable_...` | Yes (it only grants what RLS allows) | `.env` as `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, and **EAS environment variables** (same name) for builds | the app |
| **Secret** `sb_secret_...` | **Never** (bypasses RLS) | `.env.seed.local` as `SUPABASE_SECRET_KEY` (dev project only) | `scripts/*` (seed and clean-up) |
| Secret, for Edge Functions | Never | nowhere in this repo: Supabase injects `SUPABASE_SECRET_KEYS` into every function automatically | `supabase/functions/delete-account` (via `@supabase/server`) |

- `.env` holds **only** `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
  Everything named `EXPO_PUBLIC_*` is compiled into the app, where anyone can read it.
- `npm run check-env` (also run by `npm start` / `npm run build`) fails if any `EXPO_PUBLIC_`
  value is a secret key or a `service_role` JWT.
- The seed scripts only accept `sb_secret_` keys, not legacy `service_role` JWTs.

**Seed data** (fake users for the Web Map) goes to dev only:

1. Create `.env.seed.local` at the project root (git-ignored), with the **dev** project's values:
   ```
   SUPABASE_URL=https://<dev-project-ref>.supabase.co
   SUPABASE_SECRET_KEY=sb_secret_...
   ```
2. `npm run seed:map` (dry run), then `npm run seed:map -- --confirm`.
3. Clean up with `npm run seed:delete` (dry run), then `npm run seed:delete -- --confirm`.

Every seed script refuses to run if `.env.seed.local` points at production, unless you add
`--i-know-this-is-production`. The secret key never goes in `.env`: that file is only for the
app's public `EXPO_PUBLIC_` values, which ship inside the app.

## Get a fresh project

When you're ready, run:

```bash
npm run reset-project
```

This command will move the starter code to the **app-example** directory and create a blank **app** directory where you can start developing.

### Other setup steps

- To set up ESLint for linting, run `npx expo lint`, or follow our guide on ["Using ESLint and Prettier"](https://docs.expo.dev/guides/using-eslint/)
- If you'd like to set up unit testing, follow our guide on ["Unit Testing with Jest"](https://docs.expo.dev/develop/unit-testing/)
- Learn more about the TypeScript setup in this template in our guide on ["Using TypeScript"](https://docs.expo.dev/guides/typescript/)

## Learn more

To learn more about developing your project with Expo, look at the following resources:

- [Expo documentation](https://docs.expo.dev/): Learn fundamentals, or go into advanced topics with our [guides](https://docs.expo.dev/guides).
- [Learn Expo tutorial](https://docs.expo.dev/tutorial/introduction/): Follow a step-by-step tutorial where you'll create a project that runs on Android, iOS, and the web.

## Join the community

Join our community of developers creating universal apps.

- [Expo on GitHub](https://github.com/expo/expo): View our open source platform and contribute.
- [Discord community](https://chat.expo.dev): Chat with Expo users and ask questions.
