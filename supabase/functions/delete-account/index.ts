// Deletes the calling user's account.
// Plan: docs/plans/legal-compliance.md (Phase 4.2).
//
//   POST, with the user's session (supabase.functions.invoke sends it)
//   body: { confirm: "<their username>" }   ("DELETE" if they never picked one)
//   -> 200 { outcome: 'deleted' }
//   -> 400 { outcome: 'confirm_mismatch' | 'invalid' }
//   -> 401 { outcome: 'not_authenticated' }
//   -> 403 { outcome: 'mfa_required' }      two-step is on, code not entered
//   -> 405 { outcome: 'method_not_allowed' }
//   -> 500 { outcome: 'failed' }            safe to retry
//
// Order matters: avatar files first (Storage API, never SQL on
// storage.objects), then the auth user. Deleting the auth user cascades to
// every table (supabase/migrations/20260928030000_account_deletion.sql);
// safety reports are kept with the user set to null. If a step fails,
// nothing after it runs, and calling again finishes the job.
//
// The secret key comes from the function's built-in environment
// (SUPABASE_SECRET_KEYS, read by @supabase/server). It is never in the app.
// Logs never include ids, emails, or usernames.

import { createSupabaseContext } from 'npm:@supabase/server';

const AVATAR_BUCKET = 'avatars';
// Folders hold one file per photo change; this caps a runaway loop.
const MAX_LIST_ROUNDS = 50;

function reply(outcome: string, status = 200) {
  return Response.json({ outcome }, { status });
}

export default {
  fetch: async (req: Request): Promise<Response> => {
    if (req.method !== 'POST') return reply('method_not_allowed', 405);

    // Verifies the JWT itself (on top of the platform's verify_jwt check)
    // and gives an admin client that bypasses RLS.
    const { data: ctx, error: authError } = await createSupabaseContext(req, { auth: 'user' });
    if (authError || !ctx) return reply('not_authenticated', 401);

    // The user id always comes from the verified token, never the body.
    const userId: string | undefined = ctx.userClaims?.id ?? ctx.jwtClaims?.sub;
    const email: string | undefined = ctx.userClaims?.email ?? ctx.jwtClaims?.email;
    if (!userId) return reply('not_authenticated', 401);

    const admin = ctx.supabaseAdmin;

    // Two-step verification: with an authenticator app turned on, a
    // password-only (aal1) session can't delete the account. The app shows
    // the code screen first; this stops direct calls with a stolen password.
    if (ctx.jwtClaims?.aal !== 'aal2') {
      const { data: mfa, error: mfaError } = await admin.auth.admin.mfa.listFactors({ userId });
      if (mfaError) {
        console.error('delete-account: factor lookup failed', mfaError.status);
        return reply('failed', 500);
      }
      if ((mfa?.factors ?? []).some((f: { status: string }) => f.status === 'verified')) {
        return reply('mfa_required', 403);
      }
    }

    let confirm = '';
    try {
      const body = await req.json();
      confirm = typeof body?.confirm === 'string' ? body.confirm.trim() : '';
    } catch {
      return reply('invalid', 400);
    }

    // Last guard against accidents: they typed their own username.
    const { data: profile, error: profileError } = await admin
      .from('profiles')
      .select('username')
      .eq('id', userId)
      .maybeSingle();
    if (profileError) {
      console.error('delete-account: profile lookup failed', profileError.code);
      return reply('failed', 500);
    }
    const expected: string = profile?.username ?? 'DELETE';
    if (confirm.toLowerCase() !== expected.toLowerCase()) return reply('confirm_mismatch', 400);

    // 1. Every file in avatars/<user id>/, through the Storage API. Listing
    //    again after each removal until the folder is empty handles folders
    //    bigger than one page.
    for (let round = 0; round < MAX_LIST_ROUNDS; round++) {
      const { data: files, error: listError } = await admin.storage
        .from(AVATAR_BUCKET)
        .list(userId, { limit: 100 });
      if (listError) {
        console.error('delete-account: avatar list failed', listError.message);
        return reply('failed', 500);
      }
      if (!files || files.length === 0) break;

      const { error: removeError } = await admin.storage
        .from(AVATAR_BUCKET)
        .remove(files.map((file: { name: string }) => `${userId}/${file.name}`));
      if (removeError) {
        console.error('delete-account: avatar remove failed', removeError.message);
        return reply('failed', 500);
      }
    }

    // 2. A waitlist signup with the same email (the website's form). Exact
    //    match only — the waitlist isn't linked to accounts otherwise.
    if (email) {
      const { error: waitlistError } = await admin
        .from('waitlist')
        .delete()
        .in('email', Array.from(new Set([email, email.toLowerCase()])));
      if (waitlistError) {
        console.error('delete-account: waitlist delete failed', waitlistError.code);
        return reply('failed', 500);
      }
    }

    // 3. The auth user. Cascades do the rest.
    const { error: deleteError } = await admin.auth.admin.deleteUser(userId);
    if (deleteError) {
      console.error('delete-account: auth delete failed', deleteError.status);
      return reply('failed', 500);
    }

    return reply('deleted');
  },
};
