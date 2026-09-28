// Custom Google Maps styles (Android only — Apple Maps on iOS can't be
// restyled, so there we use its built-in "muted" map instead).
//
// The idea: paint the whole map in one warm tone with very little contrast,
// and hide businesses/transit, so the web lines, people, and events are the
// strongest things on screen. Roads are deliberately low-contrast so they
// don't compete with the connection lines.
//
// Each rule says "for this kind of map feature, set these colors". Made
// with the format from https://developers.google.com/maps/documentation/javascript/style-reference

type MapStyle = {
  featureType?: string;
  elementType?: string;
  stylers: Record<string, string | number>[];
}[];

function monochromeStyle(c: {
  land: string;
  road: string;
  water: string;
  label: string;
  labelHalo: string;
}): MapStyle {
  return [
    { elementType: 'geometry', stylers: [{ color: c.land }] },
    { elementType: 'labels.icon', stylers: [{ visibility: 'off' }] },
    { elementType: 'labels.text.fill', stylers: [{ color: c.label }] },
    { elementType: 'labels.text.stroke', stylers: [{ color: c.labelHalo }] },
    // Businesses, parks, schools etc. — hide the pins and labels.
    { featureType: 'poi', stylers: [{ visibility: 'off' }] },
    { featureType: 'transit', stylers: [{ visibility: 'off' }] },
    { featureType: 'road', elementType: 'geometry', stylers: [{ color: c.road }] },
    // Only label the bigger roads so the map stays quiet.
    { featureType: 'road.local', elementType: 'labels', stylers: [{ visibility: 'off' }] },
    {
      featureType: 'administrative',
      elementType: 'geometry.stroke',
      stylers: [{ color: c.road }],
    },
    { featureType: 'water', elementType: 'geometry', stylers: [{ color: c.water }] },
    { featureType: 'water', elementType: 'labels.text', stylers: [{ visibility: 'off' }] },
  ];
}

// Warm beige, matching the app's light background (#faf5ec).
export const LIGHT_MAP_STYLE = monochromeStyle({
  land: '#ebe3d5',
  road: '#ddd2c1',
  water: '#d3c8b7',
  // Muted, but still readable at a glance (~4:1 on land, ~3.6:1 on roads).
  label: '#76685f',
  labelHalo: '#ebe3d5',
});

// Deep warm brown, matching the app's dark background (#1b1614).
export const DARK_MAP_STYLE = monochromeStyle({
  land: '#1f1a17',
  road: '#2e2723',
  water: '#141110',
  label: '#8a7b72',
  labelHalo: '#1f1a17',
});
