-- 014_notes_payments_and_live_tests.sql
-- Run AFTER the existing migrations in this GitHub project.
-- This migration completes the Notes purchase flow and makes published Test
-- metadata visible in the Test Series page even before purchase.
-- It does not delete the legacy study_materials table.

BEGIN;

-- ================================================================
-- 1. Ensure Notes objects exist, so this works whether 013 was run
--    or not.
-- ================================================================
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
ALTER TABLE public.notes DROP CONSTRAINT IF EXISTS notes_product_price_check;
ALTER TABLE public.notes DROP CONSTRAINT IF EXISTS notes_free_price_check;
ALTER TABLE public.notes ADD CONSTRAINT notes_product_price_check
CHECK ((is_free = true AND price = 0) OR (is_free = false AND price > 0));

CREATE UNIQUE INDEX IF NOT EXISTS ux_notes_one_published_free
ON public.notes (is_free)
WHERE is_free = true AND is_published = true;

DROP POLICY IF EXISTS "notes_public_select" ON public.notes;
DROP POLICY IF EXISTS "notes_public_read" ON public.notes;
DROP POLICY IF EXISTS "notes_public_select" ON public.notes;
CREATE POLICY "notes_public_select" ON public.notes
FOR SELECT TO anon, authenticated
USING (is_published = true OR public.is_admin());

DROP POLICY IF EXISTS "notes_admin_all" ON public.notes;
CREATE POLICY "notes_admin_all" ON public.notes
FOR ALL TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

GRANT SELECT ON public.notes TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.notes TO authenticated;

-- ================================================================
-- 2. Existing payment/purchase tables must support either a
--    Test Series payment OR a Note payment.
-- ================================================================
ALTER TABLE public.payments
  ALTER COLUMN test_series_id DROP NOT NULL;

ALTER TABLE public.purchases
  ALTER COLUMN test_series_id DROP NOT NULL;

