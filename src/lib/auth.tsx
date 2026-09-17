import type { Session } from '@supabase/supabase-js';
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';

import { supabase } from '@/lib/supabase';
import type { Profile } from '@/lib/types';

type AuthContextValue = {
  session: Session | null;
  profile: Profile | null;
  isLoading: boolean;
  refreshProfile: () => Promise<void>;
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

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(async ({ data }) => {
      setSession(data.session);
      if (data.session) {
        setProfile(await fetchProfile(data.session.user.id));
      }
      setIsLoading(false);
    });

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(async (_event, newSession) => {
      setSession(newSession);
      if (newSession) {
        setIsLoading(true);
        setProfile(await fetchProfile(newSession.user.id));
        setIsLoading(false);
      } else {
        setProfile(null);
      }
    });

    return () => subscription.unsubscribe();
  }, []);

  async function refreshProfile() {
    if (!session) return;
    setProfile(await fetchProfile(session.user.id));
  }

  return (
    <AuthContext.Provider value={{ session, profile, isLoading, refreshProfile }}>
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
