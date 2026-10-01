import type { Session } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import { assuranceFromSession, getAssurance } from '@/lib/mfa';
import { OWN_PROFILE_COLUMNS } from '@/lib/profiles';
import { supabase } from '@/lib/supabase';
import type { Profile } from '@/lib/types';

type AuthContextValue = {
  session: Session | null;
  profile: Profile | null;
  // True when the current Terms version hasn't been accepted yet (existing
  // accounts, and everyone after the Terms change). The root layout sends
  // them to legal/accept before anything else.
  needsConsent: boolean;
  // An admin suspended this account (account_restrictions). The root layout
  // shows only the suspended screen, Terms, and Delete account.
  isSuspended: boolean;
  // Two-step verification is on for this account, but no code has been
  // entered in this session (aal1). The root layout shows only the code
  // screen until it is (security item H4).
  needsMfaCode: boolean;
  isLoading: boolean;
  refreshProfile: () => Promise<void>;
  refreshConsent: () => Promise<void>;
  refreshMfa: () => Promise<void>;
};

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

// My own full row. Other people's settings columns (location sharing,
// notifications) aren't readable through the table, so this goes through
// get_my_profile() (20260930000000).
async function fetchProfile() {
  const { data, error } = await supabase
    .rpc('get_my_profile')
    .select(OWN_PROFILE_COLUMNS)
    .maybeSingle<Profile>();
  if (error) {
    console.error('Failed to load profile', error);
    return null;
  }
  return data;
}

// Fails open (false) if the check itself fails, e.g. offline: a network
// blip shouldn't lock someone out. It's asked again on the next sign-in
// or app start.
async function fetchNeedsConsent(): Promise<boolean> {
  const { data, error } = await supabase.rpc('get_my_consent_status');
  if (error) {
    if (__DEV__) console.warn('Failed to load consent status', error);
    return false;
  }
  return Boolean((data as { needs_acceptance?: boolean } | null)?.needs_acceptance);
}

// Suspended accounts can read their own account_restrictions row, and only
// theirs. Fails open like the consent check.
async function fetchIsSuspended(userId: string): Promise<boolean> {
  const { data, error } = await supabase
    .from('account_restrictions')
    .select('user_id')
    .eq('user_id', userId)
    .maybeSingle();
  if (error) {
    if (__DEV__) console.warn('Failed to load account status', error);
    return false;
  }
  return data !== null;
}

type AccountState = { profile: Profile | null; needsConsent: boolean; isSuspended: boolean };

const EMPTY_ACCOUNT: AccountState = { profile: null, needsConsent: false, isSuspended: false };

// Until the two-step code is entered, the database refuses every read
// (mfa_required), so don't ask: it only logs errors. The code screen comes
// first anyway, and this runs again once the code is verified.
async function fetchAccount(userId: string, needsCode: boolean): Promise<AccountState> {
  if (needsCode) return EMPTY_ACCOUNT;
  const [profile, needsConsent, isSuspended] = await Promise.all([
    fetchProfile(),
    fetchNeedsConsent(),
    fetchIsSuspended(userId),
  ]);
  return { profile, needsConsent, isSuspended };
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [needsConsent, setNeedsConsent] = useState(false);
  const [isSuspended, setIsSuspended] = useState(false);
  const [needsMfaCode, setNeedsMfaCode] = useState(false);
  const [isLoading, setIsLoading] = useState(true);

  function applyAccount(account: AccountState) {
    setProfile(account.profile);
    setNeedsConsent(account.needsConsent);
    setIsSuspended(account.isSuspended);
  }

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      if (data.session) {
        const { needsCode } = assuranceFromSession(data.session);
        applyAccount(await fetchAccount(data.session.user.id, needsCode));
        setNeedsMfaCode(needsCode);
      }
      setIsLoading(false);
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(async (_event, newSession) => {
      setSession(newSession);
      if (newSession) {
        setIsLoading(true);
        // Read from the session itself: calling supabase.auth.* inside this
        // callback can deadlock. MFA_CHALLENGE_VERIFIED lands here too, which
        // loads the account and lifts the code screen.
        const { needsCode } = assuranceFromSession(newSession);
        applyAccount(await fetchAccount(newSession.user.id, needsCode));
        setNeedsMfaCode(needsCode);
        setIsLoading(false);
      } else {
        applyAccount(EMPTY_ACCOUNT);
        setNeedsMfaCode(false);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function refreshProfile() {
    if (!session) return;
    setProfile(await fetchProfile());
  }

  async function refreshConsent() {
    if (!session) return;
    setNeedsConsent(await fetchNeedsConsent());
  }

  async function refreshMfa() {
    if (!session) return;
    const { needsCode } = await getAssurance();
    // Code just entered: load the account before lifting the code screen,
    // so the layout doesn't briefly see "no profile" and open onboarding.
    if (!needsCode && needsMfaCode) {
      applyAccount(await fetchAccount(session.user.id, false));
    }
    setNeedsMfaCode(needsCode);
  }

  return (
    <AuthContext.Provider
      value={{
        session,
        profile,
        needsConsent,
        isSuspended,
        needsMfaCode,
        isLoading,
        refreshProfile,
        refreshConsent,
        refreshMfa,
      }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used inside an AuthProvider');
  }
  return context;
}
