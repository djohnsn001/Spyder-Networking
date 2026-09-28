#!/usr/bin/env node

/**
 * Prints the contrast ratio of every text/background pair the app uses, in
 * light and dark mode, read straight from src/constants/theme.ts. Flags
 * anything under WCAG AA: 4.5:1 for normal text, 3:1 for large text
 * (≥ 18pt, or ≥ 14pt bold) and UI parts (borders, icons, controls).
 *
 *   npm run contrast
 *
 * Exit code 1 if anything fails, so it can run in CI later.
 */

const fs = require('fs');
const path = require('path');

const THEME = path.resolve(__dirname, '..', 'src', 'constants', 'theme.ts');
const source = fs.readFileSync(THEME, 'utf8');

// Pull "key: '#rrggbb'" pairs out of the `light: { ... }` / `dark: { ... }`
// blocks, plus the exported single-color constants.
function block(name) {
  const start = source.indexOf(`${name}: {`);
  const end = source.indexOf('\n  }', start);
  const colors = {};
  for (const [, key, hex] of source.slice(start, end).matchAll(/(\w+):\s*'(#[0-9a-fA-F]{6})'/g)) {
    colors[key] = hex;
  }
  return colors;
}
function constant(name) {
  const match = source.match(new RegExp(`export const ${name} = '(#[0-9a-fA-F]{6})'`));
  return match ? match[1] : null;
}

const modes = { light: block('light'), dark: block('dark') };
const shared = {
  AccentColor: constant('AccentColor'),
  DangerColor: constant('DangerColor'),
  // Hard-coded label color on filled buttons (e.g. styles.buttonLabel).
  ButtonLabel: '#fdfbf7',
};

function luminance(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
function ratio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// [foreground, background, kind, where it's used]. kind: 'text' (4.5),
// 'large' (3), 'ui' (3). Names resolve in the mode first, then `shared`.
const PAIRS = [
  ['text', 'background', 'text', 'body text'],
  ['text', 'backgroundElement', 'text', 'text on cards'],
  ['text', 'backgroundSelected', 'text', 'text in inputs / pills'],
  ['textSecondary', 'background', 'text', 'secondary text'],
  ['textSecondary', 'backgroundElement', 'text', 'secondary text on cards'],
  ['textSecondary', 'backgroundSelected', 'text', 'input placeholders'],
  ['accentText', 'background', 'text', 'accent links (Retry, Unblock)'],
  ['accentText', 'backgroundElement', 'text', 'accent links on cards'],
  ['accentText', 'overlay', 'text', 'map banner actions'],
  ['secondaryAccent', 'background', 'text', 'navy links'],
  ['secondaryAccent', 'backgroundElement', 'text', 'navy links on cards (Terms / Privacy)'],
  ['onAccent', 'accent', 'text', 'labels on themed accent fills'],
  ['onSecondaryAccent', 'secondaryAccent', 'text', 'labels on navy fills'],
  ['text', 'overlay', 'text', 'map banner text'],
  ['textSecondary', 'overlay', 'text', 'map banner secondary text'],
  ['markerInk', 'markerSurface', 'text', 'map marker labels'],
  ['onMarkerMuted', 'markerMuted', 'text', 'muted map markers'],
  ['ButtonLabel', 'AccentColor', 'text', 'primary buttons (Sign up, Continue, Send report)'],
  ['ButtonLabel', 'DangerColor', 'text', 'danger buttons (Delete my account, Block)'],
  ['danger', 'background', 'text', 'Log out / Delete account rows'],
  ['danger', 'backgroundElement', 'text', 'Log out / Delete account rows on cards'],
  ['error', 'background', 'text', 'error messages'],
  ['error', 'backgroundElement', 'text', 'error messages on cards'],
  ['error', 'overlay', 'text', 'error banners over the map'],
  ['textSecondary', 'backgroundElement', 'ui', 'unchecked checkbox border'],
  ['accent', 'background', 'ui', 'map "+" button, selected pills'],
  // Not checked: overlayBorder (banner outline). Decorative: the banner has
  // its own fill and shadow, so WCAG 1.4.11 doesn't require it (Zane,
  // 2026-09-28).
];

const MIN = { text: 4.5, large: 3, ui: 3 };
let failures = 0;

for (const [mode, colors] of Object.entries(modes)) {
  console.log(`\n${mode.toUpperCase()} MODE`);
  for (const [fgName, bgName, kind, where] of PAIRS) {
    const fg = colors[fgName] ?? shared[fgName];
    const bg = colors[bgName] ?? shared[bgName];
    if (!fg || !bg) {
      console.log(`  ?     ${fgName} on ${bgName}: color not found`);
      continue;
    }
    const r = ratio(fg, bg);
    const ok = r >= MIN[kind];
    // Normal text that only passes the large-text bar is worth knowing.
    const note = !ok && kind === 'text' && r >= 3 ? ' (OK only for large/bold text)' : '';
    if (!ok) failures++;
    console.log(
      `  ${ok ? 'PASS' : 'FAIL'}  ${r.toFixed(2).padStart(5)}:1  ${fgName} ${fg} on ${bgName} ${bg}  — ${where}${note}`,
    );
  }
}

console.log(`\n${failures === 0 ? 'All pairs pass.' : `${failures} pair(s) below WCAG AA.`}`);
process.exitCode = failures === 0 ? 0 : 1;
