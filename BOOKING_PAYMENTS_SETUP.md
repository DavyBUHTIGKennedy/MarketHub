# MarketHub invitation booking and Stripe checkout foundation

This stage adds the secure server-side foundation for a trader to accept an invitation and pay for one pitch. It is a draft feature branch stacked on PR #12; it is not merged into `main`.

## What it adds

- A reservation hold linked to the invitation and the trader directory record (no trader login required).
- One reservation per trader per market date, enforced by a database unique constraint.
- Capacity allocation serialized by locking the market-date row in PostgreSQL. Two simultaneous requests cannot both take the final available pitch.
- Capacity checks include active reservations and existing legacy booking records.
- A 35-minute database hold; Stripe Checkout is configured to expire after 30 minutes.
- A Stripe payment-attempt ledger and webhook event deduplication.
- Booking confirmation only after a valid Stripe-signed `checkout.session.completed` webhook confirms the expected GBP amount.
- Automatic refund attempt if Stripe reports a payment that cannot safely be matched to a live hold or has an unexpected amount/currency.
- The invitation page now has a separate, explicit **Accept and pay** action. Merely opening the link still does not reserve or charge.
- The confirmation page checks the server-side reservation state. The browser return URL is not treated as proof of payment.

The existing `bookings` and `payments` tables are not rewritten. The new invitation flow uses separate tables so traders without website accounts can book securely.

## Database migration

After migration 007 has been applied, run:

`database/migrations/008_secure_reservations_and_payments.sql`

The new tables are inaccessible to anon/authenticated clients. Only the server-side service role can use them. The two database RPC functions are also executable only by `service_role`.

## Deploy the Edge Function

From the repository root:

```sh
npx supabase functions deploy market-checkout --project-ref vjmiuscmsittmexrmuve
```

The function is configured with `verify_jwt = false` because invitation tokens and Stripe webhooks do not use a logged-in browser session. The function validates the invitation token itself, and validates Stripe webhook signatures using the webhook signing secret.

## Stripe test-mode configuration

Do not enable live payments for the first test. Create/use a Stripe account and stay in **Test mode**.

Set these secrets in Supabase without putting them in website code or GitHub:

- `STRIPE_SECRET_KEY`: Stripe test-mode secret key (`sk_test_...`).
- `STRIPE_WEBHOOK_SECRET`: signing secret for the webhook endpoint (`whsec_...`).

Example command (replace the placeholders locally; never paste the values into chat):

```sh
npx supabase secrets set STRIPE_SECRET_KEY=sk_test_REPLACE_ME STRIPE_WEBHOOK_SECRET=whsec_REPLACE_ME --project-ref vjmiuscmsittmexrmuve
```

In Stripe Dashboard (Test mode), add a webhook endpoint:

`https://vjmiuscmsittmexrmuve.supabase.co/functions/v1/market-checkout`

Subscribe to:
- `checkout.session.completed`
- `checkout.session.expired`
- `checkout.session.async_payment_failed`

Copy that endpoint's signing secret into the Supabase `STRIPE_WEBHOOK_SECRET` secret.

The existing `MARKET_APP_BASE_URL` secret should remain the GitHub Pages origin. Do not change it for Stripe.

## Safety notes and current limits

- No card number or security code is stored by MarketHub; Stripe hosts checkout.
- Do not treat a successful browser redirect as payment confirmation. Only the signed webhook confirms.
- If a payment succeeds after its hold is no longer valid, the webhook attempts an idempotent refund and does not allocate the pitch.
- Stripe refunds that cannot be completed automatically remain flagged for organiser attention.
- The payment flow is not ready for live traders until the migration is applied, the function is deployed, Stripe test-mode secrets/webhook are configured, and the full test flow is verified.
- This is not a claim of completed financial, legal, or security certification.
