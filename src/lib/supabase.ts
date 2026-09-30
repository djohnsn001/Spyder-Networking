import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';

// The app uses Supabase's PUBLISHABLE key (sb_publishable_...), which is safe
// to ship: it only grants what Row Level Security allows. Never a secret key
// (sb_secret_...) or the legacy anon / service_role JWTs.
const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL;
const supabasePublishableKey = process.env.EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

if (!supabaseUrl || !supabasePublishableKey) {
  const renamed = !supabasePublishableKey && process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;
  throw new Error(
    renamed
      ? 'EXPO_PUBLIC_SUPABASE_ANON_KEY was renamed. In .env, rename it to ' +
          'EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY and set it to the sb_publishable_... key ' +
          '(Supabase dashboard > Project Settings > API Keys), then restart with -c.'
      : 'Missing EXPO_PUBLIC_SUPABASE_URL or EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY ' +
          '(sb_publishable_...). Check your .env file.',
  );
}

// Supabase platform bug: right after sign-in, the database can reject a
// brand-new token with PGRST303 "JWT issued at future" because its clock is
// a second or two behind the auth server's
// (github.com/supabase/supabase/issues/49655). Wait and retry just that
// error, so first-second reads (profile, terms check, unread count) don't
// fail. Everything else passes straight through.
const JWT_FUTURE_RETRIES = 3;
const JWT_FUTURE_DELAY_MS = 1000;

async function isJwtIssuedInFuture(response: Response) {
  if (response.status !== 401) return false;
  try {
    const body = await response.clone().json();
    return body?.code === 'PGRST303';
  } catch {
    return false;
  }
}

const fetchWithClockSkewRetry: typeof fetch = async (input, init) => {
  let response = await fetch(input, init);
  for (let attempt = 0; attempt < JWT_FUTURE_RETRIES; attempt++) {
    if (!(await isJwtIssuedInFuture(response))) break;
    await new Promise((resolve) => setTimeout(resolve, JWT_FUTURE_DELAY_MS));
    response = await fetch(input, init);
  }
  return response;
};

export const supabase = createClient(supabaseUrl, supabasePublishableKey, {
  global: { fetch: fetchWithClockSkewRetry },
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
