-- Xtreme AG Apps
-- FINAL REPAIR: Owner login + Live Chat
-- Run this AFTER the previously attempted 017 migration.
-- This script is designed for the EXISTING owner_credentials table:
-- username, password_hash, is_active, updated_at
-- It does NOT assume an id column.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1. Repair / set the existing Owner credential
-- ============================================================
DO $$
BEGIN
  UPDATE public.owner_credentials
  SET
    password_hash = crypt('Mona@8077#Gov&ind', gen_salt('bf', 10)),
    is_active = true,
    updated_at = now()
  WHERE username = '787886908432';

  IF NOT FOUND THEN
    INSERT INTO public.owner_credentials (username, password_hash, is_active, updated_at)
    VALUES (
      '787886908432',
      crypt('Mona@8077#Gov&ind', gen_salt('bf', 10)),
      true,
      now()
    );
  END IF;
END $$;

-- ============================================================
-- 2. Owner sessions
-- ============================================================
CREATE TABLE IF NOT EXISTS public.owner_sessions (
  token_hash text PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz
);

CREATE INDEX IF NOT EXISTS owner_sessions_expires_idx
  ON public.owner_sessions(expires_at);

ALTER TABLE public.owner_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.owner_sessions FROM anon, authenticated;

-- ============================================================
-- 3. Owner login / session functions
-- ============================================================
CREATE OR REPLACE FUNCTION public.owner_login(p_username text, p_password text)
RETURNS TABLE(session_token text, expires_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash text;
  v_token text;
  v_exp timestamptz;
BEGIN
  SELECT password_hash
    INTO v_hash
  FROM public.owner_credentials
  WHERE username = trim(p_username)
    AND is_active = true
  LIMIT 1;

  IF v_hash IS NULL OR crypt(p_password, v_hash) <> v_hash THEN
    RAISE EXCEPTION 'Invalid Owner ID or password';
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_exp := now() + interval '7 days';

  INSERT INTO public.owner_sessions(token_hash, expires_at)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), v_exp);

  RETURN QUERY SELECT v_token, v_exp;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_owner_session(p_token text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.owner_sessions
    WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
      AND revoked_at IS NULL
      AND expires_at > now()
  );
$$;

