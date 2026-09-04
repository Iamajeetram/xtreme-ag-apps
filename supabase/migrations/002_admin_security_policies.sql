-- 002_admin_security_policies.sql (FINAL HARDENED)

-- ==================================================================
-- 1. SCHEMA UPDATES
-- ==================================================================
ALTER TABLE public.questions 
ADD COLUMN IF NOT EXISTS negative_marks NUMERIC(10,2) NOT NULL DEFAULT 0;

-- ==================================================================
-- 2. SECURITY DEFINER HELPERS
-- ==================================================================

-- Safely check admin status without RLS recursion
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
  -- SECURITY DEFINER bypasses RLS for this specific query
  RETURN EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND is_admin = true
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Safely get current is_admin status for a specific user to prevent escalation
CREATE OR REPLACE FUNCTION public.get_stored_admin_status(_user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
  RETURN (SELECT is_admin FROM public.profiles WHERE id = _user_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ==================================================================
-- 3. SECURE VIEWS
-- ==================================================================
DROP VIEW IF EXISTS public.view_options;
CREATE OR REPLACE VIEW public.view_options 
WITH (security_invoker = true) -- Ensures RLS on underlying tables is respected
AS
SELECT o.id, o.question_id, o.option_text, o.sort_order, o.created_at
FROM public.options o
JOIN public.questions q ON o.question_id = q.id
JOIN public.tests t ON q.test_id = t.id
JOIN public.test_series ts ON t.test_series_id = ts.id
WHERE t.is_published = true AND ts.is_published = true;

-- ==================================================================
-- 4. RLS POLICIES
-- ==================================================================

-- PROFILES
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "profiles_select_policy" ON public.profiles;
CREATE POLICY "profiles_select_policy" ON public.profiles FOR SELECT 
USING (auth.uid() = id OR public.is_admin());

DROP POLICY IF EXISTS "profiles_update_policy" ON public.profiles;
CREATE POLICY "profiles_update_policy" ON public.profiles FOR UPDATE 
USING (auth.uid() = id OR public.is_admin())
WITH CHECK (
  -- If not admin, they cannot change their own is_admin flag
  (public.is_admin()) OR (is_admin = public.get_stored_admin_status(id))
);

-- CONTENT TABLES (test_series, tests, questions)
ALTER TABLE public.test_series ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ts_select" ON public.test_series;
CREATE POLICY "ts_select" ON public.test_series FOR SELECT USING (is_published = true OR public.is_admin());

ALTER TABLE public.tests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tests_select" ON public.tests;
CREATE POLICY "tests_select" ON public.tests FOR SELECT USING (is_published = true OR public.is_admin());

ALTER TABLE public.questions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "questions_select" ON public.questions;
CREATE POLICY "questions_select" ON public.questions FOR SELECT 
USING (
  (EXISTS (SELECT 1 FROM public.tests t WHERE t.id = questions.test_id AND t.is_published = true)) 
  OR public.is_admin()
);

-- OPTIONS (STUDENTS DENIED DIRECT SELECT)
ALTER TABLE public.options ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "options_admin" ON public.options;
CREATE POLICY "options_admin" ON public.options FOR ALL USING (public.is_admin());

-- ATTEMPTS (Immutability for Students)
ALTER TABLE public.attempts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "attempts_insert" ON public.attempts;
CREATE POLICY "attempts_insert" ON public.attempts FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "attempts_select" ON public.attempts;
CREATE POLICY "attempts_select" ON public.attempts FOR SELECT USING (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "attempts_update" ON public.attempts;
CREATE POLICY "attempts_update" ON public.attempts FOR UPDATE 
USING (auth.uid() = user_id AND status = 'in_progress')
WITH CHECK (
  -- Students can only set status to 'abandoned'. Score/Completed handled by RPC.
  (status = 'abandoned') AND 
  (score = (SELECT score FROM public.attempts WHERE id = id)) AND
  (test_id = (SELECT test_id FROM public.attempts WHERE id = id))
);

-- ATTEMPT ANSWERS (Locked when attempt is not in_progress)
ALTER TABLE public.attempt_answers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "answers_all" ON public.attempt_answers;
CREATE POLICY "answers_all" ON public.attempt_answers FOR ALL 
USING (
  EXISTS (
    SELECT 1 FROM public.attempts a 
    WHERE a.id = attempt_answers.attempt_id 
    AND a.user_id = auth.uid() 
    AND a.status = 'in_progress'
  )
);

DROP POLICY IF EXISTS "answers_select_view" ON public.attempt_answers;
CREATE POLICY "answers_select_view" ON public.attempt_answers FOR SELECT 
USING (
  EXISTS (SELECT 1 FROM public.attempts a WHERE a.id = attempt_answers.attempt_id AND a.user_id = auth.uid())
  OR public.is_admin()
);

-- PAYMENTS / PURCHASES
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "payments_student" ON public.payments;
CREATE POLICY "payments_student" ON public.payments FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "payments_insert" ON public.payments FOR INSERT WITH CHECK (auth.uid() = user_id);

ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "purchases_student" ON public.purchases;
CREATE POLICY "purchases_student" ON public.purchases FOR SELECT USING (auth.uid() = user_id);

-- ADMIN GLOBAL POLICIES
CREATE POLICY "admin_all" ON public.test_series FOR ALL USING (public.is_admin());
CREATE POLICY "admin_all" ON public.tests FOR ALL USING (public.is_admin());
CREATE POLICY "admin_all" ON public.questions FOR ALL USING (public.is_admin());
CREATE POLICY "admin_all" ON public.payments FOR ALL USING (public.is_admin());
CREATE POLICY "admin_all" ON public.purchases FOR ALL USING (public.is_admin());

ALTER TABLE public.admin_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_audit_select" ON public.admin_audit FOR SELECT USING (public.is_admin());

-- ==================================================================
-- 5. SECURE SCORING RPC
-- ==================================================================
CREATE OR REPLACE FUNCTION public.submit_test(_attempt_id UUID)
RETURNS JSONB AS $$
DECLARE
  _score NUMERIC := 0;
  _correct INTEGER := 0;
  _wrong INTEGER := 0;
  _user_id UUID;
BEGIN
  -- 1. Validate Ownership & State
  SELECT user_id INTO _user_id FROM public.attempts WHERE id = _attempt_id AND status = 'in_progress';
  IF _user_id IS NULL OR _user_id != auth.uid() THEN
    RAISE EXCEPTION 'Attempt not found or already submitted';
  END IF;

  -- 2. Authoritative Scoring
  SELECT 
    COALESCE(SUM(CASE WHEN o.is_correct = true THEN q.points ELSE -q.negative_marks END), 0),
    COUNT(*) FILTER (WHERE o.is_correct = true),
    COUNT(*) FILTER (WHERE o.is_correct = false)
  INTO _score, _correct, _wrong
  FROM public.attempt_answers aa
  JOIN public.options o ON aa.chosen_option_id = o.id
  JOIN public.questions q ON aa.question_id = q.id
  WHERE aa.attempt_id = _attempt_id;

  -- 3. Finalize
  UPDATE public.attempts
  SET status = 'completed', 
      finished_at = now(),
      score = _score
  WHERE id = _attempt_id;

  RETURN jsonb_build_object('score', _score, 'correct', _correct, 'wrong', _wrong);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 6. RPC GRANTS
REVOKE EXECUTE ON FUNCTION public.submit_test(UUID) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.submit_test(UUID) TO authenticated;
