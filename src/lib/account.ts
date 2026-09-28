import AsyncStorage from '@react-native-async-storage/async-storage';
import { FunctionsHttpError } from '@supabase/supabase-js';

import { supabase } from '@/lib/supabase';

export type DeleteAccountResult =
  | 'deleted'
  | 'confirm_mismatch'
  | 'not_authenticated'
  | 'failed'
  | 'offline';

// Calls the delete-account Edge Function (supabase/functions/delete-account),
// which deletes the photo files and then the account; the database removes
// everything else. `confirm` is the username the person typed.
export async function deleteMyAccount(confirm: string): Promise<DeleteAccountResult> {
  const { data, error } = await supabase.functions.invoke('delete-account', {
    body: { confirm },
  });

  if (!error) return data?.outcome === 'deleted' ? 'deleted' : 'failed';

  if (__DEV__) console.warn('[delete-account] failed', error.name, error.context?.status ?? '');

  if (error instanceof FunctionsHttpError) {
    try {
      const body = await error.context.json();
      if (body?.outcome === 'confirm_mismatch' || body?.outcome === 'not_authenticated') {
        return body.outcome;
      }
    } catch {
      // Not JSON; fall through.
    }
    return 'failed';
  }
  return 'offline';
}

// After the account is gone: forget this account's per-device state and
// drop the (now useless) session on this phone only — the server already
// removed the user, so a normal sign-out would fail.
export async function clearAfterAccountDeletion(userId: string) {
  try {
    const keys = await AsyncStorage.getAllKeys();
    const mine = keys.filter((key) => key.endsWith(`.${userId}`));
    if (mine.length > 0) await AsyncStorage.multiRemove(mine);
  } catch (error) {
    if (__DEV__) console.warn('Failed to clear account storage', error);
  }
  setAuthNotice('Your account was deleted.');
  await supabase.auth.signOut({ scope: 'local' });
}

// A one-time message for the login screen, which shows up on its own when
// the session ends (so there's no navigation call to pass params through).
let pendingAuthNotice: string | null = null;

export function setAuthNotice(message: string) {
  pendingAuthNotice = message;
}

export function takeAuthNotice(): string | null {
  const message = pendingAuthNotice;
  pendingAuthNotice = null;
  return message;
}
