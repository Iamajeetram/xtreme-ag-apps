# supabase/ — Project notes for Xtreme AG Apps

This folder contains draft Supabase artifacts for the Xtreme AG Apps project. It is a design-only artifact — nothing in this folder is applied to any live Supabase project.

Contents
- schema.sql — Draft PostgreSQL schema for Supabase (tables, constraints, indexes, triggers).
- policies.md — Proposed Row Level Security (RLS) policy design and operational guidance.
- (future) migrations/ — optional folder for SQL migrations.
- (future) seeds/ — optional seed data for development only.

Purpose
- Provide a clean, reviewed database design before creating the Supabase project.
- Make RLS and security requirements explicit so the implementation is safe for production.

Important notes and security guidance
- This repo artifact is NOT connected to any live Supabase project.
- Do NOT put Supabase service role key in any frontend code (GitHub Pages or Android).
- Public vs secret keys:
  - SUPABASE_URL — can be used by frontend code (public).
  - SUPABASE_ANON_KEY — can be used by frontend code (public) for normal client operations.
  - SUPABASE_SERVICE_ROLE_KEY — MUST NEVER be placed in frontend code or in client-side apps. It is a privileged secret and may perform any action on the database. Use it only in:
    - Supabase Edge Functions
    - Trusted server-side environments (your own server, serverless functions)
- Admin/privileged operations:
  - Approving payments and creating purchases/unlocks should be performed by a server-side process (Edge Function or secure RPC) that uses the service_role key. The frontend should call that function; the function must validate that the caller is an admin (e.g., check profiles.is_admin).
- Authentication & profiles:
  - Use Supabase Auth for user authentication. Store profile metadata in the `profiles` table (linked to auth.users.id).
  - Consider automatic profile creation via a trigger for convenience (provided but commented out in schema.sql). Decide whether to enable it in dev only.
- Grading and answer verification:
  - Because correct answers (options.is_correct) must be secret, grading should happen server-side by a secure function that reads correct answers and computes scores.
  - Do not expose options.is_correct to client applications.

Planned architecture
User browser (GitHub Pages frontend)
  ↓ (supabase-js, anon key)
Supabase Auth (email/password)
  ↓
Supabase Postgres (RLS enabled)
  ↓
Supabase Edge Functions / Secure RPC (service_role key) for privileged operations and grading
Android apps will later use the same Supabase backend and follow the same rules (use anon key for regular operations; do not embed service_role).

How to use these artifacts
1. Review schema.sql and policies.md with the team and stakeholders.
2. Create a Supabase project for development and apply the schema in a dev environment only.
3. Implement and test RLS policies in dev; iterate.
4. Implement Edge Functions for admin actions and grading.
5. Only after successful verification, apply to production.

Environment variables and secrets (what is public vs secret)
- Public (can be contained in frontend code):
  - SUPABASE_URL
  - SUPABASE_ANON_KEY
- Secret (must NEVER be exposed to frontend):
  - SUPABASE_SERVICE_ROLE_KEY

If you are new to Supabase
- Read Supabase docs on Auth, Postgres RLS, and Edge Functions.
- Practice on a dev project before deploying to production.

Contact
- If you need changes to the schema or policies, update the files in this folder and open a PR for review.
