-- 013_notes_products_FINAL.sql
-- NEW additive migration for Notes. Do NOT replace 012_study_material.sql.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  slug TEXT,
  description TEXT,
  exam_name TEXT,
  category TEXT,
  thumbnail_url TEXT,
  price NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (price >= 0),
  is_free BOOLEAN NOT NULL DEFAULT false,
  is_published BOOLEAN NOT NULL DEFAULT false,
  display_order INTEGER NOT NULL DEFAULT 0,
  drive_url TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT notes_free_price_check CHECK ((is_free AND price = 0) OR ((NOT is_free) AND price > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS notes_slug_unique ON public.notes(slug) WHERE slug IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS one_published_free_note ON public.notes((is_free)) WHERE is_free = true AND is_published = true;

ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notes_public_read ON public.notes;
CREATE POLICY notes_public_read ON public.notes FOR SELECT TO anon, authenticated USING (is_published = true OR public.is_admin());
DROP POLICY IF EXISTS notes_admin_insert ON public.notes;
CREATE POLICY notes_admin_insert ON public.notes FOR INSERT TO authenticated WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS notes_admin_update ON public.notes;
CREATE POLICY notes_admin_update ON public.notes FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS notes_admin_delete ON public.notes;
CREATE POLICY notes_admin_delete ON public.notes FOR DELETE TO authenticated USING (public.is_admin());
GRANT SELECT ON public.notes TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.notes TO authenticated;

CREATE TABLE IF NOT EXISTS public.note_access (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  note_id UUID NOT NULL REFERENCES public.notes(id) ON DELETE CASCADE,
  payment_id UUID,
  access_status TEXT NOT NULL DEFAULT 'active' CHECK (access_status IN ('active','revoked')),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id, note_id)
);
ALTER TABLE public.note_access ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS note_access_owner_read ON public.note_access;
CREATE POLICY note_access_owner_read ON public.note_access FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS note_access_admin_insert ON public.note_access;
CREATE POLICY note_access_admin_insert ON public.note_access FOR INSERT TO authenticated WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS note_access_admin_update ON public.note_access;
CREATE POLICY note_access_admin_update ON public.note_access FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
GRANT SELECT ON public.note_access TO authenticated;
GRANT INSERT, UPDATE ON public.note_access TO authenticated;

DO $$ BEGIN
  IF to_regclass('public.payments') IS NOT NULL THEN
    ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS note_id UUID REFERENCES public.notes(id) ON DELETE SET NULL;
    CREATE INDEX IF NOT EXISTS payments_note_id_idx ON public.payments(note_id);
  END IF;
  IF to_regclass('public.purchases') IS NOT NULL THEN
    ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS note_id UUID REFERENCES public.notes(id) ON DELETE SET NULL;
    CREATE INDEX IF NOT EXISTS purchases_note_id_idx ON public.purchases(note_id);
  END IF;
END $$;

DROP VIEW IF EXISTS public.user_notes;
CREATE VIEW public.user_notes
WITH (security_invoker = true)
AS
SELECT n.id,n.title,n.slug,n.description,n.exam_name,n.category,n.thumbnail_url,n.price,n.is_free,n.is_published,n.display_order,n.created_at,n.updated_at,
       CASE WHEN n.is_free OR EXISTS (
         SELECT 1 FROM public.note_access a
         WHERE a.note_id=n.id AND a.user_id=auth.uid() AND a.access_status='active'
           AND (a.expires_at IS NULL OR a.expires_at > now())
       ) THEN n.drive_url ELSE NULL END AS drive_url,
       (n.is_free OR EXISTS (
         SELECT 1 FROM public.note_access a
         WHERE a.note_id=n.id AND a.user_id=auth.uid() AND a.access_status='active'
           AND (a.expires_at IS NULL OR a.expires_at > now())
       )) AS has_access
FROM public.notes n
WHERE n.is_published = true OR public.is_admin();
GRANT SELECT ON public.user_notes TO authenticated;
REVOKE ALL ON public.user_notes FROM anon;

CREATE OR REPLACE FUNCTION public.notes_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS notes_updated_at ON public.notes;
CREATE TRIGGER notes_updated_at BEFORE UPDATE ON public.notes FOR EACH ROW EXECUTE FUNCTION public.notes_set_updated_at();
