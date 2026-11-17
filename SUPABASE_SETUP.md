# Connect MarketHub to Supabase

This project is being moved from browser-only demo storage to a shared PostgreSQL database with Supabase Auth and row-level security.

## 1. Create the Supabase project
1. Create a Supabase account and a new project for MarketHub.
2. Choose a strong unique database password and store it in a password manager.
3. Choose a nearby region (UK/EU if available).
4. The free plan is suitable for a small pilot, but it is not a permanent service guarantee. Check current quotas, inactivity pausing, backup and retention terms before relying on it operationally.

## 2. Apply the database schema
1. Open the project dashboard and choose **SQL Editor**.
2. Open `database/schema.sql` in this repository.
3. Paste the complete file into a new SQL query and run it.
4. Confirm that the tables and the two locations (Newcastle and Downpatrick) appear in Table Editor.

The schema enables row-level security (RLS). Signed-in traders can see only their own profile, bookings, payments, compliance records and notifications. Market setup is visible to signed-in users. Administrators can manage market setup and all records. A trader cannot promote themselves to administrator. Booking validation and unique indexes prevent conflicting pitch applications/allocations.

## 3. Create the manager account
1. In Supabase **Authentication → Users**, create the manager account (use an email address the manager controls).
2. Copy that user's UUID.
3. In SQL Editor run:
   `update public.profiles set role = 'admin' where id = 'PASTE-MANAGER-UUID-HERE';`

New signups are automatically assigned the trader role. Do not allow public sign-up to grant admin access.

## 4. Website keys
The website will need the Supabase **Project URL** and the **anon/publishable key**. These are designed for browser use when RLS is correctly configured. Never put the database password, service_role key, or any secret API key in `index.html`, GitHub, or a public page.

## 5. Data and cutover
The existing MarketHub demo data lives only in the browser where it was entered. It is not automatically uploaded or shared. Keep the demo data for testing; do not enter real trader contact details or compliance documents until authentication, the live database connection and access tests have been completed.

Before live use, test at least:
- Administrator can add/edit locations, pitches, dates, traders, bookings and payment/compliance statuses.
- Trader A cannot view or alter Trader B's personal records.
- Trader cannot approve bookings, mark payments paid, cancel markets or change their role.
- Two traders cannot hold the same pitch for the same event.
- A cancelled market cannot accept new applications.
- A removed user cannot continue to access the app.
- Backups/export and account recovery procedures are understood.

## Current status
The SQL schema is prepared, but the hosted Supabase project still needs to be created/connected and the website frontend wired to it. The existing GitHub Pages app remains a localStorage prototype until that work is completed. Do not use real personal data yet.
