export type BusinessStage = 'idea' | 'building' | 'launched';

export type Profile = {
  id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
  bio: string | null;
  interests: string[];
  business_stage: BusinessStage | null;
  city: string | null;
  notifications_enabled: boolean;
  location_sharing: 'connections' | 'off';
  created_at: string;
  updated_at: string;
};

// What anyone may see of someone else's profile. Settings like
// location_sharing and notifications_enabled stay on your own Profile.
export type PublicProfile = Pick<
  Profile,
  'id' | 'username' | 'full_name' | 'avatar_url' | 'bio' | 'interests' | 'business_stage' | 'city'
>;

// Just enough for an avatar and a name (inbox, chat header, requests).
export type ProfileSummary = Pick<Profile, 'id' | 'username' | 'full_name' | 'avatar_url'>;

// The connections list also shows city and stage.
export type ConnectionProfile = ProfileSummary & Pick<Profile, 'city' | 'business_stage'>;

// One row of discover_profiles(): a public profile plus the keyset cursor
// to pass back for the next page.
export type DiscoverProfile = PublicProfile & { cursor: string };

export type ConnectionRow = {
  id: string;
  requester_id: string;
  addressee_id: string;
  status: 'pending' | 'accepted';
  level: ConnectionLevel;
  method: ConnectionMethod;
  // When/where two people met in person (city name only). Null for acquaintances.
  met_at: string | null;
  met_city: string | null;
  // Undo window after an in-person connect; server-managed.
  undo_until: string | null;
  undo_snapshot: Record<string, unknown> | null;
  created_at: string;
};

// in_person can only be set by the server (QR scan or phone bump).
export type ConnectionLevel = 'acquaintance' | 'in_person';
export type ConnectionMethod = 'request' | 'qr' | 'bump' | 'legacy';

export type ConnectionStatus = 'none' | 'pending_sent' | 'pending_received' | 'accepted';

export type ConnectionLocation = {
  id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
  lat: number;
  lng: number;
  updated_at: string;
};

export type ConnectionEdge = {
  user_a: string;
  user_b: string;
};

export type Conversation = {
  id: string;
  is_group: boolean;
  user_a_id: string | null;
  user_b_id: string | null;
  created_at: string;
  last_message_at: string;
  last_message_id: string | null;
};

export type ConversationParticipant = {
  conversation_id: string;
  user_id: string;
  last_read_at: string;
  created_at: string;
};

export type Message = {
  id: string;
  conversation_id: string;
  sender_id: string;
  body: string;
  created_at: string;
};

export type EventVisibility = 'public' | 'connections';

// active = shown normally; hidden = auto-hidden by reports, waiting for an
// admin; removed = taken down by an admin. Only the host (and admins) ever
// see hidden/removed events.
export type EventStatus = 'active' | 'hidden' | 'removed';

// One row of the event_summaries view: the event plus what the map and
// detail sheet need to show about it.
export type EventSummary = {
  id: string;
  creator_id: string;
  title: string;
  description: string | null;
  // The real spot moved 150–350 m, fixed at creation. Always present.
  approx_latitude: number;
  approx_longitude: number;
  // The real spot and place name: null unless you're the host, going, or
  // an admin (RLS on event_locations).
  exact_latitude: number | null;
  exact_longitude: number | null;
  location_name: string | null;
  starts_at: string;
  ends_at: string | null;
  visibility: EventVisibility;
  status: EventStatus;
  // Set when the host moved the start/end time after creating it.
  time_changed_at: string | null;
  created_at: string;
  updated_at: string;
  effective_ends_at: string;
  creator_username: string | null;
  creator_full_name: string | null;
  creator_avatar_url: string | null;
  going_count: number;
  is_going: boolean;
};

// One row of get_event_attendees(): the host sees everyone; everyone else
// sees themselves plus their own connections who are going.
export type EventAttendee = {
  user_id: string;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
  is_connection: boolean;
  is_host: boolean;
};
