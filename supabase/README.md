# Supabase setup

1. Create a Supabase project and keep its database credentials private.
2. In the SQL Editor, run `database/schema.sql` if starting from an empty database.
3. Run `supabase/migrations/202611160001_secure_rls.sql`.
4. In Authentication settings, configure the correct site URL and redirect URLs for your eventual domain.
5. Register the intended administrator using the app's future signup flow. Find that user's UUID in Authentication → Users, then run the one-time admin bootstrap SQL at the bottom of the migration.
6. Create a **private** Storage bucket named `compliance-documents`. Add narrowly scoped storage policies before enabling uploads; do not make this bucket public.
7. Configure SMTP before relying on email confirmations or password resets.

The current `index.html` is still a local demo and does not connect to Supabase. The environment template is for the next frontend integration step. Never commit real keys or secrets.
