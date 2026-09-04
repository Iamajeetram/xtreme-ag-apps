-- Xtreme ExamX: per-test free access + bilingual content fields
-- Run after 003/004/005. Safe/idempotent: no table/data deletion.

ALTER TABLE public.tests
  ADD COLUMN IF NOT EXISTS default_language TEXT NOT NULL DEFAULT 'hi',
  ADD COLUMN IF NOT EXISTS is_free BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.questions
  ADD COLUMN IF NOT EXISTS content_language TEXT NOT NULL DEFAULT 'hi',
  ADD COLUMN IF NOT EXISTS question_text_en TEXT,
  ADD COLUMN IF NOT EXISTS explanation_en TEXT;

ALTER TABLE public.options
  ADD COLUMN IF NOT EXISTS option_text_en TEXT;

-- First/free tests can be started without purchasing the whole series.
-- Paid tests in a paid series require an approved purchase.
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
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT t.*, ts.is_published AS series_published, ts.price AS series_price
  INTO _test
  FROM public.tests t
  JOIN public.test_series ts ON ts.id = t.test_series_id
  WHERE t.id = _test_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Test not found'; END IF;

  IF NOT public.is_admin() THEN
    IF NOT (_test.is_published AND _test.series_published) THEN
      RAISE EXCEPTION 'This test is not available';
    END IF;
    IF NOT COALESCE(_test.is_free, false)
       AND COALESCE(_test.series_price,0) > 0
       AND NOT EXISTS (
         SELECT 1 FROM public.purchases p
         WHERE p.user_id = _uid AND p.test_series_id = _test.test_series_id
       ) THEN
      RAISE EXCEPTION 'Subscription required';
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
