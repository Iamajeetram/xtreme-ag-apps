-- Xtreme ExamX: student access, secure test start, and payment approval
-- Run only after reviewing. Safe: no table/data deletion.

-- 1) Secure test start: admin can start any test (including drafts); students need
-- a published test + published series + either free series or an unlocked purchase.
CREATE OR REPLACE FUNCTION public.start_test(_test_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid UUID := auth.uid();
  _test RECORD;
  _attempt UUID;
  _admin BOOLEAN;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT t.*, ts.is_published AS series_published, ts.price AS series_price
  INTO _test
  FROM public.tests t
  JOIN public.test_series ts ON ts.id = t.test_series_id
  WHERE t.id = _test_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Test not found'; END IF;
  _admin := public.is_admin();
  IF NOT _admin THEN
    IF NOT (_test.is_published AND _test.series_published) THEN
      RAISE EXCEPTION 'This test is not available';
    END IF;
    IF COALESCE(_test.series_price,0) > 0 AND NOT EXISTS (
      SELECT 1 FROM public.purchases p
      WHERE p.user_id = _uid AND p.test_series_id = _test.test_series_id
    ) THEN
      RAISE EXCEPTION 'Purchase required';
    END IF;
  END IF;

  SELECT id INTO _attempt
  FROM public.attempts
  WHERE user_id = _uid AND test_id = _test_id AND status = 'in_progress'
  ORDER BY started_at DESC LIMIT 1;
  IF _attempt IS NULL THEN
    INSERT INTO public.attempts(user_id,test_id,status)
    VALUES(_uid,_test_id,'in_progress')
    RETURNING id INTO _attempt;
  END IF;
  RETURN jsonb_build_object('id',_attempt,'test_id',_test_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.start_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.start_test(UUID) TO authenticated;

-- 2) Payment creation: server calculates the amount from current series pricing.
CREATE OR REPLACE FUNCTION public.create_payment(
  _test_series_id UUID,
  _name TEXT,
  _mobile TEXT,
  _utr TEXT,
  _payment_time TIMESTAMPTZ
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _uid UUID := auth.uid();
  _series RECORD;
  _amount NUMERIC(10,2);
  _id UUID;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO _series FROM public.test_series WHERE id=_test_series_id AND is_published=true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Test series not available'; END IF;
  IF EXISTS (SELECT 1 FROM public.purchases WHERE user_id=_uid AND test_series_id=_test_series_id) THEN
    RAISE EXCEPTION 'Series already unlocked';
  END IF;
  _amount := CASE WHEN _series.is_launch_offer AND _series.launch_price IS NOT NULL
                  THEN _series.launch_price ELSE _series.price END;
  IF COALESCE(length(trim(_name)),0)=0 OR COALESCE(length(trim(_mobile)),0)=0 OR COALESCE(length(trim(_utr)),0)=0 THEN
    RAISE EXCEPTION 'Name, mobile and UTR are required';
  END IF;
  INSERT INTO public.payments(user_id,test_series_id,name,mobile,amount,utr,payment_time,status)
  VALUES(_uid,_test_series_id,trim(_name),trim(_mobile),_amount,trim(_utr),_payment_time,'PENDING')
  RETURNING id INTO _id;
  RETURN jsonb_build_object('id',_id,'amount',_amount,'status','PENDING');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.create_payment(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_payment(UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ) TO authenticated;

-- Normal users should use the secure payment function instead of direct inserts.
DROP POLICY IF EXISTS "pay_student_insert" ON public.payments;

-- 3) Admin payment approval/rejection. Purchase is created atomically on approval.
CREATE OR REPLACE FUNCTION public.approve_payment(_payment_id UUID, _admin_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE _p RECORD; _purchase UUID;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  SELECT * INTO _p FROM public.payments WHERE id=_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF _p.status <> 'PENDING' THEN RAISE EXCEPTION 'Payment is already reviewed'; END IF;
  UPDATE public.payments SET status='APPROVED',admin_note=_admin_note,reviewed_by=auth.uid(),reviewed_at=now() WHERE id=_payment_id;
  INSERT INTO public.purchases(user_id,test_series_id,source_payment_id)
  VALUES(_p.user_id,_p.test_series_id,_payment_id)
  ON CONFLICT (user_id,test_series_id) DO NOTHING
  RETURNING id INTO _purchase;
  RETURN jsonb_build_object('payment_id',_payment_id,'purchase_id',_purchase,'status','APPROVED');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.approve_payment(UUID,TEXT) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.approve_payment(UUID,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_payment(_payment_id UUID, _admin_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  UPDATE public.payments SET status='REJECTED',admin_note=_admin_note,reviewed_by=auth.uid(),reviewed_at=now()
  WHERE id=_payment_id AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found or already reviewed'; END IF;
  RETURN jsonb_build_object('payment_id',_payment_id,'status','REJECTED');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reject_payment(UUID,TEXT) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reject_payment(UUID,TEXT) TO authenticated;

-- 4) Correct paid/free access rules for tests and questions.
DROP POLICY IF EXISTS "tests_view" ON public.tests;
CREATE POLICY "tests_view" ON public.tests FOR SELECT USING (
  public.is_admin() OR (
    tests.is_published = true AND EXISTS (
      SELECT 1 FROM public.test_series ts
      WHERE ts.id=tests.test_series_id AND ts.is_published=true
      AND (COALESCE(ts.price,0)=0 OR EXISTS (
        SELECT 1 FROM public.purchases p WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
      ))
    )
  )
);

DROP POLICY IF EXISTS "questions_view" ON public.questions;
CREATE POLICY "questions_view" ON public.questions FOR SELECT USING (
  public.is_admin() OR EXISTS (
    SELECT 1 FROM public.tests t
    JOIN public.test_series ts ON ts.id=t.test_series_id
    WHERE t.id=questions.test_id AND t.is_published=true AND ts.is_published=true
    AND (COALESCE(ts.price,0)=0 OR EXISTS (
      SELECT 1 FROM public.purchases p WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
    ))
  )
);

-- Safe options view must follow the same paid/free access rule.
DROP VIEW IF EXISTS public.view_options;
CREATE VIEW public.view_options AS
SELECT o.id,o.question_id,o.option_text,o.sort_order,o.created_at
FROM public.options o
JOIN public.questions q ON q.id=o.question_id
JOIN public.tests t ON t.id=q.test_id
JOIN public.test_series ts ON ts.id=t.test_series_id
WHERE t.is_published=true AND ts.is_published=true
AND (COALESCE(ts.price,0)=0 OR EXISTS (
  SELECT 1 FROM public.purchases p WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
));
ALTER VIEW public.view_options OWNER TO postgres;
GRANT SELECT ON public.view_options TO authenticated;
