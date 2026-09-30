import type { Session } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import { assuranceFromSession, getAssurance } from '@/lib/mfa';
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

async function fetchProfile(userId: string) {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .maybeSingle();
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

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [needsConsent, setNeedsConsent] = useState(false);
  const [isSuspended, setIsSuspended] = useState(false);
  const [needsMfaCode, setNeedsMfaCode] = useState(false);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      if (data.session) {
        const [nextProfile, nextNeedsConsent, nextIsSuspended] = await Promise.all([
          fetchProfile(data.session.user.id),
          fetchNeedsConsent(),
          fetchIsSuspended(data.session.user.id),
        ]);
        setProfile(nextProfile);
        setNeedsConsent(nextNeedsConsent);
        setIsSuspended(nextIsSuspended);
        setNeedsMfaCode(assuranceFromSession(data.session).needsCode);
      }
      setIsLoading(false);
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(async (_event, newSession) => {
      setSession(newSession);
      if (newSession) {
        setIsLoading(true);
        const [nextProfile, nextNeedsConsent, nextIsSuspended] = await Promise.all([
          fetchProfile(newSession.user.id),
          fetchNeedsConsent(),
          fetchIsSuspended(newSession.user.id),
        ]);
        setProfile(nextProfile);
        setNeedsConsent(nextNeedsConsent);
        setIsSuspended(nextIsSuspended);
        // Read from the session itself: calling supabase.auth.* inside this
        // callback can deadlock. MFA_CHALLENGE_VERIFIED lands here too, which
        // lifts the code screen.
        setNeedsMfaCode(assuranceFromSession(newSession).needsCode);
        setIsLoading(false);
      } else {
        setProfile(null);
        setNeedsConsent(false);
        setIsSuspended(false);
        setNeedsMfaCode(false);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function refreshProfile() {
    if (!session) return;
    setProfile(await fetchProfile(session.user.id));
  }

  async function refreshConsent() {
    if (!session) return;
    setNeedsConsent(await fetchNeedsConsent());
  }

  async function refreshMfa() {
    if (!session) return;
    setNeedsMfaCode((await getAssurance()).needsCode);
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
