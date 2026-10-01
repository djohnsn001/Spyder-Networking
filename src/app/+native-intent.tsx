import { setPendingCheckinToken } from '@/lib/checkin';
import { setPendingConnectToken } from '@/lib/connect/pending-link';

// Runs for every incoming link before routing. Remembers a connect or
// check-in code so it survives the login redirect if the user is signed out;
// the path itself is passed through unchanged.
export function redirectSystemPath({ path }: { path: string; initial: boolean }) {
  try {
    const connect = /connect\/([0-9a-fA-F]{32})/.exec(path);
    if (connect) setPendingConnectToken(connect[1].toLowerCase());
    const checkin = /checkin\/([0-9a-fA-F]{32})/.exec(path);
    if (checkin) setPendingCheckinToken(checkin[1].toLowerCase());
  } catch {
    // Never block navigation over this.
  }
  return path;
}
