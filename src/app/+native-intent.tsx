import { setPendingConnectToken } from '@/lib/connect/pending-link';

// Runs for every incoming link before routing. Remembers a connect code so it
// survives the login redirect if the user is signed out; the path itself is
// passed through unchanged.
export function redirectSystemPath({ path }: { path: string; initial: boolean }) {
  try {
    const match = /connect\/([0-9a-fA-F]{32})/.exec(path);
    if (match) setPendingConnectToken(match[1].toLowerCase());
  } catch {
    // Never block navigation over this.
  }
  return path;
}
