# Google OAuth & Authentication Setup — Xtreme AG Apps

## Overview

This document provides step-by-step instructions for setting up Google OAuth authentication and the authentication flow for Xtreme AG Apps.

## Files Created / Modified

### New Files Created:

1. **pages/login.html** — Google OAuth sign-in page
2. **pages/complete-profile.html** — Profile completion form (name, mobile, state)
3. **pages/dashboard.html** — User dashboard showing account details
4. **supabase/migrations/001_add_profile_state.sql** — Database migration adding `state` column to `profiles` table
5. **docs/AUTH_SETUP.md** — This authentication setup guide

### Files NOT Modified:

- `index.html` — Existing website preserved as-is
- `privacy.html` — Not modified
- `terms.html` — Not modified
- `robots.txt` — Not modified
- `sitemap.xml` — Not modified
- `CNAME` — Not modified
- `supabase/schema.sql` — Not modified
- `supabase/policies.md` — Not modified
- `supabase/README.md` — Not modified

---

## Prerequisites

You will need:

1. **Supabase Project** — Already created and configured
2. **Google OAuth App** — From Google Cloud Console (see setup steps below)
3. **Supabase Publishable Key** — Your `SUPABASE_URL` and `SUPABASE_ANON_KEY`
4. **GitHub Pages Domain** — https://xtremeagapps.in (your custom domain)

---

## Step 1: Create Google OAuth Credentials

### 1.1 Go to Google Cloud Console

