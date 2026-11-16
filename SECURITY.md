# Security and launch checklist

## Included in this branch
- PostgreSQL row-level security policies for the core tables.
- New auth users receive a trader profile by default.
- Only an administrator can promote/demote roles.
- Traders can submit their own pending applications and compliance metadata.
- Traders can read only their own bookings, payment rows, compliance records and notifications.
- Administrators can manage market configuration and review records.
- Unique indexes prevent duplicate active bookings for the same trader/event and duplicate allocated pitches for an event.

## Still required before production
- Connect the frontend to Supabase Auth and remove the demo role switch.
- Restrict profile updates to safe columns at the API layer; do not allow users to edit role or privileged metadata.
- Implement server-side booking approval/reallocation as a database function or trusted server endpoint, with a transaction and audit log.
- Add private Storage policies for compliance files, file type/size validation, malware scanning and retention rules.
- Add audit logs for administrator actions and event cancellations.
- Integrate a hosted payment provider and verify signed webhooks server-side.
- Integrate official weather/council sources and a notification provider; store delivery status and retry safely.
- Add tests for RLS using separate trader and admin accounts.
- Complete privacy, accessibility, data-protection and operational reviews before inviting real traders.

The SQL is a security foundation, not a certification or a substitute for testing. Have a qualified developer review it before production use.
