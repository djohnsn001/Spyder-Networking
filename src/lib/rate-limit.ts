// Thrown when the database refuses a write for going over a rate limit
// (security item M4). The limits themselves live in SQL (_rate_limits() in
// 20260929070000_rate_limits.sql); the app only turns the error code into
// something a person can read. `message` is safe to show as-is.
export class RateLimitError extends Error {
  title: string;

  constructor(title: string, message: string) {
    super(message);
    this.name = 'RateLimitError';
    this.title = title;
  }
}

type PostgrestLikeError = { message?: string; details?: string | null };

// The trigger raises e.g. message_rate_limited with detail 'minute' or 'day'.
export function isRateLimited(error: unknown, code: string): error is PostgrestLikeError {
  return (
    !!error && typeof error === 'object' && 'message' in error && error.message === code
  );
}
