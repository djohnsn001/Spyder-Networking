import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';
import Svg, { Circle, Line, Path, Polygon, Rect } from 'react-native-svg';

import { ThemedText } from '@/components/themed-text';
import { useTheme } from '@/hooks/use-theme';
import type { BadgeDefinition, BadgeStyle } from '@/lib/badges';

// Each badge's emblem, drawn in a 100 x 100 box. The badge's name, number
// and description live in the detail sheet (tap the emblem), so emblems
// carry no text.
//
//   member badges (Founder, Early Member, Supporter)   shield
//   meeting people (First Handshake ... Web Weaver)   circle, ring darkens per tier
//   attending events (Showed Up, Regular)             circle, navy
//   hosting events (Host, Community Builder)          hexagon, navy
//
// A badge added to badge_definitions without an emblem here still shows: a
// plain circle in its style's colors with its emoji icon.

type Theme = ReturnType<typeof useTheme>;
type Shape = 'circle' | 'shield' | 'hexagon';
type Palette = { ring: string; fill: string; glyph: string };
type Emblem = {
  shape: Shape;
  palette: (theme: Theme) => Palette;
  // A thin second ring inside the edge, for the member badges.
  innerRing?: boolean;
  glyph: (color: string, fill: string) => ReactNode;
};

const STROKE = { strokeWidth: 5, strokeLinecap: 'round', strokeLinejoin: 'round' } as const;

const memberPalettes: Record<'founder' | 'early_member' | 'supporter', (t: Theme) => Palette> = {
  founder: (t) => ({ ring: t.text, fill: t.accent, glyph: t.onAccent }),
  early_member: (t) => ({ ring: t.secondaryAccent, fill: t.secondaryAccent, glyph: t.background }),
  supporter: (t) => ({ ring: t.accentText, fill: t.background, glyph: t.accentText }),
};

// Meeting people: the ring gets darker with each tier.
const connectionPalette = (tier: 1 | 2 | 3 | 4) => (t: Theme) => ({
  ring: [t.backgroundSelected, t.textSecondary, t.accentText, t.text][tier - 1],
  fill: t.backgroundSelected,
  glyph: t.text,
});

const eventPalette = (tier: 1 | 2) => (t: Theme) => ({
  ring: tier === 1 ? t.secondaryAccentSoft : t.secondaryAccent,
  fill: t.secondaryAccentSoft,
  glyph: t.secondaryAccent,
});

