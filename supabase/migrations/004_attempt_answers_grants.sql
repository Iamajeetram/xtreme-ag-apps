-- 004_attempt_answers_grants.sql
-- Fix authenticated student answer-save permissions.
-- RLS policies from 002 control which rows can be accessed;
-- these grants provide the table-level privileges required by Supabase.

GRANT SELECT, INSERT, UPDATE, DELETE
ON public.attempt_answers
TO authenticated;
