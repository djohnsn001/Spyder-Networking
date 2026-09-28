import { router } from 'expo-router';
import { Alert } from 'react-native';

import { callRpc, friendlyRpcError } from '@/lib/rpc';

// Reporting and blocking people (migration 20260928020000_user_safety.sql).
// A blocked person is never told; everything they see is generic.

export type UserReportContext = 'profile' | 'message' | 'in_person' | 'other';

export type UserReportReason =
  | 'spam'
  | 'scam_or_selling'
  | 'harassment'
  | 'hate'
  | 'sexual_content'
  | 'impersonation'
  | 'underage'
  | 'unsafe_meetup'
  | 'other';

// Order shown in the report sheet. Must match report_user's list.
export const USER_REPORT_REASONS: { value: UserReportReason; label: string }[] = [
  { value: 'harassment', label: 'Harassment or bullying' },
  { value: 'scam_or_selling', label: 'Scam, or selling something' },
  { value: 'spam', label: 'Spam' },
  { value: 'hate', label: 'Hate speech' },
  { value: 'sexual_content', label: 'Sexual content' },
  { value: 'impersonation', label: 'Pretending to be someone else' },
  { value: 'underage', label: 'Might be under 18' },
  { value: 'unsafe_meetup', label: 'Made me feel unsafe in person' },
  { value: 'other', label: 'Something else' },
];

export const USER_REPORT_DETAILS_LIMIT = 500;

export type ReportUserOutcome =
  | 'reported'
  | 'self'
  | 'not_found'
  | 'invalid'
  | 'rate_limited'
  | 'not_allowed';

export async function reportUser(args: {
  userId: string;
  context: UserReportContext;
  contextId?: string | null;
  reason: UserReportReason;
  details?: string;
}): Promise<ReportUserOutcome> {
  const result = await callRpc<{ outcome: ReportUserOutcome }>('report_user', {
    p_user_id: args.userId,
    p_context: args.context,
    p_context_id: args.contextId ?? null,
    p_reason: args.reason,
    p_details: args.details?.trim() || null,
  });
  return result?.outcome ?? 'invalid';
}

export async function blockUser(userId: string) {
  return (await callRpc<{ outcome: 'blocked' | 'self' | 'not_found' }>('block_user', { p_user_id: userId }))
    ?.outcome;
}

export async function unblockUser(userId: string) {
  await callRpc('unblock_user', { p_user_id: userId });
}

export type BlockedUser = {
  user_id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
  blocked_at: string;
};

export async function fetchBlockedUsers(): Promise<BlockedUser[]> {
  return (await callRpc<BlockedUser[]>('get_my_blocked_users')) ?? [];
}

// After blocking, the person vanishes from every screen, so leave whatever
// screen showed them and go back to the tabs.
export function leaveAfterBlock() {
  if (router.canDismiss()) router.dismissAll();
  else if (router.canGoBack()) router.back();
}

// The confirmation before a block, with the plan's wording. Calls onBlocked
// once the block went through.
export function confirmBlock(name: string, userId: string, onBlocked: () => void = leaveAfterBlock) {
  Alert.alert(
    `Block ${name}?`,
    "They won't be able to find your profile, message you, or connect with you. They won't be notified.",
    [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Block',
        style: 'destructive',
        onPress: async () => {
          try {
            await blockUser(userId);
            onBlocked();
          } catch (error) {
            Alert.alert("Couldn't block", friendlyRpcError(error));
          }
        },
      },
    ],
  );
}

export function openReport(userId: string, context: UserReportContext, options?: {
  contextId?: string;
  name?: string;
}) {
  router.push({
    pathname: '/report/[userId]',
    params: {
      userId,
      context,
      ...(options?.contextId ? { contextId: options.contextId } : {}),
      ...(options?.name ? { name: options.name } : {}),
    },
  });
}

// The "⋯" menu on a profile or chat: Report or Block. Alert keeps it native
// on both platforms (Android allows three buttons, which is exactly this).
export function openSafetyMenu(name: string, userId: string, context: UserReportContext) {
  Alert.alert(name, undefined, [
    { text: 'Report', onPress: () => openReport(userId, context, { name }) },
    { text: 'Block', style: 'destructive', onPress: () => confirmBlock(name, userId) },
    { text: 'Cancel', style: 'cancel' },
  ]);
}

// ---------------------------------------------------------------------------
// Admin (every call is re-checked on the server; non-admins get 42501)
// ---------------------------------------------------------------------------

export type AdminUserReportEntry = {
  id: string;
  context: UserReportContext;
  context_id: string | null;
  reason: UserReportReason;
  details: string | null;
  reporter_username: string | null;
  created_at: string;
};

export type AdminUserReportGroup = {
  reported_user_id: string | null; // null once that account is deleted
  username: string | null;
  full_name: string | null;
  is_suspended: boolean;
  report_count: number;
  reports_by_reason: Record<string, number>;
  has_underage: boolean;
  latest_report_at: string;
  latest_snapshot: {
    username?: string | null;
    full_name?: string | null;
    bio?: string | null;
    city?: string | null;
    message?: { body: string; sent_at: string } | null;
  } | null;
  reports: AdminUserReportEntry[];
};

export const USER_REPORT_REASON_LABEL: Record<string, string> = Object.fromEntries(
  USER_REPORT_REASONS.map((r) => [r.value, r.label]),
);

export async function adminListUserReports(): Promise<AdminUserReportGroup[]> {
  return (await callRpc<AdminUserReportGroup[]>('admin_list_user_reports', { p_status: 'open' })) ?? [];
}

export async function adminResolveUserReport(reportId: string, status: 'dismissed' | 'actioned', note?: string) {
  await callRpc('admin_resolve_user_report', {
    p_report_id: reportId,
    p_status: status,
    p_note: note ?? null,
  });
}

export async function adminSetAccountStatus(userId: string, status: 'suspended' | null, reason?: string) {
  return callRpc<{ outcome: string; events_removed?: number }>('admin_set_account_status', {
    p_user_id: userId,
    p_status: status,
    p_reason: reason ?? null,
  });
}
