import type { Factor, Session } from '@supabase/supabase-js';

import { callRpc } from '@/lib/rpc';
import { supabase } from '@/lib/supabase';

// Two-step verification (TOTP: 6-digit codes from an authenticator app) via
// Supabase Auth MFA. Available to everyone; required for admins, because
// is_admin() only counts sessions at 'aal2' (security item H4).
//
// aal1 = signed in with a password; aal2 = also entered a code this session.

export type AssuranceState = {
  // Has a verified factor but hasn't entered a code in this session.
  needsCode: boolean;
  currentLevel: string | null;
};

function jwtClaim(token: string, claim: string): unknown {
  try {
    const payload = token.split('.')[1] ?? '';
    const base64 = payload.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')))[claim];
  } catch {
    return undefined;
  }
}

// The same answer as getAuthenticatorAssuranceLevel(), worked out from the
// session itself: the access token's `aal` claim, and whether the user has a
// verified factor. Used inside onAuthStateChange, where calling other
// supabase.auth methods can deadlock.
export function assuranceFromSession(session: Session): AssuranceState {
  const currentLevel = (jwtClaim(session.access_token, 'aal') as string | undefined) ?? null;
  const hasVerifiedFactor = (session.user.factors ?? []).some((f) => f.status === 'verified');
  return { needsCode: hasVerifiedFactor && currentLevel !== 'aal2', currentLevel };
}

export async function getAssurance(): Promise<AssuranceState> {
  const { data, error } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (error || !data) {
    if (__DEV__ && error) console.warn('[mfa] assurance level failed', error);
    return { needsCode: false, currentLevel: null };
  }
  return {
    needsCode: data.nextLevel === 'aal2' && data.currentLevel !== 'aal2',
    currentLevel: data.currentLevel,
  };
}

// Verified authenticator-app factors (what Settings lists).
export async function listTotpFactors(): Promise<Factor[]> {
  const { data, error } = await supabase.auth.mfa.listFactors();
  if (error) throw error;
  return data?.totp ?? [];
}

export type TotpEnrollment = {
  factorId: string;
  secret: string;
  // otpauth://... — the QR code encodes this, and authenticator apps open it.
  uri: string;
};

// Starts adding an authenticator app. Clears any earlier set-up that was never
// finished first, so an abandoned attempt can't block a new one.
export async function startTotpEnrollment(): Promise<TotpEnrollment> {
  const { data: factors, error: listError } = await supabase.auth.mfa.listFactors();
  if (listError) throw listError;
  for (const factor of factors?.all ?? []) {
    if (factor.factor_type === 'totp' && factor.status === 'unverified') {
      await supabase.auth.mfa.unenroll({ factorId: factor.id });
    }
  }

  const { data, error } = await supabase.auth.mfa.enroll({
    factorType: 'totp',
    // Must be unique among the user's factors.
    friendlyName: `Authenticator app (${new Date().toISOString().slice(0, 10)} ${Date.now() % 10000})`,
    issuer: 'Bolas',
  });
  if (error) throw error;
  return { factorId: data.id, secret: data.totp.secret, uri: data.totp.uri };
}

// Checks a 6-digit code. On success the session becomes aal2 (Supabase emits
// MFA_CHALLENGE_VERIFIED, and the auth provider re-checks).
export async function verifyTotpCode(factorId: string, code: string): Promise<'ok' | 'wrong_code'> {
  const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId, code: code.trim() });
  if (!error) return 'ok';
  if (__DEV__) console.warn('[mfa] verify failed', error);
  if (/invalid|expired|code/i.test(error.message ?? '')) return 'wrong_code';
  throw error;
}

// Removes an authenticator app, then refreshes the session so its level drops
// right away (otherwise it stays aal2 until the next token refresh).
export async function removeTotpFactor(factorId: string) {
  const { error } = await supabase.auth.mfa.unenroll({ factorId });
  if (error) throw error;
  await supabase.auth.refreshSession();
}

export type AdminStatus = { isAdmin: boolean; needsMfa: boolean };

// { is_admin: admin AND aal2, needs_mfa: admin but only aal1 }.
export async function getMyAdminStatus(): Promise<AdminStatus> {
  const raw = await callRpc<{ is_admin?: boolean; needs_mfa?: boolean }>('get_my_admin_status');
  return { isAdmin: raw?.is_admin === true, needsMfa: raw?.needs_mfa === true };
}
