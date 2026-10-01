import { openBrowserAsync, WebBrowserPresentationStyle } from 'expo-web-browser';
import { Alert, Linking } from 'react-native';

// Real legal details. Every legal screen and draft reads from
// here. Never invent real values (legal name, emails, site).
export const LEGAL = {
  ENTITY_NAME: 'Bolas Networking LLC',
  CONTACT_EMAIL: 'admin@bolasnetworking.com',
  SUPPORT_EMAIL: 'admin@bolasnetworking.com',
  PRIVACY_URL: 'https://bolasnetworking.com/privacy',
  TERMS_URL: 'https://bolasnetworking.com/terms',
  GUIDELINES_URL: 'https://bolasnetworking.com/guidelines',
  SAFETY_URL: 'https://bolasnetworking.com/safety',
  DELETE_ACCOUNT_URL: 'https://bolasnetworking.com/delete-account',
  // Must match public._current_terms_version() (migration
  // 20260928010000_legal_consent.sql). Bump both together.
  TERMS_VERSION: '2026-10-01',
  MIN_AGE: 18,
  // Shown after a report. Only promise what the team really does (Zane's
  // call, 2026-09-28).
  REPORT_REVIEW_PROMISE: 'within 24 hours',
} as const;

if (__DEV__) {
  const unfilled = Object.entries(LEGAL)
    .filter(([, value]) => typeof value === 'string' && value.includes('{{'))
    .map(([key]) => key);
  if (unfilled.length > 0) {
    console.warn(`[legal] Placeholders still unfilled in src/lib/legal/config.ts: ${unfilled.join(', ')}`);
  }
}

// Legal pages open in the in-app browser. Until the placeholders are filled
// in there's no real page, so say so instead of opening a broken URL.
export async function openLegalUrl(url: string) {
  if (url.includes('{{')) {
    if (__DEV__) console.warn(`[legal] ${url} is still a placeholder`);
    Alert.alert('Coming soon', "This page isn't published yet.");
    return;
  }
  await openBrowserAsync(url, { presentationStyle: WebBrowserPresentationStyle.AUTOMATIC });
}

export async function contactSupport() {
  if (LEGAL.SUPPORT_EMAIL.includes('{{')) {
    Alert.alert('Coming soon', 'A support email address is on the way.');
    return;
  }
  await Linking.openURL(`mailto:${LEGAL.SUPPORT_EMAIL}?subject=${encodeURIComponent('Bolas support')}`);
}
