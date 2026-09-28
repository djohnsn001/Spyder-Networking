import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';

const supabaseUrl = process.env.EXPO_PUBLIC_SUPABASE_URL;
const supabaseAnonKey = process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'Missing EXPO_PUBLIC_SUPABASE_URL or EXPO_PUBLIC_SUPABASE_ANON_KEY. Check your .env file.',
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

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  global: { fetch: fetchWithClockSkewRetry },
  auth: {
    storage: AsyncStorage,
    autoRefreshToken: true,
    persistSession: true,
    detectSessionInUrl: false,
  },
});
