# Connect MarketHub to Supabase

MarketHub is being moved from browser-only demo storage to a shared PostgreSQL database with Supabase Auth and row-level security. The database is being prepared as a **multi-organisation platform**: each market organisation has its own members, traders, locations, pitches, events, bookings, payments and compliance records.

## 1. Create the Supabase project
1. Create a Supabase account and a new project for the first MarketHub installation.
2. Choose a strong unique database password and store it in a password manager.
3. Choose a nearby region (UK/EU if available).
4. The free plan may suit a small pilot, but it is not a permanent service guarantee. Check current quotas, inactivity pausing, backup and retention terms before relying on it operationally.

## 2. Apply the database schema and multi-organisation upgrade
1. Open the project dashboard and choose **SQL Editor**.
2. Open `database/schema.sql` in this repository, paste the complete file into a new SQL query and run it.
3. Open `database/migrations/001_multi_organisation.sql`, paste the complete file into a second SQL query and run it.
4. Open `database/migrations/002_security_role_hardening.sql`, paste the complete file into a third SQL query and run it.
5. Confirm that the tables include `organizations` and `organization_memberships`, and that the existing Newcastle and Downpatrick locations belong to the `markethub-demo` organisation.

The migration moves the existing single-market starter data into one organisation called **MarketHub Demo Market**. It adds organisation IDs to market records and replaces global access policies with organisation-scoped row-level security. A user's role is held in their organisation membership (owner, admin or trader), not in a platform-wide administrator flag. Migration `002_security_role_hardening.sql` retires the old global profile-role authorization helper, prevents authenticated browser clients from changing the legacy `profiles.role` field, restricts profile updates to basic contact fields, and limits administrators to managing trader memberships. Only owners can grant or revoke administrator/owner roles, and an organisation cannot lose its last owner.

## 3. Create the manager account and assign the first organisation owner
1. In Supabase **Authentication → Users**, create the manager account using an email address the manager controls.
2. Copy that user's UUID.
3. In SQL Editor run the bootstrap statement at the bottom of `database/migrations/001_multi_organisation.sql`, replacing `MANAGER-AUTH-USER-UUID` with the exact UUID.
4. Confirm that the manager appears in `organization_memberships` as `owner` for `markethub-demo`.

New signups are automatically given a basic trader profile. They are **not** automatically made administrators or owners. Adding a person to an organisation and assigning their role must be an administrator-controlled process.

## 4. Website keys
The website will need the Supabase **Project URL** and the **anon/publishable key**. These are designed for browser use only when row-level security is correctly configured. Never put the database password, `service_role` key, or any secret API key in `index.html`, GitHub, or a public page.

## 5. Multi-organisation model
- Each market operator is represented by one row in `organizations`.
- A user can belong to more than one organisation through `organization_memberships`, with a separate role in each.
- Locations, pitches, market dates, bookings, payments, compliance records, notifications and audit records carry an `organization_id`.
- Row-level security checks organisation membership and administrator role before allowing access.
- A new organisation should be provisioned through a trusted owner/admin workflow, not by trusting a public browser form. Its initial owner membership must be created by trusted server-side code or a controlled SQL/admin operation.
- This design supports independent deployments and data exports. It does not yet implement a customer-facing organisation creation, billing, or one-click migration interface.

## 6. Data and cutover
The existing MarketHub demo data lives only in the browser where it was entered. It is not automatically uploaded or shared. Keep the demo data for testing; do not enter real trader contact details or compliance documents until authentication, the live database connection and access tests have been completed.

Before live use, test at least:
- An organisation's administrator can manage only that organisation's locations, pitches, dates, traders, bookings, payments and compliance records.
- A user belonging to Organisation A cannot read or change Organisation B's records.
- Trader A cannot view or alter Trader B's personal records.
- A trader cannot approve bookings, mark payments paid, cancel markets or change their organisation role.
- Two traders cannot hold the same pitch for the same event.
- A cancelled market cannot accept new applications.
- Removing a user's organisation membership immediately removes their access to that organisation.
- Backups/export and account recovery procedures are understood.

## Current status
The multi-organisation SQL schema and upgrade migration are prepared in GitHub, but they have **not** been applied to a hosted Supabase project. The website is also **not yet connected** to Supabase; the GitHub Pages app remains a browser-local prototype until the frontend is migrated and tested. Do not use real personal data yet.
