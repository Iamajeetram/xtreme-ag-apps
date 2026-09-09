-- Xtreme AG Apps: detailed public recommendation form
-- Safe to run after the previous recommendation table migration.
CREATE TABLE IF NOT EXISTS public.service_recommendations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT,
  mobile TEXT,
  email TEXT,
  category TEXT,
  title TEXT,
  message TEXT NOT NULL,
  benefit TEXT,
  reference TEXT,
  contact_permission TEXT NOT NULL DEFAULT 'yes',
  preferred_contact TEXT NOT NULL DEFAULT 'WhatsApp',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.service_recommendations
  ADD COLUMN IF NOT EXISTS mobile TEXT,
  ADD COLUMN IF NOT EXISTS email TEXT,
  ADD COLUMN IF NOT EXISTS title TEXT,
  ADD COLUMN IF NOT EXISTS benefit TEXT,
  ADD COLUMN IF NOT EXISTS reference TEXT,
  ADD COLUMN IF NOT EXISTS contact_permission TEXT DEFAULT 'yes',
  ADD COLUMN IF NOT EXISTS preferred_contact TEXT DEFAULT 'WhatsApp';

ALTER TABLE public.service_recommendations ENABLE ROW LEVEL SECURITY;
GRANT INSERT ON public.service_recommendations TO anon, authenticated;
GRANT SELECT ON public.service_recommendations TO authenticated;

DROP POLICY IF EXISTS "Anyone can submit service recommendations" ON public.service_recommendations;
CREATE POLICY "Anyone can submit service recommendations"
ON public.service_recommendations
FOR INSERT TO anon, authenticated
WITH CHECK (
  length(trim(message)) >= 20
  AND length(trim(message)) <= 3000
  AND length(trim(name)) BETWEEN 1 AND 80
  AND length(trim(mobile)) BETWEEN 7 AND 15
  AND length(trim(title)) BETWEEN 1 AND 150
  AND (user_id IS NULL OR user_id = auth.uid())
);

DROP POLICY IF EXISTS "Admins can view service recommendations" ON public.service_recommendations;
CREATE POLICY "Admins can view service recommendations"
ON public.service_recommendations
FOR SELECT TO authenticated
USING (public.is_admin());

CREATE INDEX IF NOT EXISTS service_recommendations_created_at_idx
ON public.service_recommendations (created_at DESC);
