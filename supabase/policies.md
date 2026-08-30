# Row Level Security (RLS) policy design — Xtreme AG Apps (proposal)

This document describes the recommended Row Level Security (RLS) policies for the Supabase PostgreSQL schema (see supabase/schema.sql). RLS MUST be enabled for all application tables to ensure least-privilege access.

High-level rules
- Normal users (authenticated via Supabase Auth) may access only their own sensitive data, and may read published/public content.
- Admins can manage content, view payments, and perform privileged operations (approval, unlocking) via a secure server-side flow.
- The Supabase service_role key must NEVER be placed in frontend (GitHub Pages or Android) code; use it only in trusted server-side environments such as Edge Functions or secure server processes.

Conventions used in policies
- auth.uid() — the Supabase helper that returns the current authenticated user's id.
- profiles.is_admin — boolean flag in profiles table identifying admins.
- For admin-only server actions, prefer using Supabase Edge Function or secure RPC that validates the caller and executes updates with elevated privileges.

Enable RLS
- For each application table, enable RLS:
  ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY;

Table-specific policies (description; exact SQL policy statements to be implemented by DB admin)

1) profiles
- Purpose: store profile metadata linked to auth.users.
- Policies:
  - SELECT, UPDATE: allow if auth.uid() = id (users may read/update their own profile).
  - INSERT: allow if auth.uid() = NEW.id (user created via auth; optional server-side profile creation allowed).
  - Admins: allow SELECT/UPDATE for users with profiles.is_admin = true (note: careful bootstrapping required).
  - Deny non-admins from reading other users' profiles.

2) test_series
- Purpose: published/unpublished test series metadata.
- Policies:
  - SELECT:
    - allow if is_published = true (public access).
    - allow for admins (profiles.is_admin = true).
  - INSERT/UPDATE/DELETE:
    - allow only for admins (server-side or via authenticated admin UI).
  - Note: If you plan to expose unpublished test_series to specific users (e.g., beta testers), add an explicit allow-list table and policies.

3) tests
- Purpose: tests belonging to test_series.
- Policies:
  - SELECT:
    - allow if tests.is_published = true AND the parent test_series.is_published = true.
    - allow for admins.
    - allow if the user has an unlocked purchase (exists in purchases) for the parent test_series (for taking tests).
  - INSERT/UPDATE/DELETE:
    - allow only for admins.

4) questions
- Purpose: questions for tests.
- Policies:
  - SELECT:
    - For normal users, allow access only when taking an unlocked test (i.e., user has a purchase row for test_series AND the test is published OR during an active attempt where attempt_id is known). Prefer server-side RPC for test start that returns questions without revealing is_correct.
    - For admins, allow full access.
  - INSERT/UPDATE/DELETE:
    - allow only for admins.
  - Important: The is_correct answers are stored on options rows — ensure options.is_correct cannot be read by normal users (see options policy below).

5) options
- Purpose: answer options for questions (includes is_correct).
- Policies:
  - SELECT:
    - For normal users, SELECT must exclude is_correct (the column itself cannot be masked easily via policy). Best practice:
      - Do NOT grant direct SELECT access to public.options for normal users.
      - Instead, create a secure view or server-side RPC that returns options WITHOUT the is_correct column for normal users.
      - Grant admins full SELECT.
    - Example approach:
      - public.view_options_for_user(question_id) — returns id, option_text, sort_order but NOT is_correct.
  - INSERT/UPDATE/DELETE:
    - only for admins.
  - Rationale: Prevent exposing correct answers before submission.

6) attempts
- Purpose: track user attempts on tests.
- Policies:
  - INSERT:
    - allow if auth.uid() = NEW.user_id (user may create their own attempt).
  - SELECT:
    - allow if auth.uid() = user_id (users may read their attempts).
    - allow admins to read attempts for debugging/auditing.
  - UPDATE:
    - allow if auth.uid() = user_id AND status IN ('in_progress') for operations such as finishing attempt (server-side checks should validate scoring).
    - For score/finalization, prefer a server-side grading function invoked by the frontend that uses an RPC/Edge Function to compute the score (so that is_correct is not exposed to the client).
  - DELETE:
    - restricted to admins (or disallowed).

