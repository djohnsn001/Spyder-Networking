// A connect code from a bolas://connect/<token> link that arrived while the
// user couldn't use it yet (signed out, or profile setup unfinished). Kept in
// memory only: codes expire within a minute, so persisting it is pointless.
let pendingToken: string | null = null;

export function setPendingConnectToken(token: string) {
  pendingToken = token;
}

// Returns the pending code (if any) and clears it, so it's only used once.
export function takePendingConnectToken(): string | null {
  const token = pendingToken;
  pendingToken = null;
  return token;
}
