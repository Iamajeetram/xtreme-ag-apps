-- Xtreme AG Apps - FINAL Owner Login + Service Queries + Live Chat
-- Run ONCE in Supabase SQL Editor.
-- Do NOT commit this file to a public GitHub repository because it contains the
-- one-time Owner password used to create the server-side bcrypt hash.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1. OWNER CREDENTIAL
-- Works with the EXISTING owner_credentials schema:
-- username, password_hash, is_active, updated_at
-- No id column is assumed.
-- ============================================================
UPDATE public.owner_credentials
SET password_hash = crypt('Mona@8077#Gov&ind', gen_salt('bf', 12)),
    is_active = true,
    updated_at = now()
WHERE username = '787886908432';

INSERT INTO public.owner_credentials (username, password_hash, is_active, updated_at)
SELECT '787886908432', crypt('Mona@8077#Gov&ind', gen_salt('bf', 12)), true, now()
WHERE NOT EXISTS (
  SELECT 1 FROM public.owner_credentials WHERE username = '787886908432'
);

-- ============================================================
-- 2. OWNER SESSIONS
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

-- Remove any older owner_login return type before replacing it with JSONB.
DROP FUNCTION IF EXISTS public.owner_login(text,text);

CREATE FUNCTION public.owner_login(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_hash text;
  v_token text;
  v_exp timestamptz;
BEGIN
  SELECT password_hash INTO v_hash
  FROM public.owner_credentials
  WHERE username = trim(p_username)
    AND is_active = true
  ORDER BY updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_hash IS NULL OR crypt(p_password, v_hash) <> v_hash THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Invalid Owner ID or password.');
  END IF;

  v_token := encode(gen_random_bytes(32), 'hex');
  v_exp := now() + interval '7 days';

  INSERT INTO public.owner_sessions(token_hash, expires_at)
  VALUES (encode(digest(v_token, 'sha256'), 'hex'), v_exp);

  RETURN jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp);
END;
$$;

