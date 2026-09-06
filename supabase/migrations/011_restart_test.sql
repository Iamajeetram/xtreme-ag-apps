-- Xtreme ExamX: restart a paused/in-progress attempt as a fresh attempt.
-- Run after 010. Safe/idempotent.

CREATE OR REPLACE FUNCTION public.restart_test(_test_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  _uid UUID := auth.uid();
  _attempt RECORD;
BEGIN
  IF _uid IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  SELECT * INTO _attempt
  FROM public.attempts
  WHERE user_id=_uid AND test_id=_test_id AND status='in_progress'
  ORDER BY started_at DESC
  LIMIT 1;

  IF _attempt IS NOT NULL THEN
    UPDATE public.attempts
      SET status='abandoned', paused_at=NULL
      WHERE id=_attempt.id;
  END IF;

  RETURN public.start_test(_test_id);
END; $$;

REVOKE EXECUTE ON FUNCTION public.restart_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.restart_test(UUID) TO authenticated;
