-- supabase/migrations/001_add_profile_state.sql
-- Add state column to public.profiles table

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS state TEXT;
