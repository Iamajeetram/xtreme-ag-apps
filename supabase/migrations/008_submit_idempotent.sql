-- Xtreme ExamX: make submission safe/idempotent.
-- Prevents a race between timer auto-submit and manual Submit Test.

CREATE OR REPLACE FUNCTION public.submit_test(_attempt_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _user_id UUID;
  _test_id UUID;
  _status TEXT;
  _score NUMERIC(12,4);
  _correct_count INTEGER := 0;
  _wrong_count INTEGER := 0;
  _unattempted_count INTEGER := 0;
BEGIN
  SELECT user_id, test_id, status, score
    INTO _user_id, _test_id, _status, _score
  FROM public.attempts
  WHERE id = _attempt_id;

  IF _user_id IS NULL OR _user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized attempt';
  END IF;

  -- Idempotent: if timer/manual submit raced and the attempt is already
  -- completed, return the stored result instead of throwing an error.
  IF _status = 'completed' THEN
    SELECT COUNT(*) FILTER (WHERE o.option_text <> 'अनुत्तरित प्रश्न' AND o.is_correct),
           COUNT(*) FILTER (WHERE o.option_text <> 'अनुत्तरित प्रश्न' AND NOT o.is_correct)
      INTO _correct_count, _wrong_count
    FROM public.attempt_answers aa
    JOIN public.questions q ON q.id = aa.question_id AND q.test_id = _test_id
    JOIN public.options o ON o.id = aa.chosen_option_id AND o.question_id = q.id
    WHERE aa.attempt_id = _attempt_id;

    SELECT COUNT(*) INTO _unattempted_count
    FROM public.questions q
    WHERE q.test_id = _test_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.attempt_answers aa
        JOIN public.options o ON o.id = aa.chosen_option_id
        WHERE aa.attempt_id = _attempt_id
          AND aa.question_id = q.id
          AND o.question_id = q.id
          AND o.option_text <> 'अनुत्तरित प्रश्न'
      );

    RETURN jsonb_build_object(
      'score', COALESCE(_score,0),
      'correct', COALESCE(_correct_count,0),
      'wrong', COALESCE(_wrong_count,0),
      'unattempted', COALESCE(_unattempted_count,0),
      'already_submitted', true
    );
  END IF;

  IF _status <> 'in_progress' THEN
    RAISE EXCEPTION 'Attempt is not active';
  END IF;

  SELECT COALESCE(SUM(CASE
      WHEN o.option_text = 'अनुत्तरित प्रश्न' THEN 0
      WHEN o.is_correct THEN q.points
      ELSE -q.negative_marks
    END), 0),
    COUNT(*) FILTER (WHERE o.option_text <> 'अनुत्तरित प्रश्न' AND o.is_correct),
    COUNT(*) FILTER (WHERE o.option_text <> 'अनुत्तरित प्रश्न' AND NOT o.is_correct)
  INTO _score, _correct_count, _wrong_count
  FROM public.attempt_answers aa
  JOIN public.questions q ON q.id = aa.question_id AND q.test_id = _test_id
  JOIN public.options o ON o.id = aa.chosen_option_id AND o.question_id = q.id
  WHERE aa.attempt_id = _attempt_id;

  SELECT COUNT(*) INTO _unattempted_count
  FROM public.questions q
  WHERE q.test_id = _test_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.attempt_answers aa
      JOIN public.options o ON o.id = aa.chosen_option_id
      WHERE aa.attempt_id = _attempt_id
        AND aa.question_id = q.id
        AND o.question_id = q.id
        AND o.option_text <> 'अनुत्तरित प्रश्न'
    );

  UPDATE public.attempts
  SET status='completed', finished_at=now(), score=_score
  WHERE id=_attempt_id AND status='in_progress';

  RETURN jsonb_build_object(
    'score', _score,
    'correct', _correct_count,
    'wrong', _wrong_count,
    'unattempted', _unattempted_count,
    'already_submitted', false
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.submit_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.submit_test(UUID) TO authenticated;
