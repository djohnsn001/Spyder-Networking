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

export type ConnectionRow = {
  id: string;
  requester_id: string;
  addressee_id: string;
  status: 'pending' | 'accepted';
  created_at: string;
};

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

// One row of the event_summaries view: the event plus what the map and
// detail sheet need to show about it.
export type EventSummary = {
  id: string;
  creator_id: string;
  title: string;
  description: string | null;
  latitude: number;
  longitude: number;
  location_name: string | null;
  starts_at: string;
  ends_at: string | null;
  visibility: EventVisibility;
  created_at: string;
  updated_at: string;
  effective_ends_at: string;
  creator_username: string | null;
  creator_full_name: string | null;
  creator_avatar_url: string | null;
  attendee_count: number;
  is_going: boolean;
};
