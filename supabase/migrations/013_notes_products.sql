-- 013_notes_products.sql
-- Xtreme AG Apps / Xtreme ExamX
-- Notes / Study Material as purchasable products.
--
-- Safe additive migration:
-- * Does NOT delete the existing study_materials table or its data.
-- * New Notes use public.notes and Google Drive URLs.
-- * At most ONE published note can be free.
-- * Paid note URLs are hidden by public.user_notes until note_access is active.
-- * Existing Test Series payment/purchase tables are extended only with nullable note_id columns.

BEGIN;

CREATE TABLE IF NOT EXISTS public.notes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT,
    exam_name TEXT,
    category TEXT,
    thumbnail_url TEXT,
    price NUMERIC(10,2) NOT NULL DEFAULT 0,
    is_free BOOLEAN NOT NULL DEFAULT false,
    is_published BOOLEAN NOT NULL DEFAULT false,
    display_order INTEGER NOT NULL DEFAULT 0,
    drive_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notes
    DROP CONSTRAINT IF EXISTS notes_product_price_check;

ALTER TABLE public.notes
    ADD CONSTRAINT notes_product_price_check
    CHECK (
        (is_free = true AND price = 0)
        OR
        (is_free = false AND price > 0)
    );

CREATE INDEX IF NOT EXISTS idx_notes_published_order
    ON public.notes (is_published, display_order, created_at);

CREATE INDEX IF NOT EXISTS idx_notes_category
    ON public.notes (category);

CREATE INDEX IF NOT EXISTS idx_notes_exam_name
    ON public.notes (exam_name);

-- Maximum one published free sample.
CREATE UNIQUE INDEX IF NOT EXISTS ux_notes_one_published_free
    ON public.notes (is_free)
    WHERE is_free = true AND is_published = true;

DROP POLICY IF EXISTS "notes_public_select" ON public.notes;
CREATE POLICY "notes_public_select"
ON public.notes
FOR SELECT
TO anon, authenticated
USING (is_published = true OR public.is_admin());

DROP POLICY IF EXISTS "notes_admin_all" ON public.notes;
CREATE POLICY "notes_admin_all"
ON public.notes
FOR ALL
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

GRANT SELECT ON public.notes TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.notes TO authenticated;

-- ------------------------------------------------------------------
-- Extend existing payment/purchase tables without changing existing
-- Test Series behaviour. note_id remains NULL for Test Series rows.
-- ------------------------------------------------------------------

DO $$
BEGIN
    IF to_regclass('public.payments') IS NOT NULL THEN
        ALTER TABLE public.payments
            ADD COLUMN IF NOT EXISTS note_id UUID
            REFERENCES public.notes(id) ON DELETE SET NULL;

        CREATE INDEX IF NOT EXISTS idx_payments_note_id
            ON public.payments (note_id);
    END IF;

    IF to_regclass('public.purchases') IS NOT NULL THEN
        ALTER TABLE public.purchases
            ADD COLUMN IF NOT EXISTS note_id UUID
            REFERENCES public.notes(id) ON DELETE SET NULL;

        CREATE INDEX IF NOT EXISTS idx_purchases_note_id
            ON public.purchases (note_id);
    END IF;
END $$;

-- ------------------------------------------------------------------
-- NOTE ACCESS
-- ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.note_access (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    note_id UUID NOT NULL REFERENCES public.notes(id) ON DELETE CASCADE,
    payment_id UUID NULL REFERENCES public.payments(id) ON DELETE SET NULL,
    access_status TEXT NOT NULL DEFAULT 'active'
        CHECK (access_status IN ('active', 'revoked')),
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NULL,
    UNIQUE (user_id, note_id)
);

CREATE INDEX IF NOT EXISTS idx_note_access_user
    ON public.note_access (user_id);

CREATE INDEX IF NOT EXISTS idx_note_access_note
    ON public.note_access (note_id);

ALTER TABLE public.note_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "note_access_student_select" ON public.note_access;
CREATE POLICY "note_access_student_select"
ON public.note_access
FOR SELECT
TO authenticated
USING (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "note_access_admin_all" ON public.note_access;
CREATE POLICY "note_access_admin_all"
ON public.note_access
FOR ALL
TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

GRANT SELECT ON public.note_access TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.note_access TO authenticated;

-- ------------------------------------------------------------------
-- SAFE STUDENT-FACING VIEW
--
-- The paid Drive URL is returned only when the current user has
-- active, non-expired access.
-- ------------------------------------------------------------------

DROP VIEW IF EXISTS public.user_notes;

CREATE VIEW public.user_notes
WITH (security_invoker = true)
AS
SELECT
    n.id,
    n.title,
    n.slug,
    n.description,
    n.exam_name,
    n.category,
    n.thumbnail_url,
    n.price,
    n.is_free,
    n.is_published,
    n.display_order,
    CASE
        WHEN n.is_free = true THEN n.drive_url
        WHEN na.access_status = 'active'
             AND (na.expires_at IS NULL OR na.expires_at > now())
        THEN n.drive_url
        ELSE NULL
    END AS drive_url,
    CASE
        WHEN n.is_free = true THEN true
        WHEN na.access_status = 'active'
             AND (na.expires_at IS NULL OR na.expires_at > now())
        THEN true
        ELSE false
    END AS has_access
FROM public.notes n
LEFT JOIN public.note_access na
    ON na.note_id = n.id
   AND na.user_id = auth.uid()
WHERE n.is_published = true OR public.is_admin();

GRANT SELECT ON public.user_notes TO authenticated;

-- Keep paid note URLs out of the normal anonymous API surface.
REVOKE ALL ON public.user_notes FROM anon;

COMMIT;

-- ------------------------------------------------------------------
-- IMPORTANT:
-- Do NOT insert a fake/sample Drive URL here.
-- Create exactly one real free sample from the Admin > Study Material
-- page:
--
--   is_free       = true
--   price         = 0
--   is_published  = true
--   drive_url     = actual Google Drive sharing URL
--
-- Every other published note must use:
--
--   is_free       = false
--   price         > 0
--
-- The unique partial index prevents two published free samples.
--
-- Existing public.study_materials from 012_study_material.sql is
-- intentionally NOT deleted. It is legacy and should no longer be
-- used by the new Android Notes implementation.
--
-- Verification:
-- SELECT id,title,price,is_free,is_published,drive_url
-- FROM public.notes ORDER BY display_order,created_at;
--
-- SELECT * FROM public.user_notes;