CREATE OR REPLACE FUNCTION public.is_owner_session(p_token text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.owner_sessions
    WHERE token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex')
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
  WHERE token_hash = encode(digest(coalesce(p_token,''), 'sha256'), 'hex')
    AND revoked_at IS NULL;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.owner_login(text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_owner_session(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.owner_logout(text) TO anon, authenticated;

-- ============================================================
-- 3. SERVICE QUERY OWNER RPCs
-- ============================================================
ALTER TABLE public.service_recommendations
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'new';

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
    SELECT * FROM public.service_recommendations
    ORDER BY created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_update_query_status(
  p_token text, p_id uuid, p_status text
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
-- 4. LIVE CHAT TABLES
-- Visitor chat is RPC-based, so Anonymous Sign-In is NOT required.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visitor_name text NOT NULL,
  visitor_mobile text NOT NULL,
  visitor_session text NOT NULL UNIQUE,
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
REVOKE ALL ON public.chat_conversations FROM anon, authenticated;
REVOKE ALL ON public.chat_messages FROM anon, authenticated;

-- ============================================================
-- 5. VISITOR CHAT RPCs
-- Session key is a random browser-generated secret stored locally.
-- ============================================================
DROP FUNCTION IF EXISTS public.chat_start(text,text,text);
CREATE FUNCTION public.chat_start(
  p_name text, p_mobile text, p_visitor_session text
)
RETURNS TABLE(id uuid, visitor_name text, visitor_mobile text, status text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF length(trim(coalesce(p_name,''))) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'Please enter a valid name';
  END IF;
  IF length(regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g')) NOT BETWEEN 10 AND 15 THEN
    RAISE EXCEPTION 'Please enter a valid mobile number';
  END IF;
  IF length(coalesce(p_visitor_session,'')) NOT BETWEEN 16 AND 100 THEN
    RAISE EXCEPTION 'Invalid chat session';
  END IF;

  SELECT c.id INTO v_id
  FROM public.chat_conversations c
  WHERE c.visitor_session = p_visitor_session
  LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO public.chat_conversations(visitor_name, visitor_mobile, visitor_session)
    VALUES (trim(p_name), trim(p_mobile), p_visitor_session)
    RETURNING chat_conversations.id INTO v_id;
  ELSE
    UPDATE public.chat_conversations
    SET visitor_name = trim(p_name),
        visitor_mobile = trim(p_mobile),
        updated_at = now()
    WHERE chat_conversations.id = v_id;
  END IF;

  RETURN QUERY
    SELECT c.id, c.visitor_name, c.visitor_mobile, c.status
    FROM public.chat_conversations c
    WHERE c.id = v_id;
END;
$$;

DROP FUNCTION IF EXISTS public.chat_get(uuid,text);
CREATE FUNCTION public.chat_get(p_conversation_id uuid, p_visitor_session text)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_conversations
    WHERE id = p_conversation_id
      AND visitor_session = p_visitor_session
  ) THEN
    RAISE EXCEPTION 'Chat session not found';
  END IF;

  RETURN QUERY
    SELECT * FROM public.chat_messages
    WHERE conversation_id = p_conversation_id
    ORDER BY created_at;
END;
$$;

DROP FUNCTION IF EXISTS public.chat_send(uuid,text,text);
CREATE FUNCTION public.chat_send(
  p_conversation_id uuid, p_visitor_session text, p_message text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.chat_conversations
    WHERE id = p_conversation_id
      AND visitor_session = p_visitor_session
      AND status = 'open'
  ) THEN
    RAISE EXCEPTION 'Chat is closed or session is invalid';
  END IF;

  IF length(trim(coalesce(p_message,''))) NOT BETWEEN 1 AND 3000 THEN
    RAISE EXCEPTION 'Invalid message';
  END IF;

  INSERT INTO public.chat_messages(conversation_id, sender, message)
  VALUES (p_conversation_id, 'visitor', trim(p_message))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.chat_start(text,text,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_get(uuid,text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_send(uuid,text,text) TO anon, authenticated;

-- ============================================================
-- 6. OWNER CHAT RPCs
-- ============================================================
CREATE OR REPLACE FUNCTION public.owner_list_chats(p_token text)
RETURNS TABLE(
  id uuid, visitor_name text, visitor_mobile text, status text,
  created_at timestamptz, updated_at timestamptz,
  last_message text, last_message_at timestamptz, unread_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;

  RETURN QUERY
  SELECT c.id, c.visitor_name, c.visitor_mobile, c.status,
         c.created_at, c.updated_at,
         lm.message, lm.created_at,
         COALESCE(uc.n,0)::bigint
  FROM public.chat_conversations c
  LEFT JOIN LATERAL (
    SELECT m.message, m.created_at
    FROM public.chat_messages m
    WHERE m.conversation_id = c.id
    ORDER BY m.created_at DESC LIMIT 1
  ) lm ON true
  LEFT JOIN LATERAL (
    SELECT count(*) n
    FROM public.chat_messages m
    WHERE m.conversation_id = c.id
      AND m.sender = 'visitor'
      AND m.read_at IS NULL
  ) uc ON true
  ORDER BY c.updated_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_get_chat(p_token text, p_conversation_id uuid)
RETURNS SETOF public.chat_messages
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
    SELECT * FROM public.chat_messages
    WHERE conversation_id = p_conversation_id
    ORDER BY created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_send_chat(
  p_token text, p_conversation_id uuid, p_message text
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.is_owner_session(p_token) THEN
    RAISE EXCEPTION 'Owner session expired';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_conversations WHERE id = p_conversation_id) THEN
    RAISE EXCEPTION 'Conversation not found';
  END IF;
  IF length(trim(coalesce(p_message,''))) NOT BETWEEN 1 AND 3000 THEN
    RAISE EXCEPTION 'Invalid message';
  END IF;

  INSERT INTO public.chat_messages(conversation_id, sender, message)
  VALUES (p_conversation_id, 'owner', trim(p_message))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_close_chat(p_token text, p_conversation_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
-- 7. UPDATE CHAT TIMESTAMP + REALTIME
-- ============================================================
CREATE OR REPLACE FUNCTION public.chat_touch_conversation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
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
FOR EACH ROW EXECUTE FUNCTION public.chat_touch_conversation();

ALTER TABLE public.chat_conversations REPLICA IDENTITY FULL;
ALTER TABLE public.chat_messages REPLICA IDENTITY FULL;

DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_conversations;
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
  EXCEPTION WHEN undefined_object THEN NULL;
END;
$$;

-- Tell PostgREST to reload its schema cache immediately.
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 8. VERIFY
-- ============================================================
SELECT username, is_active,
       (password_hash = crypt('Mona@8077#Gov&ind', password_hash)) AS password_matches
FROM public.owner_credentials
WHERE username = '787886908432';

SELECT to_regclass('public.chat_conversations') AS chat_conversations,
       to_regclass('public.chat_messages') AS chat_messages;

SELECT proname, pg_get_function_result(oid) AS returns
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN ('owner_login','chat_start','chat_get','chat_send')
ORDER BY proname;
