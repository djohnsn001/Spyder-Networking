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
