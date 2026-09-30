import { useEffect, useRef, useState } from 'react';

import {
  createConnectToken,
  friendlyConnectError,
  getConnectTokenStatus,
  LOCATION_MESSAGE,
  RATE_LIMITED_MESSAGE,
  type ConnectFix,
  type InPersonMatch,
} from '@/lib/connect/api';

// Server-side lifetime (create_connect_token: 30 s). A code that just
// rotated off screen can still be scanned until then, so it keeps getting
// polled.
const TOKEN_LIFETIME_MS = 30_000;
// Rotate a little before the code expires, so the one on screen always has
// a few seconds left for a scan that's already in progress.
export const TOKEN_ROTATE_MS = 25_000;
const POLL_MS = 1000;
const RETRY_MS = 5000;

type LiveToken = { token: string; expiresAt: number };

// Shows a fresh QR code: creates one on start, every 25 s, and right after
// each scan. Each code carries the owner's latest location (`fix`); the
// server only lets someone nearby redeem it (security item H2). Polls the
// codes that can still be scanned and calls onMatched when one is used, so
// the code owner sees the match card too.
//
// Pass active=false when the screen isn't focused, the app is in the
// background, or there's no location yet; everything stops until it's true.
export function useRotatingToken({
  active,
  fix,
  onMatched,
}: {
  active: boolean;
  fix: ConnectFix | null;
  onMatched: (match: InPersonMatch) => void;
}) {
  const [token, setToken] = useState<string | null>(null);
  // When the on-screen code will next rotate (for the countdown bar).
  const [rotatesAt, setRotatesAt] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  const onMatchedRef = useRef(onMatched);
  useEffect(() => {
    onMatchedRef.current = onMatched;
  }, [onMatched]);

  // The newest fix, read at each rotation without restarting the loop.
  const fixRef = useRef(fix);
  useEffect(() => {
    fixRef.current = fix;
  }, [fix]);

  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    let live: LiveToken[] = [];
    let rotateTimer: ReturnType<typeof setTimeout> | undefined;
    let pollTimer: ReturnType<typeof setTimeout> | undefined;

    async function rotate() {
      clearTimeout(rotateTimer);
      try {
        const result = await createConnectToken(fixRef.current);
        if (cancelled) return;
        if (result.kind !== 'ok') {
          if (result.kind === 'rate_limited') {
            // The code on screen (if any) is still valid for a while; retry soon.
            setError(RATE_LIMITED_MESSAGE);
            rotateTimer = setTimeout(rotate, RETRY_MS * 2);
          } else {
            // No usable location: nothing scannable to show until there is one.
            setToken(null);
            setError(LOCATION_MESSAGE[result.kind]);
            rotateTimer = setTimeout(rotate, RETRY_MS);
          }
          return;
        }
        const now = Date.now();
        live = [
          { token: result.token, expiresAt: now + TOKEN_LIFETIME_MS },
          ...live.filter((t) => t.expiresAt > now),
        ].slice(0, 2);
        setToken(result.token);
        setRotatesAt(now + TOKEN_ROTATE_MS);
        setError(null);
        rotateTimer = setTimeout(rotate, TOKEN_ROTATE_MS);
      } catch (e) {
        if (cancelled) return;
        setError(friendlyConnectError(e));
        rotateTimer = setTimeout(rotate, RETRY_MS);
      }
    }

    async function poll() {
      const now = Date.now();
      live = live.filter((t) => t.expiresAt > now);
      for (const { token: code } of live) {
        try {
          const status = await getConnectTokenStatus(code);
          if (cancelled) return;
          if (status.kind === 'used' || status.kind === 'expired' || status.kind === 'not_found') {
            live = live.filter((t) => t.token !== code);
          }
          if (status.kind === 'used') {
            if (status.match) onMatchedRef.current(status.match);
            // That code is spent; put a fresh one up for the next person.
            void rotate();
            break;
          }
        } catch {
          // Transient network blip; the next poll retries.
        }
      }
      if (!cancelled) pollTimer = setTimeout(poll, POLL_MS);
    }

    void rotate();
    pollTimer = setTimeout(poll, POLL_MS);

    return () => {
      cancelled = true;
      clearTimeout(rotateTimer);
      clearTimeout(pollTimer);
      // Don't flash a possibly-expired code when it becomes active again.
      setToken(null);
      setRotatesAt(null);
    };
  }, [active]);

  return { token, rotatesAt, error };
}
