-- Xtreme ExamX: fix free-test RLS, bilingual options, and fast test-runner metadata
-- Run after 006. Safe/idempotent.

-- Free tests inside a paid series must still be readable by students.
DROP POLICY IF EXISTS "tests_view" ON public.tests;
CREATE POLICY "tests_view" ON public.tests FOR SELECT USING (
  public.is_admin() OR (
    tests.is_published = true AND EXISTS (
      SELECT 1 FROM public.test_series ts
      WHERE ts.id=tests.test_series_id AND ts.is_published=true
      AND (
        COALESCE(tests.is_free,false) = true
        OR COALESCE(ts.price,0)=0
        OR EXISTS (
          SELECT 1 FROM public.purchases p
          WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
        )
      )
    )
  )
);

DROP POLICY IF EXISTS "questions_view" ON public.questions;
CREATE POLICY "questions_view" ON public.questions FOR SELECT USING (
  public.is_admin() OR EXISTS (
    SELECT 1 FROM public.tests t
    JOIN public.test_series ts ON ts.id=t.test_series_id
    WHERE t.id=questions.test_id
      AND t.is_published=true
      AND ts.is_published=true
      AND (
        COALESCE(t.is_free,false) = true
        OR COALESCE(ts.price,0)=0
        OR EXISTS (
          SELECT 1 FROM public.purchases p
          WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
        )
      )
  )
);

-- Include English option text in the safe student view; never expose is_correct.
DROP VIEW IF EXISTS public.view_options;
CREATE VIEW public.view_options AS
SELECT
  o.id,
  o.question_id,
  o.option_text,
  o.option_text_en,
  o.sort_order,
  o.created_at
FROM public.options o
JOIN public.questions q ON q.id=o.question_id
JOIN public.tests t ON t.id=q.test_id
JOIN public.test_series ts ON ts.id=t.test_series_id
WHERE t.is_published=true
  AND ts.is_published=true
  AND (
    COALESCE(t.is_free,false) = true
    OR COALESCE(ts.price,0)=0
    OR EXISTS (
      SELECT 1 FROM public.purchases p
      WHERE p.user_id=auth.uid() AND p.test_series_id=ts.id
    )
  );
ALTER VIEW public.view_options OWNER TO postgres;
GRANT SELECT ON public.view_options TO authenticated;

-- Return everything the runner needs in one RPC call, including the original attempt start time.
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
  _started_at TIMESTAMPTZ;
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

  SELECT id, started_at INTO _attempt, _started_at
  FROM public.attempts
  WHERE user_id = _uid AND test_id = _test_id AND status = 'in_progress'
  ORDER BY started_at DESC LIMIT 1;

  IF _attempt IS NULL THEN
    INSERT INTO public.attempts(user_id,test_id,status)
    VALUES(_uid,_test_id,'in_progress')
    RETURNING id, started_at INTO _attempt, _started_at;
  END IF;

  RETURN jsonb_build_object(
    'id',_attempt,
    'test_id',_test_id,
    'title',_test.title,
    'time_limit_minutes',COALESCE(_test.time_limit_minutes,0),
    'default_language',COALESCE(_test.default_language,'hi'),
    'is_free',COALESCE(_test.is_free,false),
    'started_at',_started_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.start_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.start_test(UUID) TO authenticated;
