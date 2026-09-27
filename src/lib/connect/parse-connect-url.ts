// A connect token is 128 random bits as 32 lowercase hex chars (see
// create_connect_token). QR codes encode it as bolas://connect/<token>.
// Later this can also accept https://<landing-domain>/c/<token> (universal links).

const TOKEN_PATTERN = /^[0-9a-f]{32}$/;
const URL_PATTERN = /^bolas:\/\/connect\/([0-9a-fA-F]{32})\/?$/;

export function connectUrlFor(token: string): string {
  return `bolas://connect/${token}`;
}

export function isConnectToken(value: string): boolean {
  return TOKEN_PATTERN.test(value);
}

// Returns the token from a scanned code, or null if it isn't a Bolas code.
export function parseConnectUrl(value: string): string | null {
  const match = URL_PATTERN.exec(value.trim());
  return match ? match[1].toLowerCase() : null;
}