1. Visit [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select an existing one
3. Go to **APIs & Services** → **Credentials**

### 1.2 Create OAuth 2.0 Consent Screen

1. Click **Create OAuth 2.0 Consent Screen**
2. Choose **External** (or **Internal** if your Google Workspace domain allows)
3. Fill in the form:
   - **App name:** Xtreme AG Apps
   - **User support email:** ajeetram3@gmail.com
   - **Developer contact:** ajeetram3@gmail.com
4. Click **Save and Continue**
5. Skip scopes (or add minimal scopes if required)
6. Skip test users (or add your test email if in development)
7. Review and create the consent screen

### 1.3 Create OAuth 2.0 Client ID

1. Go to **Credentials** → **Create Credentials** → **OAuth 2.0 Client ID**
2. Choose **Web Application**
3. Configure:
   - **Name:** Xtreme AG Apps Web
   - **Authorized JavaScript origins:**
     - `https://xtremeagapps.in`
     - `http://localhost:3000` (for local testing)
   - **Authorized redirect URIs:**
     - `https://xtremeagapps.in/`
     - `https://xtremeagapps.in/pages/login.html`
     - `https://xtremeagapps.in/pages/dashboard.html`
     - `https://[your-supabase-project].supabase.co/auth/v1/callback`
4. Click **Create**
5. Download the credentials (you'll see Client ID and Client Secret)
6. **Keep the Client ID safe** — you'll need it for Supabase

---

## Step 2: Configure Supabase Auth

### 2.1 Enable Google OAuth in Supabase

1. Go to your Supabase project dashboard
2. Navigate to **Authentication** → **Providers**
3. Find **Google** and click to enable
4. Paste your **Google OAuth 2.0 Client ID** into the `Client ID` field
5. Paste your **Google OAuth 2.0 Client Secret** into the `Client Secret` field
6. Click **Save**

### 2.2 Configure Auth Redirect URLs

1. Go to **Authentication** → **URL Configuration**
2. Add the following redirect URLs:
   - `https://xtremeagapps.in/pages/dashboard.html`
   - `https://xtremeagapps.in/pages/login.html`
   - `http://localhost:3000/pages/dashboard.html` (for local development)
3. Save

---

## Step 3: Configure Frontend Credentials

### 3.1 Update Supabase Credentials in Frontend Files

Replace the placeholder values in the following files with your actual Supabase credentials:

**In `pages/login.html` (around line 179-180):**
```javascript
const SUPABASE_URL = 'https://your-supabase-project.supabase.co';
const SUPABASE_ANON_KEY = 'your-supabase-anon-key';
```

**In `pages/complete-profile.html` (around line 256-257):**
```javascript
const SUPABASE_URL = 'https://your-supabase-project.supabase.co';
const SUPABASE_ANON_KEY = 'your-supabase-anon-key';
```

**In `pages/dashboard.html` (around line 192-193):**
```javascript
const SUPABASE_URL = 'https://your-supabase-project.supabase.co';
const SUPABASE_ANON_KEY = 'your-supabase-anon-key';
```

You can find these values in your Supabase dashboard:
- Go to **Settings** → **API**
- Copy the **Project URL** and **Anon Public** key

---

## Step 4: Apply Database Migration

### 4.1 Run the Migration in Supabase

The migration file `supabase/migrations/001_add_profile_state.sql` adds a `state` column to the `profiles` table.

To apply it:

1. Go to your Supabase dashboard
2. Navigate to **SQL Editor**
3. Click **New Query**
4. Copy the contents of `supabase/migrations/001_add_profile_state.sql`:
   ```sql
   ALTER TABLE public.profiles
   ADD COLUMN IF NOT EXISTS state TEXT;
   ```
5. Click **Run**
6. Verify the column was added by checking the `profiles` table structure

---

## Step 5: Authentication Flow

### 5.1 User Sign-In Flow

1. **User visits `/pages/login.html`**
   - Sees "Continue with Google" button
   - Clicks the button
   
2. **Google OAuth Dialog**
   - User authenticates with their Google account
   - Google redirects to Supabase callback
   - Supabase creates or updates the user in `auth.users`
   
3. **Profile Check**
   - Frontend checks `public.profiles` for the user
   - If profile is complete (has `display_name`, `mobile`, `state`):
     - Redirects to `/pages/dashboard.html`
   - If profile is missing or incomplete:
     - Redirects to `/pages/complete-profile.html`

### 5.2 Profile Completion Flow

1. **User sees `/pages/complete-profile.html`**
   - Name field is prefilled from Google metadata
   - User enters mobile number (10 digits)
   - User selects state from dropdown
   - All fields are required
   
2. **Form Submission**
   - Frontend validates all fields
   - Validates mobile number format (10 digits)
   - Gets the authenticated user ID from Supabase session
   - Performs UPSERT into `public.profiles`:
     ```
     display_name, mobile, state, is_admin
     ```
   - Ensures `is_admin` is never set to `true` by the frontend
   - Preserves existing `is_admin` value if user already has a profile
   
3. **Redirect to Dashboard**
   - After successful save, redirects to `/pages/dashboard.html`

### 5.3 Dashboard Flow

1. **User sees `/pages/dashboard.html`**
   - Displays profile information:
     - Full name
     - Email
     - Mobile number
     - State
     - Account status (Active)
   - Shows placeholders for future features:
     - My Test Series
     - My Payments
     - My Results
   - Navigation shows "Logout" option
   
2. **Session Persistence**
   - Session is maintained across page refreshes
   - If user refreshes or revisits, they remain logged in
   
3. **Logout**
   - Click "Logout" to sign out
   - Clears Supabase session
   - Redirects to `/pages/login.html`

---

## Step 6: Security Considerations

### ✅ Implemented Security Measures

1. **Anon Key Only** — Frontend uses only the Supabase publishable (anon) key
   - Never expose the service role key
   - All privileged operations must use Edge Functions or backend
   
2. **User ID from Session** — Never accept user_id from URL or form fields
   - Always use `supabase.auth.getSession().user.id`
   
3. **Profile Completeness Check** — Both frontend and backend validate
   - Frontend checks before redirecting
   - RLS policies will enforce on backend
   
4. **is_admin Protection** — Frontend never sets `is_admin = true`
   - Always set to `false` for new profiles
   - Preserve existing value for updates
   - Only admins can be promoted via database direct access
   
5. **No Email/Password Registration** — Google OAuth only
   - No plain-text password storage
   - Reduces password-related security risks

---

## Step 7: Enable RLS (Row Level Security)

To ensure database security, enable RLS on the `profiles` table:

1. Go to Supabase **SQL Editor**
2. Run:
   ```sql
   ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
   ```
3. Create policies (see `supabase/policies.md` for detailed policy definitions)

---

## Step 8: Test the Flow Locally

### 8.1 Local Testing Setup

If testing locally before deploying to GitHub Pages:

1. Update redirect URIs to include `http://localhost:3000`
2. In your pages, use `http://localhost:3000` instead of `https://xtremeagapps.in`
3. Serve the files using a local server (e.g., Python's `http.server`)

### 8.2 Test Scenarios

- **New User Sign-In**
  1. Click "Continue with Google"
  2. Authenticate with a test Google account
  3. Should redirect to complete-profile.html
  4. Fill in profile details
  5. Should redirect to dashboard.html
  
- **Existing User Sign-In**
  1. Sign out
  2. Click "Continue with Google" with the same account
  3. Should skip profile completion
  4. Should go directly to dashboard.html
  
- **Session Persistence**
  1. Log in successfully
  2. Refresh the page
  3. Should remain logged in
  
- **Logout**
  1. Click "Logout"
  2. Should redirect to login.html
  3. Should not be able to access dashboard without logging in

---

## Troubleshooting

### Issue: "User is not authenticated"

**Solution:**
- Ensure Supabase credentials are correct
- Check that the user is actually signed in with `getSession()`
- Verify RLS policies are not blocking access

### Issue: "Profile not found"

**Solution:**
- Check that the `profiles` table has the `state` column (run migration)
- Verify the user_id in the session matches the profile id
- Check RLS policies allow the user to read their own profile

### Issue: Google sign-in button doesn't work

**Solution:**
- Verify Google OAuth credentials are correct in Supabase
- Check that redirect URLs are properly configured
- Check browser console for errors
- Ensure `handleGoogleSignIn()` function is properly called

### Issue: Profile completes but doesn't redirect to dashboard

**Solution:**
- Check browser console for JavaScript errors
- Verify the UPSERT query in Supabase runs successfully
- Check that all three fields (name, mobile, state) are not empty
- Verify Supabase session is active after profile save

---

## Next Steps

After authentication is working:

1. **Implement Admin Dashboard** (future phase)
2. **Implement Payment Processing** (future phase)
3. **Implement Test Series** (future phase)
4. **Implement Test Grading** (future phase)
5. **Android App Integration** (future phase)

---

## Support

For questions about this setup, contact: ajeetram3@gmail.com

For Supabase documentation, visit: https://supabase.com/docs/
For Google OAuth documentation, visit: https://developers.google.com/identity/protocols/oauth2