7) attempt_answers
- Purpose: stores per-question answers for an attempt.
- Policies:
  - INSERT:
    - allow if auth.uid() = (select user_id from attempts where attempts.id = NEW.attempt_id)
      (i.e., only the owner of the attempt can insert answers).
  - SELECT:
    - allow if auth.uid() = attempts.user_id (users may read their answers for their attempts).
    - admins may read all.
  - UPDATE/DELETE:
    - restrict to the owner for in-progress attempts or to admins; prefer server-side enforcement to avoid tampering.

8) payments
- Purpose: manual UPI payment records submitted by users.
- Policies:
  - INSERT:
    - allow if auth.uid() = NEW.user_id (users may create payment records for themselves).
  - SELECT:
    - allow if auth.uid() = user_id (users may read their own payment records).
    - allow admins to read (for review).
  - UPDATE/DELETE:
    - prevent users from changing status fields.
    - Provide no direct policy allowing status transitions by users.
    - Admins may update status (APPROVED/REJECTED) only via a secure server-side mechanism (Edge Function or RPC that performs checks and writes using service_role).
  - Additional:
    - Mask or limit access to sensitive fields as appropriate. Only admins should see admin_note, reviewed_by, reviewed_at.

9) purchases
- Purpose: user unlock/purchase records.
- Policies:
  - INSERT:
    - disallow client direct INSERT for normal users (purchases must be created only by the admin approval flow).
    - Admin server-side process or Edge Function should create purchases using elevated privileges.
  - SELECT:
    - allow if auth.uid() = user_id (users can read their own purchases/unlocks).
    - allow admins to read all purchases.
  - UPDATE/DELETE:
    - admins only.

10) admin_audit
- Purpose: record admin actions (audit log).
- Policies:
  - SELECT:
    - only admins may read admin_audit records.
  - INSERT:
    - disallow client-side insertions.
    - Only server-side flows (Edge Functions) should write audit entries using service_role key or a secure RPC.
  - UPDATE/DELETE:
    - disallowed for everyone; audit records should be append-only.

Admin authorization and secure operations
- DO NOT place service_role key in frontend code.
- Approving/rejecting payments and creating purchases must be performed by a trusted server-side component:
  - Option A (preferred): Supabase Edge Function that authenticates the session, checks that the caller is an admin (profiles.is_admin = true), then performs the status update on payments and creates the purchases row and admin_audit entry. The Edge Function uses the service_role key securely (server-side).
  - Option B: Secure RPC (stored procedure) that checks the caller's admin flag using a signed JWT verified server-side and then uses the service_role key to run the procedure.
- Admin UI in frontend should call the Edge Function endpoint. The Edge Function must validate the calling user's session and admin status before any state change.

Protecting is_correct
- The is_correct boolean value in options must not be returned to the client.
- Implement one of:
  - Use a server-side grading function (Edge Function/RPC) that reads options.is_correct and computes the score. Only this server-side function sees is_correct.
  - Or create a view with is_correct removed and grant client SELECT to that view for question-taking, while restricting direct access to options for non-admins.

Additional notes
- Audit logging: all admin actions that change payment.status or create purchases must add a row in admin_audit with details (payment id, admin id, action, reason).
- Bootstrapping admin users: the first admin should be assigned via the database by a trusted operator (manual setting of profiles.is_admin = true) — avoid automating promotion for security.
- Rate limits & abuse: consider adding server-side rate limiting for attempt creation to prevent abuse.
- Sensitive data retention & export: document retention periods and export processes. Ensure compliance with local laws (GDPR/India data protection guidance).

Contact
- For operational questions or to request schema/policy changes, contact: ajeetram3@gmail.com

Reminder
- This document is a design proposal only; do not apply the policies to a live database until reviewed and tested on a dev instance.
