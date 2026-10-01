import { supabase } from '@/lib/supabase';

// Calls a Supabase RPC with a timeout, and turns network trouble into an
// RpcError with a kind the UI can explain. Same pattern as
// src/lib/connect/api.ts. Raw errors are only logged in development.

const RPC_TIMEOUT_MS = 8000;

export type RpcErrorKind = 'offline' | 'timeout' | 'unknown';

export class RpcError extends Error {
  kind: RpcErrorKind;
  // The Postgres error message, e.g. 'rsvp_rate_limited' from a trigger.
  // For matching in code only — never show it to users.
  serverMessage: string | null;

  constructor(kind: RpcErrorKind, cause?: unknown) {
    super(kind);
    this.kind = kind;
    this.serverMessage =
      cause && typeof cause === 'object' && 'message' in cause && typeof cause.message === 'string'
        ? cause.message
        : null;
    if (__DEV__ && cause) console.warn('[rpc]', cause);
  }
}

export function friendlyRpcError(error: unknown): string {
  if (error instanceof RpcError) {
    // The database refuses password-only sessions of accounts with two-step
    // on (20260930000000). The app normally shows the code screen first.
    if (error.serverMessage === 'mfa_required') {
      return 'Enter your two-step verification code to continue.';
    }
    // discover_profiles refuses Looking For filters without Premium
    // (20260930020000). The app hides them first, so this is a fallback.
    if (error.serverMessage === 'premium_required') {
      return 'Filtering by Looking For tags is a Premium feature.';
    }
    if (error.kind === 'offline') return "You're offline. Check your connection and try again.";
    if (error.kind === 'timeout') return 'That took too long. Check your connection and try again.';
  }
  return 'Something went wrong. Try again.';
}

function isNetworkMessage(message: string | undefined) {
  return /network request failed|failed to fetch|network error/i.test(message ?? '');
}

export async function callRpc<T = any>(name: string, args?: Record<string, unknown>): Promise<T> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS);
  try {
    const { data, error } = await supabase.rpc(name, args).abortSignal(controller.signal);
    if (error) {
      if (controller.signal.aborted) throw new RpcError('timeout', error);
      if (isNetworkMessage(error.message)) throw new RpcError('offline', error);
      throw new RpcError('unknown', error);
    }
    return data as T;
  } catch (error) {
    if (error instanceof RpcError) throw error;
    if (controller.signal.aborted) throw new RpcError('timeout', error);
    throw new RpcError('offline', error);
  } finally {
    clearTimeout(timer);
  }
}
