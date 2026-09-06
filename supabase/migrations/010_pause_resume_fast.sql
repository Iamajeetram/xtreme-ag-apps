-- Xtreme ExamX: pause/resume, exact question restore, single-language fast runner
-- Run after 009. Safe/idempotent.

ALTER TABLE public.attempts
  ADD COLUMN IF NOT EXISTS paused_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS current_question INTEGER NOT NULL DEFAULT 0;

ALTER TABLE public.tests ADD COLUMN IF NOT EXISTS available_from TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.pause_attempt(_attempt_id UUID, _current_question INTEGER DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE _uid UUID:=auth.uid(); _a public.attempts%ROWTYPE;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO _a FROM public.attempts WHERE id=_attempt_id AND status='in_progress';
  IF NOT FOUND OR (_a.user_id<>_uid AND NOT public.is_admin()) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  UPDATE public.attempts SET paused_at=COALESCE(paused_at,now()), current_question=GREATEST(0,_current_question) WHERE id=_attempt_id;
  RETURN jsonb_build_object('ok',true,'paused_at',now(),'current_question',GREATEST(0,_current_question));
END; $$;
REVOKE EXECUTE ON FUNCTION public.pause_attempt(UUID,INTEGER) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.pause_attempt(UUID,INTEGER) TO authenticated;

CREATE OR REPLACE FUNCTION public.update_attempt_position(_attempt_id UUID, _current_question INTEGER)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  UPDATE public.attempts SET current_question=GREATEST(0,_current_question)
  WHERE id=_attempt_id AND user_id=auth.uid() AND status='in_progress' AND paused_at IS NULL;
END; $$;
REVOKE EXECUTE ON FUNCTION public.update_attempt_position(UUID,INTEGER) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.update_attempt_position(UUID,INTEGER) TO authenticated;

-- Fast start: resumes a paused attempt by shifting its start time by the pause duration,
-- and returns test metadata + questions + safe options + saved answers in one round trip.
CREATE OR REPLACE FUNCTION public.start_test(_test_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  _uid UUID:=auth.uid(); _test RECORD; _attempt RECORD; _limit INTEGER; _paused BOOLEAN:=false;
  _result JSONB;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT t.*,ts.is_published AS series_published,ts.price AS series_price
  INTO _test FROM public.tests t JOIN public.test_series ts ON ts.id=t.test_series_id WHERE t.id=_test_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Test not found'; END IF;
  IF NOT public.is_admin() THEN
    IF NOT (_test.is_published AND _test.series_published) THEN RAISE EXCEPTION 'This test is not available'; END IF;
    IF _test.available_from IS NOT NULL AND _test.available_from > now() THEN RAISE EXCEPTION 'This test is not available yet'; END IF;
    IF NOT COALESCE(_test.is_free,false) AND COALESCE(_test.series_price,0)>0 AND NOT EXISTS(
      SELECT 1 FROM public.purchases p WHERE p.user_id=_uid AND p.test_series_id=_test.test_series_id
    ) THEN RAISE EXCEPTION 'Subscription required'; END IF;
  END IF;
  _limit:=COALESCE(_test.time_limit_minutes,0);
  SELECT * INTO _attempt FROM public.attempts WHERE user_id=_uid AND test_id=_test_id AND status='in_progress' ORDER BY started_at DESC LIMIT 1;
  IF _attempt IS NOT NULL AND _attempt.paused_at IS NOT NULL THEN
    UPDATE public.attempts
      SET started_at=started_at+(now()-paused_at), paused_at=NULL
      WHERE id=_attempt.id
      RETURNING * INTO _attempt;
  END IF;
  IF _attempt IS NOT NULL AND _limit>0 AND _attempt.started_at+make_interval(mins=>_limit)<=now() THEN
    PERFORM public.submit_test(_attempt.id); _attempt:=NULL;
  END IF;
  IF _attempt.id IS NULL THEN
    INSERT INTO public.attempts(user_id,test_id,status,current_question) VALUES(_uid,_test_id,'in_progress',0)
    RETURNING * INTO _attempt;
  END IF;

  SELECT jsonb_build_object(
    'id',_attempt.id,'test_id',_test_id,'title',_test.title,
    'time_limit_minutes',_limit,'default_language','hi','is_free',COALESCE(_test.is_free,false),
    'started_at',_attempt.started_at,'current_question',COALESCE(_attempt.current_question,0),
    'questions',COALESCE((SELECT jsonb_agg(qj ORDER BY (qj->>'sort_order')::int, qj->>'id') FROM (
      SELECT jsonb_build_object(
        'id',q.id,'question_text',q.question_text,'question_type',q.question_type,
        'points',q.points,'negative_marks',q.negative_marks,'sort_order',q.sort_order,
        'options',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',o.id,'option_text',o.option_text,'sort_order',o.sort_order)
          ORDER BY o.sort_order,o.id) FROM public.options o WHERE o.question_id=q.id),'[]'::jsonb)
      ) qj
      FROM public.questions q WHERE q.test_id=_test_id
    ) x),'[]'::jsonb),
    'answers',COALESCE((SELECT jsonb_agg(jsonb_build_object('question_id',aa.question_id,'chosen_option_id',aa.chosen_option_id,'text_answer',aa.text_answer))
      FROM public.attempt_answers aa WHERE aa.attempt_id=_attempt.id),'[]'::jsonb)
  ) INTO _result;
  RETURN _result;
END; $$;
REVOKE EXECUTE ON FUNCTION public.start_test(UUID) FROM public,anon;
GRANT EXECUTE ON FUNCTION public.start_test(UUID) TO authenticated;
