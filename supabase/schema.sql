-- supabase/schema.sql
-- Draft production-oriented PostgreSQL schema for Xtreme AG Apps (Supabase)
-- NOTE: This file is a repository artifact only. Do NOT apply to production until reviewed.

-- Enable pgcrypto for gen_random_uuid() if not already available in the target database.
-- In Supabase you can enable this extension in SQL editor if allowed.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Reusable function to set updated_at automatically on UPDATE
CREATE OR REPLACE FUNCTION public.trigger_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- ==================================================================
-- profiles
-- One-to-one with auth.users. Use auth.users as the source of truth for credentials.
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT,
  mobile TEXT,
  is_admin BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profiles_mobile ON public.profiles (mobile);

-- Optional trigger to keep updated_at current
CREATE TRIGGER trg_profiles_set_timestamp
BEFORE UPDATE ON public.profiles
FOR EACH ROW
EXECUTE PROCEDURE public.trigger_set_timestamp();

-- ==================================================================
-- test_series
-- Represents a purchasable collection of tests (a Test Series).
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.test_series (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  description TEXT,
  price NUMERIC(10,2) NOT NULL DEFAULT 0,
  is_published BOOLEAN NOT NULL DEFAULT false,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_test_series_slug ON public.test_series (slug);

CREATE TRIGGER trg_test_series_set_timestamp
BEFORE UPDATE ON public.test_series
FOR EACH ROW
EXECUTE PROCEDURE public.trigger_set_timestamp();

-- ==================================================================
-- tests
-- Individual tests within a test_series
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.tests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  test_series_id UUID NOT NULL REFERENCES public.test_series(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  time_limit_minutes INTEGER,
  is_published BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_tests_test_series_id ON public.tests (test_series_id);

CREATE TRIGGER trg_tests_set_timestamp
BEFORE UPDATE ON public.tests
FOR EACH ROW
EXECUTE PROCEDURE public.trigger_set_timestamp();

-- ==================================================================
-- questions
-- Questions belong to a test. question_type constrained to single/multi/text
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.questions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  test_id UUID NOT NULL REFERENCES public.tests(id) ON DELETE CASCADE,
  question_text TEXT NOT NULL,
  question_type TEXT NOT NULL DEFAULT 'single',
  points NUMERIC(10,2) NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT question_type_check CHECK (question_type IN ('single','multi','text'))
);

CREATE INDEX IF NOT EXISTS idx_questions_test_id ON public.questions (test_id);

CREATE TRIGGER trg_questions_set_timestamp
BEFORE UPDATE ON public.questions
FOR EACH ROW
EXECUTE PROCEDURE public.trigger_set_timestamp();

-- ==================================================================
-- options
-- Answer options for questions. is_correct must not be exposed to normal users.
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  option_text TEXT NOT NULL,
  is_correct BOOLEAN NOT NULL DEFAULT false,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_options_question_id ON public.options (question_id);

-- ==================================================================
-- attempts
-- When a user takes a test, an attempt row is created.
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.attempts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  test_id UUID NOT NULL REFERENCES public.tests(id) ON DELETE CASCADE,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  score NUMERIC(10,2),
  status TEXT NOT NULL DEFAULT 'in_progress',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT attempts_status_check CHECK (status IN ('in_progress','completed','abandoned'))
);

CREATE INDEX IF NOT EXISTS idx_attempts_user_id ON public.attempts (user_id);
CREATE INDEX IF NOT EXISTS idx_attempts_test_id ON public.attempts (test_id);

-- ==================================================================
-- attempt_answers
-- Stores selected option or text answers for a given attempt and question.
-- Prevent duplicate answers for the same attempt/question using UNIQUE constraint.
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.attempt_answers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attempt_id UUID NOT NULL REFERENCES public.attempts(id) ON DELETE CASCADE,
  question_id UUID NOT NULL REFERENCES public.questions(id) ON DELETE CASCADE,
  chosen_option_id UUID REFERENCES public.options(id) ON DELETE SET NULL,
  text_answer TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_attempt_question UNIQUE (attempt_id, question_id)
);

CREATE INDEX IF NOT EXISTS idx_attempt_answers_attempt_id ON public.attempt_answers (attempt_id);

-- ==================================================================
-- payments
-- Manual UPI payment records submitted by users for purchasing a test_series
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  test_series_id UUID NOT NULL REFERENCES public.test_series(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  mobile TEXT NOT NULL,
  amount NUMERIC(10,2) NOT NULL,
  utr TEXT NOT NULL,
  payment_time TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  admin_note TEXT,
  reviewed_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT payments_status_check CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE INDEX IF NOT EXISTS idx_payments_user_id ON public.payments (user_id);
CREATE INDEX IF NOT EXISTS idx_payments_test_series_id ON public.payments (test_series_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON public.payments (status);
CREATE INDEX IF NOT EXISTS idx_payments_utr ON public.payments (utr);

CREATE TRIGGER trg_payments_set_timestamp
BEFORE UPDATE ON public.payments
FOR EACH ROW
EXECUTE PROCEDURE public.trigger_set_timestamp();

-- ==================================================================
-- purchases
-- When an admin approves a payment, a purchase/unlock row is created.
-- Prevent duplicate active purchases with a unique constraint on (user_id, test_series_id).
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.purchases (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  test_series_id UUID NOT NULL REFERENCES public.test_series(id) ON DELETE CASCADE,
  source_payment_id UUID UNIQUE REFERENCES public.payments(id) ON DELETE RESTRICT,
  unlocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT unique_user_test_series_purchase UNIQUE (user_id, test_series_id)
);

CREATE INDEX IF NOT EXISTS idx_purchases_user_id ON public.purchases (user_id);
CREATE INDEX IF NOT EXISTS idx_purchases_test_series_id ON public.purchases (test_series_id);

-- ==================================================================
-- admin_audit
-- Records admin actions for auditability.
-- ==================================================================
CREATE TABLE IF NOT EXISTS public.admin_audit (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  action TEXT NOT NULL,
  target_id UUID,
  details JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_admin_user_id ON public.admin_audit (admin_user_id);

-- ==================================================================
-- Optional trigger to create profile rows upon auth.users insertion.
-- Many Supabase projects create a profile row for each auth user. This block is optional:
-- If you want an automatic profile row when a new user is created, enable the trigger below in the Supabase SQL editor.
-- The trigger is provided here for review but is commented out to avoid unexpected side-effects.

-- CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
-- RETURNS TRIGGER AS $$
-- BEGIN
--   -- Insert a minimal profile record when a new auth.users row is created.
--   INSERT INTO public.profiles (id, created_at, updated_at)
--   VALUES (NEW.id, now(), now())
--   ON CONFLICT (id) DO NOTHING;
--   RETURN NEW;
-- END;
-- $$ LANGUAGE plpgsql;
--
-- CREATE TRIGGER on_auth_user_created
-- AFTER INSERT ON auth.users
-- FOR EACH ROW
-- EXECUTE PROCEDURE public.handle_new_auth_user();

-- ==================================================================
-- Notes:
-- - Do not store secrets in the database.
-- - is_correct values in public.options must be protected by RLS or only accessed server-side.
-- - Grading should be performed server-side (Edge Function or secure RPC) using service_role key or appropriate privileges.

-- End of schema.sql
