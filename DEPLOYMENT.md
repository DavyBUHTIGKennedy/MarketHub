# Deployment notes

## Static preview on GitHub Pages
1. Open repository **Settings → Pages**.
2. Under Build and deployment, choose **Deploy from a branch**.
3. Select `main` and `/(root)`, then Save.
4. Wait for GitHub Pages to publish the site. The Pages URL will appear in Settings → Pages.

This publishes the browser-only demo. It does not add authentication, shared storage or integrations.

## Production architecture
- Host the frontend on a trusted HTTPS platform.
- Use Supabase (or an equivalent backend) for authentication, PostgreSQL and private document storage.
- Enforce role-based authorization and row-level security on the server/database; never rely on hiding admin controls in the browser.
- Use a server-side function for booking approvals, pitch conflict checks and audit events.
- Integrate a hosted payment checkout provider; verify payment webhooks server-side.
- Connect Met Office and council data through server-side adapters, respecting API terms and rate limits.
- Use a transactional email/SMS provider for cancellation notices and delivery logs.
- Add monitoring, backups, retention rules, accessibility testing and privacy/legal review.

Do not place service-role keys, payment secrets or other credentials in frontend code or this repository.
