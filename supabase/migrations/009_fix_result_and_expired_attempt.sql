-- Xtreme ExamX: fix result RPC schema mismatch and stale attempts.
-- Run after 008. Safe/idempotent.

-- The 005 migration referenced questions.order_index, but the live schema uses
-- questions.sort_order. This replacement also returns the shape expected by the
-- current test runner (items[]).
CREATE OR REPLACE FUNCTION public.get_test_result(_attempt_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _owner UUID;
  _test UUID;
  _result JSONB;
BEGIN
  SELECT user_id, test_id INTO _owner, _test
  FROM public.attempts
  WHERE id = _attempt_id AND status = 'completed';

  IF _owner IS NULL OR (_owner <> auth.uid() AND NOT public.is_admin()) THEN
    RAISE EXCEPTION 'Unauthorized or result not available';
  END IF;

  WITH numbered AS (
    SELECT
      q.id, q.question_text, q.points, q.negative_marks, q.explanation, q.sort_order,
      row_number() OVER (ORDER BY q.sort_order, q.id) AS question_no
    FROM public.questions q
    WHERE q.test_id = _test
  )
  SELECT jsonb_build_object(
    'attempt', to_jsonb(a),
    'items', COALESCE(jsonb_agg(
      jsonb_build_object(
        'question_id', n.id,
        'question_no', n.question_no,
        'question_text', n.question_text,
        'points', n.points,
        'negative_marks', n.negative_marks,
        'explanation', n.explanation,
        'selected_option_id', aa.chosen_option_id,
        'selected_option_text', yo.option_text,
        'correct_option_text', co.option_text,
        'is_unanswered', (aa.id IS NULL OR yo.option_text = 'अनुत्तरित प्रश्न'),
        'is_correct', (yo.id IS NOT NULL AND yo.option_text <> 'अनुत्तरित प्रश्न' AND yo.is_correct),
        'marks', CASE
          WHEN aa.id IS NULL OR yo.option_text = 'अनुत्तरित प्रश्न' THEN 0
          WHEN yo.is_correct THEN n.points
          ELSE -n.negative_marks
        END
      ) ORDER BY n.sort_order, n.id
    ) FILTER (WHERE n.id IS NOT NULL), '[]'::jsonb)
  ) INTO _result
  FROM public.attempts a
  JOIN numbered n ON true
  LEFT JOIN public.attempt_answers aa
    ON aa.attempt_id = a.id AND aa.question_id = n.id
  LEFT JOIN public.options yo ON yo.id = aa.chosen_option_id
  LEFT JOIN public.options co ON co.question_id = n.id AND co.is_correct = true
  WHERE a.id = _attempt_id
  GROUP BY a.id;

  RETURN _result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_test_result(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_test_result(UUID) TO authenticated;

-- Replace start_test so an old in-progress attempt whose allotted time has
-- already expired cannot reopen with a 00:00:00 timer. It is completed first,
-- then a fresh attempt is created.
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
  _limit INTEGER;
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

  _limit := COALESCE(_test.time_limit_minutes, 0);

  SELECT id, started_at INTO _attempt, _started_at
  FROM public.attempts
  WHERE user_id = _uid AND test_id = _test_id AND status = 'in_progress'
  ORDER BY started_at DESC LIMIT 1;

  IF _attempt IS NOT NULL AND _limit > 0
     AND _started_at + make_interval(mins => _limit) <= now() THEN
    -- Let the normal secure scorer finalize the expired attempt.
    PERFORM public.submit_test(_attempt);
    _attempt := NULL;
    _started_at := NULL;
  END IF;

  IF _attempt IS NULL THEN
    INSERT INTO public.attempts(user_id,test_id,status)
    VALUES(_uid,_test_id,'in_progress')
    RETURNING id, started_at INTO _attempt, _started_at;
  END IF;

  RETURN jsonb_build_object(
    'id',_attempt,
    'test_id',_test_id,
    'title',_test.title,
    'time_limit_minutes',_limit,
    'default_language',COALESCE(_test.default_language,'hi'),
    'is_free',COALESCE(_test.is_free,false),
    'started_at',_started_at
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.start_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.start_test(UUID) TO authenticated;
