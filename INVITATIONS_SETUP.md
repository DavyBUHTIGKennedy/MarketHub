# MarketHub invitation foundation

This stage adds secure invitation links and a public invitation-details page. It does not make bookings, take payments, or send email yet.

## Database

After migrations 001–006 have been applied, run:

`database/migrations/007_secure_market_invitations.sql`

The migration adds:
- An owner-managed priority flag for each trader.
- One invitation record per trader per market date.
- A SHA-256 token hash (never the raw link token).
- A snapshot of the market name, date, location, opening time and pitch price.
- Owner/admin-only database visibility. Public token lookup is handled by the Edge Function.

## Deploy the Edge Function

From the repository root, after signing in to the Supabase CLI:

```sh
npx supabase login
npx supabase functions deploy market-invitations --project-ref vjmiuscmsittmexrmuve
```

The function uses the standard Supabase Edge Function environment variables for the project URL, anon key and service-role key. Do not put a service-role key in the website or commit it to GitHub.

For the local preview, invitation links can use `http://localhost:8000`. Before generating links from the deployed website, set the deployed site's origin as the `MARKET_APP_BASE_URL` Edge Function secret:

```sh
npx supabase secrets set MARKET_APP_BASE_URL=https://YOUR-GITHUB-PAGES-ORIGIN --project-ref vjmiuscmsittmexrmuve
```

Use the site's origin only (no page path), and replace the example with the exact GitHub Pages origin.

## How the first invitation flow works

1. An owner marks selected traders as Priority in the Traders tab.
2. In Invitations, the owner chooses a future scheduled market date.
3. The owner generates links for Priority traders first.
4. Later, the owner generates links for the remaining eligible (non-priority) traders.
5. Each link is unique to one trader and one market date. Only its SHA-256 hash is stored in the database.
6. The public `invite.html` page displays the event, location, date, opening time and snapshotted price.

Links are currently shown to the owner for copying and sending manually. Email delivery is deliberately not enabled until a sender/domain is configured and tested.

Opening an invitation only displays details. There is no accept, booking, or payment action in this stage. Those actions require the separate atomic capacity/booking and Stripe work.
