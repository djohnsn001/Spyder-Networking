/**
 * Below are the colors that are used in the app. The colors are defined in the light and dark mode.
 * There are many other ways to style your app. For example, [Nativewind](https://www.nativewind.dev/), [Tamagui](https://tamagui.dev/), [unistyles](https://reactnativeunistyles.vercel.app), etc.
 */

import '@/global.css';

import { Platform } from 'react-native';

export const Colors = {
  light: {
    text: '#2a211c',
    background: '#faf5ec',
    backgroundElement: '#f3ebdd',
    backgroundSelected: '#e8dcc8',
    textSecondary: '#685a52',

    // Red text (Log out, Delete account) and error messages. Separate per
    // mode because no single red passes WCAG AA on both the cream and the
    // near-black backgrounds (npm run contrast).
    danger: '#b8383d',
    error: '#b3372f',

    // Brand accent, tuned per mode. `accent` is a fill (buttons, markers),
    // `onAccent` is text/icons drawn on that fill, and `accentText` is
    // accent-colored text on a normal background (links, Retry).
    accent: '#7a5d55',
    onAccent: '#fdfbf7',
    accentText: '#7a5d55',

    // Navy secondary accent, for selected/informational things (links,
    // selected pills, group markers). Buttons stay the clay `accent`.
    secondaryAccent: '#22324f',
    secondaryAccentSoft: '#dde3ec',
    onSecondaryAccent: '#fdfbf7',

    // Things that float over the map: banners, the cluster list card.
    overlay: '#fdfbf7',
    overlayBorder: '#a29287',
    scrim: 'rgba(42, 33, 28, 0.45)',
    shadow: '#2a211c',

    // Map markers.
    markerOutline: '#fdfbf7',
    markerSurface: '#fdfbf7',
    markerInk: '#2a211c',
    markerMuted: '#6e6058',
    onMarkerMuted: '#fdfbf7',
    halo: 'rgba(122, 93, 85, 0.16)',
    haloBorder: 'rgba(107, 82, 74, 0.85)',
    eventAreaFill: 'rgba(122, 93, 85, 0.16)',
    eventAreaStroke: '#7a5d55',

    // The web's lines. On the light map they're dark brown threads with a
    // thin cream outline ("casing") so they read over roads and labels.
    webSpoke: '#5c463f',
    webMutual: '#7a5d55',
    webCasing: 'rgba(253, 251, 247, 0.85)',
  },
  dark: {
    text: '#faf5ec',
    background: '#1b1614',
    backgroundElement: '#2a2320',
    backgroundSelected: '#382f2b',
    textSecondary: '#b8a99f',

    danger: '#e56b6f',
    error: '#f28b82',

    accent: '#83655d',
    onAccent: '#fdfbf7',
    accentText: '#d4b5aa',

    secondaryAccent: '#8a9bb8',
    secondaryAccentSoft: '#1a2640',
    onSecondaryAccent: '#1b1614',

    overlay: '#2a2320',
    overlayBorder: '#6e6058',
    scrim: 'rgba(0, 0, 0, 0.6)',
    shadow: '#000000',

    markerOutline: '#faf5ec',
    markerSurface: '#f3ebdd',
    markerInk: '#2a211c',
    markerMuted: '#b8a99f',
    onMarkerMuted: '#1b1614',
    halo: 'rgba(250, 245, 236, 0.2)',
    haloBorder: 'rgba(250, 245, 236, 0.7)',
    eventAreaFill: 'rgba(212, 181, 170, 0.14)',
    eventAreaStroke: 'rgba(212, 181, 170, 0.8)',

    // On the dark map the threads are cream, with a dark casing.
    webSpoke: '#faf5ec',
    webMutual: '#d4b5aa',
    webCasing: 'rgba(20, 14, 11, 0.7)',
  },
} as const;

export type ThemeColor = keyof typeof Colors.light & keyof typeof Colors.dark;

export const Fonts = Platform.select({
  ios: {
    /** iOS `UIFontDescriptorSystemDesignDefault` */
    sans: 'system-ui',
    /** iOS `UIFontDescriptorSystemDesignSerif` */
    serif: 'ui-serif',
    /** iOS `UIFontDescriptorSystemDesignRounded` */
    rounded: 'ui-rounded',
    /** iOS `UIFontDescriptorSystemDesignMonospaced` */
    mono: 'ui-monospace',
  },
  default: {
    sans: 'normal',
    serif: 'serif',
    rounded: 'normal',
    mono: 'monospace',
  },
  web: {
    sans: 'var(--font-display)',
    serif: 'var(--font-serif)',
    rounded: 'var(--font-rounded)',
    mono: 'var(--font-mono)',
  },
});

export const Spacing = {
  half: 2,
  one: 4,
  two: 8,
  three: 16,
  four: 24,
  five: 32,
  six: 64,
} as const;

export const BorderWidth = {
  thin: 1,
  thick: 2,
} as const;

export const BottomTabInset = Platform.select({ ios: 50, android: 80 }) ?? 0;
export const MaxContentWidth = 800;

export const AccentColor = '#83655d';
// The navy secondary accent per mode. In components, prefer
// `useTheme().secondaryAccent`, which follows the in-app light/dark toggle.
export const SecondaryAccent = {
  light: Colors.light.secondaryAccent,
  dark: Colors.dark.secondaryAccent,
} as const;
export const SecondaryAccentSoft = {
  light: Colors.light.secondaryAccentSoft,
  dark: Colors.dark.secondaryAccentSoft,
} as const;
// Fill for destructive buttons (white label on top: 5.5:1). For red TEXT use
// the theme's `danger` color instead.
export const DangerColor = '#b8383d';