ALTER TABLE public.payments
  ADD COLUMN IF NOT EXISTS note_id UUID REFERENCES public.notes(id) ON DELETE SET NULL;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS note_id UUID REFERENCES public.notes(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_payments_note_id ON public.payments(note_id);
CREATE INDEX IF NOT EXISTS idx_purchases_note_id ON public.purchases(note_id);

-- Existing Test Series uniqueness remains. Notes get their own uniqueness.
CREATE UNIQUE INDEX IF NOT EXISTS ux_purchases_user_note
ON public.purchases(user_id, note_id);

-- A payment must belong to exactly one product type.
ALTER TABLE public.payments DROP CONSTRAINT IF EXISTS payments_one_product_check;
ALTER TABLE public.payments ADD CONSTRAINT payments_one_product_check
CHECK (
  (test_series_id IS NOT NULL AND note_id IS NULL)
  OR
  (test_series_id IS NULL AND note_id IS NOT NULL)
);

ALTER TABLE public.purchases DROP CONSTRAINT IF EXISTS purchases_one_product_check;
ALTER TABLE public.purchases ADD CONSTRAINT purchases_one_product_check
CHECK (
  (test_series_id IS NOT NULL AND note_id IS NULL)
  OR
  (test_series_id IS NULL AND note_id IS NOT NULL)
);

-- Students must use the secure RPCs for payment creation.
DROP POLICY IF EXISTS "payments_insert" ON public.payments;
DROP POLICY IF EXISTS "pay_student_insert" ON public.payments;

-- ================================================================
-- 3. Note access.
-- ================================================================
CREATE TABLE IF NOT EXISTS public.note_access (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  note_id UUID NOT NULL REFERENCES public.notes(id) ON DELETE CASCADE,
  payment_id UUID NULL REFERENCES public.payments(id) ON DELETE SET NULL,
  access_status TEXT NOT NULL DEFAULT 'active'
    CHECK (access_status IN ('active','revoked')),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(user_id,note_id)
);

ALTER TABLE public.note_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "note_access_student_select" ON public.note_access;
CREATE POLICY "note_access_student_select" ON public.note_access
FOR SELECT TO authenticated
USING (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "note_access_admin_all" ON public.note_access;
CREATE POLICY "note_access_admin_all" ON public.note_access
FOR ALL TO authenticated
USING (public.is_admin())
WITH CHECK (public.is_admin());

GRANT SELECT ON public.note_access TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.note_access TO authenticated;

-- ================================================================
-- 4. Student-safe Notes view.
-- Paid Google Drive URL is NULL until access is active.
-- ================================================================
DROP VIEW IF EXISTS public.user_notes;
CREATE VIEW public.user_notes
WITH (security_invoker = true)
AS
SELECT
  n.id,n.title,n.slug,n.description,n.exam_name,n.category,n.thumbnail_url,
  n.price,n.is_free,n.is_published,n.display_order,
  CASE
    WHEN n.is_free THEN n.drive_url
    WHEN a.access_status='active'
      AND (a.expires_at IS NULL OR a.expires_at > now())
    THEN n.drive_url
    ELSE NULL
  END AS drive_url,
  (
    n.is_free OR (
      a.access_status='active'
      AND (a.expires_at IS NULL OR a.expires_at > now())
    )
  ) AS has_access
FROM public.notes n
LEFT JOIN public.note_access a
  ON a.note_id=n.id AND a.user_id=auth.uid()
WHERE n.is_published=true OR public.is_admin();

GRANT SELECT ON public.user_notes TO authenticated;
REVOKE ALL ON public.user_notes FROM anon;

-- ================================================================
-- 5. Secure Note payment creation.
-- Amount comes from the current Note row, not from the browser.
-- ================================================================
CREATE OR REPLACE FUNCTION public.create_note_payment(
  _note_id UUID,
  _name TEXT,
  _mobile TEXT,
  _utr TEXT,
  _payment_time TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  _uid UUID := auth.uid();
  _note RECORD;
  _id UUID;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT * INTO _note
  FROM public.notes
  WHERE id=_note_id AND is_published=true AND is_free=false;

  IF NOT FOUND THEN RAISE EXCEPTION 'Paid Note not available'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.note_access
    WHERE user_id=_uid AND note_id=_note_id
      AND access_status='active'
      AND (expires_at IS NULL OR expires_at > now())
  ) THEN
    RAISE EXCEPTION 'Note already unlocked';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.payments
    WHERE user_id=_uid AND note_id=_note_id AND status='PENDING'
  ) THEN
    RAISE EXCEPTION 'Payment is already pending';
  END IF;

  IF COALESCE(length(trim(_name)),0)=0
     OR COALESCE(length(trim(_mobile)),0)=0
     OR COALESCE(length(trim(_utr)),0)=0
  THEN RAISE EXCEPTION 'Name, mobile and UTR are required'; END IF;

  INSERT INTO public.payments(
    user_id,test_series_id,note_id,name,mobile,amount,utr,payment_time,status
  )
  VALUES(
    _uid,NULL,_note_id,trim(_name),trim(_mobile),_note.price,trim(_utr),
    _payment_time,'PENDING'
  )
  RETURNING id INTO _id;

  RETURN jsonb_build_object('id',_id,'amount',_note.price,'status','PENDING');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.create_note_payment(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.create_note_payment(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO authenticated;

-- ================================================================
-- 6. Replace payment approval so existing Test Series approvals
--    still work, while Note approvals also create note_access.
-- ================================================================
CREATE OR REPLACE FUNCTION public.approve_payment(
  _payment_id UUID,
  _admin_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  _p RECORD;
  _purchase UUID;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;

  SELECT * INTO _p
  FROM public.payments
  WHERE id=_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF _p.status <> 'PENDING' THEN RAISE EXCEPTION 'Payment is already reviewed'; END IF;

  UPDATE public.payments
  SET status='APPROVED',admin_note=_admin_note,
      reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now()
  WHERE id=_payment_id;

  IF _p.note_id IS NOT NULL THEN
    INSERT INTO public.purchases(user_id,test_series_id,note_id,source_payment_id)
    VALUES(_p.user_id,NULL,_p.note_id,_payment_id)
    ON CONFLICT (user_id,note_id) DO NOTHING
    RETURNING id INTO _purchase;

    INSERT INTO public.note_access(user_id,note_id,payment_id,access_status)
    VALUES(_p.user_id,_p.note_id,_payment_id,'active')
    ON CONFLICT (user_id,note_id)
    DO UPDATE SET
      payment_id=EXCLUDED.payment_id,
      access_status='active',
      granted_at=now(),
      expires_at=NULL;

    RETURN jsonb_build_object(
      'payment_id',_payment_id,'purchase_id',_purchase,
      'note_id',_p.note_id,'status','APPROVED'
    );
  END IF;

  INSERT INTO public.purchases(user_id,test_series_id,source_payment_id)
  VALUES(_p.user_id,_p.test_series_id,_payment_id)
  ON CONFLICT (user_id,test_series_id) DO NOTHING
  RETURNING id INTO _purchase;

  RETURN jsonb_build_object(
    'payment_id',_payment_id,'purchase_id',_purchase,
    'test_series_id',_p.test_series_id,'status','APPROVED'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.approve_payment(UUID,TEXT) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.approve_payment(UUID,TEXT) TO authenticated;

-- ================================================================
-- 7. Published Test metadata must be visible before purchase.
-- Questions/options remain protected by the existing paid-access RLS.
-- start_test() remains the authoritative gate.
-- ================================================================
DROP POLICY IF EXISTS "tests_view" ON public.tests;
CREATE POLICY "tests_view" ON public.tests
FOR SELECT TO authenticated
USING (
  public.is_admin()
  OR (
    tests.is_published=true
    AND EXISTS (
      SELECT 1 FROM public.test_series ts
      WHERE ts.id=tests.test_series_id
        AND ts.is_published=true
    )
  )
);

COMMIT;

-- Verification:
-- SELECT id,title,is_published,is_free FROM public.tests ORDER BY updated_at DESC;
-- SELECT id,title,is_free,price,is_published FROM public.notes ORDER BY display_order,created_at;
-- SELECT id,user_id,test_series_id,note_id,status FROM public.payments ORDER BY created_at DESC;
