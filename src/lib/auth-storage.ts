import AsyncStorage from '@react-native-async-storage/async-storage';
import * as aesjs from 'aes-js';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import { Platform } from 'react-native';

// Where Supabase keeps the signed-in session (including the refresh token,
// which can mint new logins). Security item M1.
//
// Native: encrypted, following Supabase's React Native guide. A random
// AES-256 key lives in SecureStore (iOS Keychain / Android Keystore); the
// session is encrypted with it and saved in AsyncStorage, because SecureStore
// can reject values over ~2 KB and a session is bigger than that. Anyone who
// copies the app's files gets only ciphertext.
//
// Two changes from the guide's sample:
// - One long-lived key plus a fresh random IV per write, instead of a new key
//   per write. The guide writes the key and the data separately, so an app
//   killed between the two writes leaves data nobody can decrypt (a surprise
//   logout). Here each save is a single AsyncStorage write.
// - Randomness comes from expo-crypto's getRandomBytesAsync (always the
//   native secure generator) instead of a global polyfill.
//
// Web keeps plain AsyncStorage (localStorage): SecureStore doesn't exist
// there.

const KEY_NAME = 'bolas.auth-storage-key';
// Marks an encrypted value. A plain session saved before this update is JSON,
// so it never starts with this.
const ENCRYPTED_PREFIX = 'bolas-enc-v1:';
const IV_HEX_LENGTH = 32; // 16 bytes

// THIS_DEVICE_ONLY: the key never moves to another phone through an iCloud
// or iTunes backup, so a restored backup can't be used to sign in (the user
// just logs in again). Android's SecureStore is already left out of backups.
const SECURE_STORE_OPTIONS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
};

// Kept in memory after the first read, so token refreshes while the app is
// running never depend on the Keychain being readable at that moment.
let cachedKey: Uint8Array | null = null;

async function loadKey(createIfMissing: boolean): Promise<Uint8Array | null> {
  if (cachedKey) return cachedKey;
  const stored = await SecureStore.getItemAsync(KEY_NAME, SECURE_STORE_OPTIONS);
  if (stored) {
    cachedKey = aesjs.utils.hex.toBytes(stored);
    return cachedKey;
  }
  if (!createIfMissing) return null;
  const key = await Crypto.getRandomBytesAsync(32);
  await SecureStore.setItemAsync(KEY_NAME, aesjs.utils.hex.fromBytes(key), SECURE_STORE_OPTIONS);
  cachedKey = key;
  return key;
}

async function encrypt(value: string): Promise<string> {
  const key = await loadKey(true);
  const iv = await Crypto.getRandomBytesAsync(16);
  const cipher = new aesjs.ModeOfOperation.ctr(key!, new aesjs.Counter(iv));
  const encrypted = cipher.encrypt(aesjs.utils.utf8.toBytes(value));
  return ENCRYPTED_PREFIX + aesjs.utils.hex.fromBytes(iv) + aesjs.utils.hex.fromBytes(encrypted);
}

function decrypt(key: Uint8Array, stored: string): string | null {
  const body = stored.slice(ENCRYPTED_PREFIX.length);
  const iv = aesjs.utils.hex.toBytes(body.slice(0, IV_HEX_LENGTH));
  const cipher = new aesjs.ModeOfOperation.ctr(key, new aesjs.Counter(iv));
  const value = aesjs.utils.utf8.fromBytes(
    cipher.decrypt(aesjs.utils.hex.toBytes(body.slice(IV_HEX_LENGTH))),
  );
  // Supabase only ever stores JSON; anything else was encrypted with a key
  // we no longer have.
  try {
    JSON.parse(value);
    return value;
  } catch {
    return null;
  }
}

// Runs storage calls one at a time. Otherwise a slow first-launch migration
// could finish after a token refresh and overwrite the new session with the
// old one.
let queue: Promise<unknown> = Promise.resolve();
function serialized<T>(task: () => Promise<T>): Promise<T> {
  const run = queue.then(task, task);
  queue = run.catch(() => undefined);
  return run;
}

const encryptedStorage = {
  getItem: (name: string) =>
    serialized(async () => {
      const stored = await AsyncStorage.getItem(name);
      if (stored === null) return null;

      if (!stored.startsWith(ENCRYPTED_PREFIX)) {
        // First launch after the update: a plain session from the old
        // version. Encrypt it in place (the same AsyncStorage entry, so the
        // plain copy is overwritten) and keep the user signed in.
        await AsyncStorage.setItem(name, await encrypt(stored));
        return stored;
      }

      // If the Keychain can't be read right now this throws, and the
      // encrypted session is left alone for next time.
      const key = await loadKey(false);
      const value = key ? decrypt(key, stored) : null;
      if (value === null) {
        // The key is gone (e.g. a backup restored onto a new phone), so this
        // can never be decrypted. Clear it; the user signs in again.
        await AsyncStorage.removeItem(name);
      }
      return value;
    }),

  setItem: (name: string, value: string) =>
    serialized(async () => {
      await AsyncStorage.setItem(name, await encrypt(value));
    }),

  removeItem: (name: string) =>
    serialized(async () => {
      await AsyncStorage.removeItem(name);
    }),
};

export const authStorage = Platform.OS === 'web' ? AsyncStorage : encryptedStorage;
