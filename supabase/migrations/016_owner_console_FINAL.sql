-- Xtreme AG Apps FINAL Owner Console + Service Queries migration
-- Run this ONE migration. No previous 015/016 migration is required.
-- Owner credentials are stored as a bcrypt hash, not plaintext.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.service_recommendations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  name TEXT NOT NULL,
  mobile TEXT NOT NULL,
  email TEXT,
  category TEXT NOT NULL,
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  benefit TEXT,
  reference TEXT,
  contact_permission TEXT NOT NULL DEFAULT 'yes',
  preferred_contact TEXT NOT NULL DEFAULT 'WhatsApp',
  status TEXT NOT NULL DEFAULT 'new',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT service_recommendations_status_check CHECK (status IN ('new','contacted','resolved')),
  CONSTRAINT service_recommendations_contact_check CHECK (preferred_contact IN ('WhatsApp','Call')),
  CONSTRAINT service_recommendations_message_len CHECK (length(trim(message)) BETWEEN 20 AND 3000),
  CONSTRAINT service_recommendations_name_len CHECK (length(trim(name)) BETWEEN 1 AND 80),
  CONSTRAINT service_recommendations_mobile_len CHECK (length(trim(mobile)) BETWEEN 7 AND 15),
  CONSTRAINT service_recommendations_title_len CHECK (length(trim(title)) BETWEEN 1 AND 150)
);

ALTER TABLE public.service_recommendations ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'new';
ALTER TABLE public.service_recommendations ADD COLUMN IF NOT EXISTS preferred_contact TEXT NOT NULL DEFAULT 'WhatsApp';
ALTER TABLE public.service_recommendations ADD COLUMN IF NOT EXISTS contact_permission TEXT NOT NULL DEFAULT 'yes';

ALTER TABLE public.service_recommendations ENABLE ROW LEVEL SECURITY;
GRANT INSERT ON public.service_recommendations TO anon, authenticated;
REVOKE SELECT, UPDATE, DELETE ON public.service_recommendations FROM anon;
REVOKE SELECT, UPDATE, DELETE ON public.service_recommendations FROM authenticated;

DROP POLICY IF EXISTS "Public can submit service queries" ON public.service_recommendations;
CREATE POLICY "Public can submit service queries"
ON public.service_recommendations FOR INSERT TO anon, authenticated
WITH CHECK (
  length(trim(name)) BETWEEN 1 AND 80
  AND length(trim(mobile)) BETWEEN 7 AND 15
  AND length(trim(title)) BETWEEN 1 AND 150
  AND length(trim(message)) BETWEEN 20 AND 3000
  AND preferred_contact IN ('WhatsApp','Call')
  AND (user_id IS NULL OR user_id = auth.uid())
);

CREATE INDEX IF NOT EXISTS service_recommendations_created_at_idx ON public.service_recommendations(created_at DESC);
CREATE INDEX IF NOT EXISTS service_recommendations_status_idx ON public.service_recommendations(status);

CREATE TABLE IF NOT EXISTS public.owner_credentials (
  username TEXT PRIMARY KEY,
  password_hash TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Owner ID supplied by the owner. Password is represented only by a bcrypt hash.
INSERT INTO public.owner_credentials(username,password_hash,is_active)
VALUES ('787886908432', '$2y$12$9QeO4UY2IJ3to89MIoJPr.FxiFcGNzkGbSFO/hrTBNaHUtW7e/pL.', true)
ON CONFLICT (username) DO UPDATE SET password_hash=EXCLUDED.password_hash,is_active=true,updated_at=now();

CREATE TABLE IF NOT EXISTS public.owner_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash TEXT UNIQUE NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ
);

ALTER TABLE public.owner_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.owner_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.owner_credentials FROM anon, authenticated;
REVOKE ALL ON public.owner_sessions FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.owner_login(p_username TEXT, p_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions
AS $$
DECLARE h TEXT; raw_token TEXT; expiry TIMESTAMPTZ;
BEGIN
  SELECT password_hash INTO h
  FROM public.owner_credentials
  WHERE username=trim(p_username) AND is_active=true;

  IF h IS NULL OR crypt(p_password,h) <> h THEN
    RETURN jsonb_build_object('ok',false);
  END IF;

  raw_token := encode(gen_random_bytes(32),'hex');
  expiry := now() + interval '12 hours';
  INSERT INTO public.owner_sessions(token_hash,expires_at)
  VALUES (encode(digest(raw_token,'sha256'),'hex'),expiry);

  RETURN jsonb_build_object('ok',true,'token',raw_token,'expires_at',expiry);
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_get_service_queries(p_token TEXT)
RETURNS SETOF public.service_recommendations
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.owner_sessions
    WHERE token_hash=encode(digest(p_token,'sha256'),'hex')
      AND revoked_at IS NULL AND expires_at>now()
  ) THEN RAISE EXCEPTION 'Unauthorized'; END IF;

  RETURN QUERY SELECT * FROM public.service_recommendations ORDER BY created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_update_service_query(p_token TEXT,p_id UUID,p_status TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.owner_sessions
    WHERE token_hash=encode(digest(p_token,'sha256'),'hex')
      AND revoked_at IS NULL AND expires_at>now()
  ) THEN RAISE EXCEPTION 'Unauthorized'; END IF;
  IF p_status NOT IN ('new','contacted','resolved') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.service_recommendations SET status=p_status WHERE id=p_id;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.owner_logout(p_token TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions
AS $$
BEGIN
  UPDATE public.owner_sessions
  SET revoked_at=now()
  WHERE token_hash=encode(digest(p_token,'sha256'),'hex') AND revoked_at IS NULL;
  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.owner_login(TEXT,TEXT) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.owner_get_service_queries(TEXT) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.owner_update_service_query(TEXT,UUID,TEXT) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.owner_logout(TEXT) TO anon,authenticated;