const EMBLEMS: Record<string, Emblem> = {
  // A bolas: three weights on cords, tied in the middle.
  founder: {
    shape: 'shield',
    palette: memberPalettes.founder,
    innerRing: true,
    glyph: (c) => (
      <>
        <Line x1={50} y1={52} x2={50} y2={30} stroke={c} {...STROKE} strokeWidth={3.5} />
        <Line x1={50} y1={52} x2={33} y2={65} stroke={c} {...STROKE} strokeWidth={3.5} />
        <Line x1={50} y1={52} x2={67} y2={65} stroke={c} {...STROKE} strokeWidth={3.5} />
        <Circle cx={50} cy={28} r={7.5} fill={c} />
        <Circle cx={31} cy={67} r={7.5} fill={c} />
        <Circle cx={69} cy={67} r={7.5} fill={c} />
        <Circle cx={50} cy={52} r={4} fill={c} />
      </>
    ),
  },
  // A sprout.
  early_member: {
    shape: 'shield',
    palette: memberPalettes.early_member,
    innerRing: true,
    glyph: (c) => (
      <>
        <Line x1={50} y1={72} x2={50} y2={46} stroke={c} {...STROKE} />
        <Path d="M50 54 C50 42 41 35 29 35 C29 47 38 54 50 54 Z" fill={c} />
        <Path d="M50 47 C50 35 59 28 71 28 C71 40 62 47 50 47 Z" fill={c} />
      </>
    ),
  },
  // A heart.
  supporter: {
    shape: 'shield',
    palette: memberPalettes.supporter,
    glyph: (c) => (
      <Path
        d="M50 71 C31 58 27 49 27 42 C27 34 33 29 40 29 C45 29 48 32 50 36 C52 32 55 29 60 29 C67 29 73 34 73 42 C73 49 69 58 50 71 Z"
        fill={c}
      />
    ),
  },
  // Two people joined.
  first_handshake: {
    shape: 'circle',
    palette: connectionPalette(1),
    glyph: (c) => (
      <>
        <Line x1={33} y1={50} x2={67} y2={50} stroke={c} {...STROKE} />
        <Circle cx={33} cy={50} r={8} fill={c} />
        <Circle cx={67} cy={50} r={8} fill={c} />
      </>
    ),
  },
  // A chain of three.
  connector: {
    shape: 'circle',
    palette: connectionPalette(2),
    glyph: (c) => (
      <>
        <Path d="M29 61 L50 39 L71 61" fill="none" stroke={c} {...STROKE} />
        <Circle cx={29} cy={61} r={7} fill={c} />
        <Circle cx={50} cy={39} r={7} fill={c} />
        <Circle cx={71} cy={61} r={7} fill={c} />
      </>
    ),
  },
  // One person at the center of six.
  super_connector: {
    shape: 'circle',
    palette: connectionPalette(3),
    glyph: (c) => {
      const spokes = hexPoints(23);
      return (
        <>
          {spokes.map(([x, y]) => (
            <Line key={`l${x}${y}`} x1={50} y1={50} x2={x} y2={y} stroke={c} {...STROKE} strokeWidth={3.5} />
          ))}
          {spokes.map(([x, y]) => (
            <Circle key={`c${x}${y}`} cx={x} cy={y} r={5} fill={c} />
          ))}
          <Circle cx={50} cy={50} r={7.5} fill={c} />
        </>
      );
    },
  },
  // A web.
  web_weaver: {
    shape: 'circle',
    palette: connectionPalette(4),
    glyph: (c) => (
      <>
        {hexPoints(25).map(([x, y]) => (
          <Line key={`${x}${y}`} x1={50} y1={50} x2={x} y2={y} stroke={c} strokeWidth={3} strokeLinecap="round" />
        ))}
        {[9, 17, 25].map((radius) => (
          <Polygon
            key={radius}
            points={hexPoints(radius).map((point) => point.join(',')).join(' ')}
            fill="none"
            stroke={c}
            strokeWidth={3}
            strokeLinejoin="round"
          />
        ))}
      </>
    ),
  },
  // A map pin.
  showed_up: {
    shape: 'circle',
    palette: eventPalette(1),
    glyph: (c, fill) => (
      <>
        <Path d="M50 74 C50 74 32 57 32 45 C32 34 40 27 50 27 C60 27 68 34 68 45 C68 57 50 74 50 74 Z" fill={c} />
        <Circle cx={50} cy={45} r={6.5} fill={fill} />
      </>
    ),
  },
  // A calendar with a check.
  regular: {
    shape: 'circle',
    palette: eventPalette(2),
    glyph: (c) => (
      <>
        <Rect x={29} y={33} width={42} height={38} rx={6} fill="none" stroke={c} {...STROKE} />
        <Line x1={29} y1={45} x2={71} y2={45} stroke={c} {...STROKE} />
        <Line x1={40} y1={27} x2={40} y2={37} stroke={c} {...STROKE} />
        <Line x1={60} y1={27} x2={60} y2={37} stroke={c} {...STROKE} />
        <Path d="M40 58 L47 64 L60 52" fill="none" stroke={c} {...STROKE} />
      </>
    ),
  },
  // A flag.
  host: {
    shape: 'hexagon',
    palette: eventPalette(1),
    glyph: (c) => (
      <>
        <Line x1={37} y1={27} x2={37} y2={74} stroke={c} {...STROKE} />
        <Path d="M37 29 L68 29 L60 40 L68 51 L37 51 Z" fill={c} stroke={c} {...STROKE} strokeWidth={2} />
      </>
    ),
  },
  // A group of three.
  community_builder: {
    shape: 'hexagon',
    palette: eventPalette(2),
    glyph: (c, fill) => (
      <>
        <Circle cx={32} cy={47} r={6} fill={c} />
        <Path d="M21 70 A11 11 0 0 1 43 70 Z" fill={c} />
        <Circle cx={68} cy={47} r={6} fill={c} />
        <Path d="M57 70 A11 11 0 0 1 79 70 Z" fill={c} />
        <Circle cx={50} cy={40} r={8} fill={c} stroke={fill} strokeWidth={3} />
        <Path d="M35 71 A15 15 0 0 1 65 71 Z" fill={c} stroke={fill} strokeWidth={3} />
      </>
    ),
  },
};

