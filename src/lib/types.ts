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
  created_at: string;
  updated_at: string;
};
