import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';

import { useAuth } from '@/lib/auth';
import { getTotalUnreadCount, subscribeToInboxMessages } from '@/lib/messages';

type UnreadMessagesContextValue = {
  unreadCount: number;
  refreshUnreadCount: () => Promise<void>;
};

const UnreadMessagesContext = createContext<UnreadMessagesContextValue | undefined>(undefined);

export function UnreadMessagesProvider({ children }: { children: ReactNode }) {
  const { session } = useAuth();
  const [unreadCount, setUnreadCount] = useState(0);

  const refreshUnreadCount = useCallback(async () => {
    if (!session) {
      setUnreadCount(0);
      return;
    }
    setUnreadCount(await getTotalUnreadCount());
  }, [session]);

  useEffect(() => {
    void refreshUnreadCount();
  }, [refreshUnreadCount]);

  useEffect(() => {
    if (!session) return;
    // Any insert anywhere could change the total (a new message for us, or
    // one in a conversation we're not currently looking at) — refetching
    // the real count from the database is simpler and safer than trying to
    // increment/decrement it locally and risking it drifting from the
    // actual read/unread state.
    const unsubscribe = subscribeToInboxMessages(() => {
      void refreshUnreadCount();
    });
    return unsubscribe;
  }, [session, refreshUnreadCount]);

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