// Six points around the center, pointing up.
function hexPoints(radius: number): [number, number][] {
  return [90, 30, -30, -90, -150, 150].map((degrees) => {
    const angle = (degrees * Math.PI) / 180;
    return [round(50 + radius * Math.cos(angle)), round(50 - radius * Math.sin(angle))];
  });
}

function round(value: number) {
  return Math.round(value * 100) / 100;
}

// The outline, shrunk toward the center by k (1 = full size).
function ShapeOutline({ shape, k, ...paint }: { shape: Shape; k: number; fill?: string; stroke?: string; strokeWidth?: number; opacity?: number }) {
  const p = (x: number, y: number) => `${round(50 + (x - 50) * k)} ${round(50 + (y - 50) * k)}`;
  if (shape === 'circle') return <Circle cx={50} cy={50} r={round(46 * k)} {...paint} />;
  if (shape === 'hexagon') {
    return (
      <Path
        d={`M${p(50, 3)} L${p(91, 26.5)} L${p(91, 73.5)} L${p(50, 97)} L${p(9, 73.5)} L${p(9, 26.5)} Z`}
        strokeLinejoin="round"
        {...paint}
      />
    );
  }
  return (
    <Path
      d={`M${p(50, 3)} L${p(89, 15)} L${p(89, 47)} C${p(89, 72)} ${p(71, 88)} ${p(50, 97)} C${p(29, 88)} ${p(11, 72)} ${p(11, 47)} L${p(11, 15)} Z`}
      strokeLinejoin="round"
      {...paint}
    />
  );
}

const fallbackPalettes: Record<BadgeStyle, (t: Theme) => Palette> = {
  ...memberPalettes,
  milestone: connectionPalette(1),
};

export function BadgeEmblem({
  badgeKey,
  definition,
  size,
}: {
  badgeKey: string;
  definition: BadgeDefinition | undefined;
  size: number;
}) {
  const theme = useTheme();
  const emblem = EMBLEMS[badgeKey];
  const shape = emblem?.shape ?? 'circle';
  const palette = (emblem?.palette ?? fallbackPalettes[definition?.style ?? 'milestone'])(theme);

  return (
    <View style={{ width: size, height: size }}>
      <Svg width={size} height={size} viewBox="0 0 100 100">
        <ShapeOutline shape={shape} k={1} fill={palette.ring} />
        <ShapeOutline shape={shape} k={0.86} fill={palette.fill} />
        {emblem?.innerRing ? (
          <ShapeOutline shape={shape} k={0.76} fill="none" stroke={palette.glyph} strokeWidth={1.5} opacity={0.45} />
        ) : null}
        {emblem?.glyph(palette.glyph, palette.fill)}
      </Svg>
      {!emblem ? (
        <View style={styles.fallback} pointerEvents="none">
          <ThemedText style={{ fontSize: size * 0.42, lineHeight: size * 0.55 }}>
            {definition?.icon ?? '🏅'}
          </ThemedText>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  fallback: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
});
