// Shared fixture data for the Web Map seed scripts (seed-map-data.js and
// add-seed-connections.js) — kept in one place so both stay in sync.

const SEED_EMAIL_DOMAIN = "bolas-seed.local";

// Positioned in an evenly-spaced ring (a 12-gon, i.e. decagon-ish) around
// Boise instead of clustered by city, so the Web Map's spider web spreads
// out across many distinct areas instead of a few tight blobs. lat/lng are
// pre-rounded to 2 decimals, matching the server-side rounding in
// update_my_location() — seed data should look like real saved locations.
const PROFILES = [
  { key: "ava", full_name: "Ava Chen", username: "ava_builds", city: "Boise", lat: 43.62, lng: -116.05, business_stage: "building", interests: ["food-delivery", "campus"], bio: "Building a campus food delivery app. Looking for an Android developer." },
  { key: "marcus", full_name: "Marcus Webb", username: "marcuswebb", city: "Boise", lat: 43.69, lng: -116.07, business_stage: "idea", interests: ["ai", "career"], bio: "Building an AI resume review tool. Looking for a cofounder who's done this before." },
  { key: "bella", full_name: "Bella Garcia", username: "bella_g", city: "Eagle", lat: 43.74, lng: -116.13, business_stage: "launched", interests: ["health", "students"], bio: "Building a mental health check-in app for students. Can help with fundraising." },
  { key: "priya", full_name: "Priya Patel", username: "priya.patel", city: "Eagle", lat: 43.77, lng: -116.2, business_stage: "building", interests: ["sustainability", "retail"], bio: "Building sustainable packaging for local retailers. Looking for a first customer." },
  { key: "jordan", full_name: "Jordan Lee", username: "jordanlee", city: "Star", lat: 43.74, lng: -116.28, business_stage: "idea", interests: ["fitness", "sports"], bio: "Building a fitness app for college athletes. Can help with design." },
  { key: "liam", full_name: "Liam O'Connor", username: "liam_oc", city: "Star", lat: 43.69, lng: -116.33, business_stage: "building", interests: ["mobility", "campus"], bio: "Building a campus rideshare app. Looking for a backend developer." },
  { key: "sofia", full_name: "Sofia Ramirez", username: "sofia.r", city: "Middleton", lat: 43.62, lng: -116.35, business_stage: "launched", interests: ["marketplace", "local"], bio: "Building a local farmers market marketplace. Can help with go-to-market." },
  { key: "tyler", full_name: "Tyler Brooks", username: "tbrooks", city: "Caldwell", lat: 43.54, lng: -116.33, business_stage: "idea", interests: ["education"], bio: "Building a student tutoring platform. Looking for a technical cofounder." },
  { key: "grace", full_name: "Grace Kim", username: "gracekim", city: "Nampa", lat: 43.49, lng: -116.28, business_stage: "building", interests: ["ecommerce", "handmade"], bio: "Building a marketplace for local handmade goods. Looking for a designer." },
  { key: "noah", full_name: "Noah Whitfield", username: "noah_w", city: "Nampa", lat: 43.47, lng: -116.2, business_stage: "idea", interests: ["ev", "energy"], bio: "Building an EV charging startup for apartment complexes. Can help with pitch decks." },
  { key: "maya", full_name: "Maya Thompson", username: "maya.t", city: "Kuna", lat: 43.49, lng: -116.13, business_stage: "building", interests: ["agtech"], bio: "Building sensor tech for local farms. Looking for a hardware engineer." },
  { key: "ethan", full_name: "Ethan Park", username: "ethanpark", city: "Meridian", lat: 43.54, lng: -116.07, business_stage: "launched", interests: ["media", "podcast"], bio: "Building a podcast network for first-time founders. Can help with storytelling." },
];

// Accepted connections between seed users (beyond "everyone <-> you"), so
// get_connection_edges() has plenty of mutual pairs to draw a real web —
// each person connects to a few others both inside and outside their own
// city cluster, rather than isolated per-city pairs.
const SEED_TO_SEED_EDGES = [
  ["ava", "marcus"],
  ["marcus", "bella"],
  ["ava", "bella"],
  ["priya", "jordan"],
  ["jordan", "liam"],
  ["priya", "liam"],
  ["sofia", "tyler"],
  ["grace", "noah"],
  ["maya", "ethan"],
  ["marcus", "priya"],
  ["bella", "jordan"],
  ["ava", "sofia"],
  ["liam", "grace"],
  ["tyler", "maya"],
  ["noah", "ethan"],
  ["sofia", "maya"],
  ["grace", "tyler"],
  ["priya", "sofia"],
  ["bella", "grace"],
  ["marcus", "noah"],
  ["jordan", "maya"],
  ["liam", "ethan"],
  ["ava", "tyler"],
  ["sofia", "noah"],
  ["maya", "grace"],
];

module.exports = { SEED_EMAIL_DOMAIN, PROFILES, SEED_TO_SEED_EDGES };
