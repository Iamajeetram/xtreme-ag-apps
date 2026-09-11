-- Fix for the previously installed owner credential hash.
-- Run this once if 016_owner_console_FINAL.sql has already been run.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
UPDATE public.owner_credentials
SET password_hash = '$2a$12$fCDN7pL5FguD7nErB1VxS.cs85NTLK0yN.JAuJpuoDnWnG88sF1Ru',
    is_active = true,
    updated_at = now()
WHERE username = '787886908432';

-- Sanity check: should return true.
SELECT (password_hash = crypt('Mona@8077#Gov&ind', password_hash)) AS password_matches
FROM public.owner_credentials
WHERE username = '787886908432';
