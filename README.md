# MarketHub

Mobile-first market trader management prototype for weekly stall applications, administrator approval, market events, pitch/location setup, payments tracking and trader compliance.

## Run locally
No build step is required. Open `index.html` in a browser, or serve this folder with any static web server:

```bash
python -m http.server 8000
```

Then visit http://localhost:8000.

## Demo features
- Switch between administrator and trader demo views.
- Administrators manage locations and pitches, and create dated market events from the Market calendar.
- Seed locations include Warepoint (Food 1), Newcastle (Food 1–5 and Coffee 1–2), and Downpatrick (Food 1–5 and Coffee 1–2); the new pitches are £35 per week.
- Traders select a market date from a visual calendar, then choose from pitch cards for that market. A pitch already requested or approved for that date is shown as unavailable.
- Traders submit a pitch request for administrator approval; pitch availability is scoped to each market date.
- Administrators add pitches and events, cancel events, and mark payments as paid.
- Trader compliance overview and safety/resource links.
- Demo changes persist in the current browser using localStorage.

## Important limitations
This repository currently contains a front-end prototype, not a production service. Demo data is local to one browser and is not shared between users. There is no real account authentication, server-side authorization, document upload, email/SMS delivery, payment processing, or live Met Office/council data feed. The trader view uses a sample trader identity. Do not use it to collect real personal, financial or compliance documents.

Before launch, implement a secure backend (the SQL in `database/schema.sql` is a starting point), real user accounts and role-based access, server-side booking validation, audit logging, backups, privacy notices and tested integrations. Payment processing should use a compliant hosted checkout provider; never store card details in MarketHub.
