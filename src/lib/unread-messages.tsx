import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';

import { useAuth } from '@/lib/auth';
import { getTotalUnreadCount, subscribeToInboxMessages } from '@/lib/messages';

type UnreadMessagesContextValue = {
  unreadCount: number;
  refreshUnreadCount: () => Promise<void>;
};

const UnreadMessagesContext = createContext<UnreadMessagesContextValue | undefined>(undefined);

export function UnreadMessagesProvider({ children }: { children: ReactNode }) {
  const { session, needsMfaCode } = useAuth();
  // Nothing to load until the two-step code is entered: the database
  // refuses it (mfa_required). The effects below rerun once it is.
  const userId = needsMfaCode ? null : (session?.user.id ?? null);
  // Remembered with whose count it is, so a different account (or signing
  // out) never shows the previous account's number.
  const [unread, setUnread] = useState<{ userId: string; count: number } | null>(null);
  const unreadCount = unread && unread.userId === userId ? unread.count : 0;

  const refreshUnreadCount = useCallback(async () => {
    if (!userId) return;
    const count = await getTotalUnreadCount();
    setUnread({ userId, count });
  }, [userId]);

  useEffect(() => {
    if (!userId) return;
    getTotalUnreadCount().then((count) => setUnread({ userId, count }));
  }, [userId]);

  useEffect(() => {
    if (!userId) return;
    // Any insert anywhere could change the total (a new message for us, or
    // one in a conversation we're not currently looking at) — refetching
    // the real count from the database is simpler and safer than trying to
    // increment/decrement it locally and risking it drifting from the
    // actual read/unread state.
    const unsubscribe = subscribeToInboxMessages(() => {
      void refreshUnreadCount();
    });
    return unsubscribe;
  }, [userId, refreshUnreadCount]);

  return (
    <UnreadMessagesContext.Provider value={{ unreadCount, refreshUnreadCount }}>
      {children}
    </UnreadMessagesContext.Provider>
  );
}

export function useUnreadMessages() {
  const context = useContext(UnreadMessagesContext);
  if (!context) {
    throw new Error('useUnreadMessages must be used inside an UnreadMessagesProvider');
  }
  return context;
}