CREATE OR REPLACE FUNCTION public.owner_logout(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  UPDATE public.owner_sessions
  SET revoked_at = now()
  WHERE token_hash = encode(digest(p_token, 'sha256'), 'hex')
    AND revoked_at IS NULL;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.owner_login(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_owner_session(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_logout(text) TO anon, authenticated;

-- ============================================================
-- 4. Service query status + Owner query RPCs
-- ============================================================
ALTER TABLE public.service_recommendations
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'new';

ALTER TABLE public.service_recommendations
  DROP CONSTRAINT IF EXISTS service_recommendations_status_check;

ALTER TABLE public.service_recommendations
  ADD CONSTRAINT service_recommendations_status_check
  CHECK (status IN ('new','contacted','resolved'));

CREATE OR REPLACE FUNCTION public.owner_list_queries(p_token text)
RETURNS SETOF public.service_recommendations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.service_recommendations
  ORDER BY created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_update_query_status(
  p_token text,
  p_id uuid,
  p_status text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  IF p_status NOT IN ('new','contacted','resolved') THEN
    RAISE EXCEPTION 'Invalid status';
  END IF;

  UPDATE public.service_recommendations
  SET status = p_status
  WHERE id = p_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.owner_list_queries(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_update_query_status(text,uuid,text) TO anon, authenticated;

-- ============================================================
-- 5. Live Chat tables
-- ============================================================
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visitor_name text,
  visitor_mobile text,
  visitor_session text NOT NULL UNIQUE,
  visitor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES public.chat_conversations(id) ON DELETE CASCADE,
  sender text NOT NULL CHECK (sender IN ('visitor','owner')),
  message text NOT NULL CHECK (length(trim(message)) BETWEEN 1 AND 3000),
  created_at timestamptz NOT NULL DEFAULT now(),
  read_at timestamptz
);

CREATE INDEX IF NOT EXISTS chat_messages_conversation_created_idx
  ON public.chat_messages(conversation_id, created_at);

CREATE INDEX IF NOT EXISTS chat_conversations_updated_idx
  ON public.chat_conversations(updated_at DESC);

ALTER TABLE public.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON public.chat_conversations TO authenticated;
GRANT SELECT, INSERT ON public.chat_messages TO authenticated;

DROP POLICY IF EXISTS visitor_conversation_access ON public.chat_conversations;
CREATE POLICY visitor_conversation_access
ON public.chat_conversations
FOR SELECT TO authenticated
USING (visitor_user_id = auth.uid());

DROP POLICY IF EXISTS visitor_conversation_insert ON public.chat_conversations;
CREATE POLICY visitor_conversation_insert
ON public.chat_conversations
FOR INSERT TO authenticated
WITH CHECK (
  visitor_user_id = auth.uid()
  AND length(visitor_session) BETWEEN 16 AND 100
);

DROP POLICY IF EXISTS visitor_conversation_update ON public.chat_conversations;
CREATE POLICY visitor_conversation_update
ON public.chat_conversations
FOR UPDATE TO authenticated
USING (visitor_user_id = auth.uid())
WITH CHECK (visitor_user_id = auth.uid());

DROP POLICY IF EXISTS visitor_message_access ON public.chat_messages;
CREATE POLICY visitor_message_access
ON public.chat_messages
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.chat_conversations c
    WHERE c.id = conversation_id
      AND c.visitor_user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS visitor_message_insert ON public.chat_messages;
CREATE POLICY visitor_message_insert
ON public.chat_messages
FOR INSERT TO authenticated
WITH CHECK (
  sender = 'visitor'
  AND EXISTS (
    SELECT 1
    FROM public.chat_conversations c
    WHERE c.id = conversation_id
      AND c.visitor_user_id = auth.uid()
      AND c.status = 'open'
  )
);

-- ============================================================
-- 6. Keep conversation timestamp current
-- ============================================================
CREATE OR REPLACE FUNCTION public.chat_touch_conversation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.chat_conversations
  SET updated_at = now()
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_chat_touch_conversation ON public.chat_messages;
CREATE TRIGGER trg_chat_touch_conversation
AFTER INSERT ON public.chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.chat_touch_conversation();

-- ============================================================
-- 7. Owner Chat RPCs
-- ============================================================
CREATE OR REPLACE FUNCTION public.owner_list_chats(p_token text)
RETURNS TABLE(
  id uuid,
  visitor_name text,
  visitor_mobile text,
  status text,
  created_at timestamptz,
  updated_at timestamptz,
  last_message text,
  last_message_at timestamptz,
  unread_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  RETURN QUERY
  SELECT
    c.id,
    c.visitor_name,
    c.visitor_mobile,
    c.status,
    c.created_at,
    c.updated_at,
    lm.message AS last_message,
    lm.created_at AS last_message_at,
    COALESCE(uc.unread_count, 0)::bigint AS unread_count
  FROM public.chat_conversations c
  LEFT JOIN LATERAL (
    SELECT m.message, m.created_at
    FROM public.chat_messages m
    WHERE m.conversation_id = c.id
    ORDER BY m.created_at DESC
    LIMIT 1
  ) lm ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS unread_count
    FROM public.chat_messages m
    WHERE m.conversation_id = c.id
      AND m.sender = 'visitor'
      AND m.read_at IS NULL
  ) uc ON true
  ORDER BY c.updated_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_get_chat(
  p_token text,
  p_conversation_id uuid
)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  UPDATE public.chat_messages
  SET read_at = now()
  WHERE conversation_id = p_conversation_id
    AND sender = 'visitor'
    AND read_at IS NULL;

  RETURN QUERY
  SELECT *
  FROM public.chat_messages
  WHERE conversation_id = p_conversation_id
  ORDER BY created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_send_chat(
  p_token text,
  p_conversation_id uuid,
  p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.chat_conversations
    WHERE id = p_conversation_id
  ) THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;

  IF length(trim(p_message)) < 1 OR length(trim(p_message)) > 3000 THEN
    RAISE EXCEPTION 'Message must be between 1 and 3000 characters';
  END IF;

  INSERT INTO public.chat_messages(conversation_id, sender, message)
  VALUES (p_conversation_id, 'owner', trim(p_message))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_close_chat(
  p_token text,
  p_conversation_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  UPDATE public.chat_conversations
  SET status = 'closed', updated_at = now()
  WHERE id = p_conversation_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.owner_list_chats(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_get_chat(text,uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_send_chat(text,uuid,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_close_chat(text,uuid) TO anon, authenticated;

-- ============================================================
-- 8. Realtime
-- ============================================================
ALTER TABLE public.chat_conversations REPLICA IDENTITY FULL;
ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_conversations'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_conversations;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
EXCEPTION WHEN undefined_object THEN
  NULL;
END $$;

-- ============================================================
-- 9. Final verification
-- ============================================================
SELECT
  username,
  is_active,
  password_hash = crypt('Mona@8077#Gov&ind', password_hash) AS password_matches
FROM public.owner_credentials
WHERE username = '787886908432';

SELECT to_regclass('public.chat_conversations') AS chat_conversations,
       to_regclass('public.chat_messages') AS chat_messages;
