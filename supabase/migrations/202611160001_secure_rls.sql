-- MarketHub secure baseline: Supabase PostgreSQL RLS and signup profile provisioning.
-- Apply after database/schema.sql, or use this file as the authoritative migration.
create or replace function public.is_markethub_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin'
  );
$$;

revoke all on function public.is_markethub_admin() from public;
grant execute on function public.is_markethub_admin() to authenticated;

-- Automatically create a trader profile for each newly registered auth user.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, business_name, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'business_name', ''),
    'trader'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_markethub on auth.users;
create trigger on_auth_user_created_markethub
after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Prevent users from changing their own role, even if they can edit profile fields.
create or replace function public.prevent_profile_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.role is distinct from old.role
     and not public.is_markethub_admin() then
    raise exception 'Only a MarketHub administrator can change account roles';
  end if;
  return new;
end;
$$;

drop trigger if exists prevent_profile_role_escalation on public.profiles;
create trigger prevent_profile_role_escalation
before update on public.profiles
for each row execute procedure public.prevent_profile_role_escalation();

-- An approved pitch can only be allocated once per event.
create unique index if not exists bookings_one_active_pitch_per_event
on public.bookings(event_id, allocated_pitch_id)
where allocated_pitch_id is not null
  and status in ('approved', 'reallocated');

-- One trader may only have one active booking per event.
create unique index if not exists bookings_one_active_booking_per_trader
on public.bookings(event_id, trader_id)
where status in ('pending', 'approved', 'reallocated');

-- RLS policies. Policies are intentionally explicit and deny access by default.
alter table public.profiles enable row level security;
alter table public.market_locations enable row level security;
alter table public.pitches enable row level security;
alter table public.market_events enable row level security;
alter table public.bookings enable row level security;
alter table public.payments enable row level security;
alter table public.compliance_documents enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "profiles_read_self_or_admin" on public.profiles;
create policy "profiles_read_self_or_admin" on public.profiles
for select to authenticated
using (id = (select auth.uid()) or (select public.is_markethub_admin()));

drop policy if exists "profiles_update_self_or_admin" on public.profiles;
create policy "profiles_update_self_or_admin" on public.profiles
for update to authenticated
using (id = (select auth.uid()) or (select public.is_markethub_admin()))
with check (id = (select auth.uid()) or (select public.is_markethub_admin()));

drop policy if exists "locations_read_authenticated" on public.market_locations;
create policy "locations_read_authenticated" on public.market_locations
for select to authenticated using (true);
drop policy if exists "locations_admin_manage" on public.market_locations;
create policy "locations_admin_manage" on public.market_locations
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "pitches_read_authenticated" on public.pitches;
create policy "pitches_read_authenticated" on public.pitches
for select to authenticated using (true);
drop policy if exists "pitches_admin_manage" on public.pitches;
create policy "pitches_admin_manage" on public.pitches
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "events_read_authenticated" on public.market_events;
create policy "events_read_authenticated" on public.market_events
for select to authenticated using (true);
drop policy if exists "events_admin_manage" on public.market_events;
create policy "events_admin_manage" on public.market_events
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "bookings_read_own_or_admin" on public.bookings;
create policy "bookings_read_own_or_admin" on public.bookings
for select to authenticated
using (trader_id = (select auth.uid()) or (select public.is_markethub_admin()));
drop policy if exists "traders_submit_own_pending_booking" on public.bookings;
create policy "traders_submit_own_pending_booking" on public.bookings
for insert to authenticated
with check (
  trader_id = (select auth.uid())
  and status = 'pending'
  and reviewed_by is null
  and reviewed_at is null
  and allocated_pitch_id is null
);
drop policy if exists "admins_manage_bookings" on public.bookings;
create policy "admins_manage_bookings" on public.bookings
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "payments_read_own_or_admin" on public.payments;
create policy "payments_read_own_or_admin" on public.payments
for select to authenticated
using (trader_id = (select auth.uid()) or (select public.is_markethub_admin()));
drop policy if exists "payments_admin_manage" on public.payments;
create policy "payments_admin_manage" on public.payments
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "compliance_read_own_or_admin" on public.compliance_documents;
create policy "compliance_read_own_or_admin" on public.compliance_documents
for select to authenticated
using (trader_id = (select auth.uid()) or (select public.is_markethub_admin()));
drop policy if exists "traders_submit_own_compliance" on public.compliance_documents;
create policy "traders_submit_own_compliance" on public.compliance_documents
for insert to authenticated
with check (
  trader_id = (select auth.uid())
  and review_status = 'pending'
  and reviewed_by is null
  and reviewed_at is null
);
drop policy if exists "admins_manage_compliance" on public.compliance_documents;
create policy "admins_manage_compliance" on public.compliance_documents
for all to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

drop policy if exists "notifications_read_own_or_admin" on public.notifications;
create policy "notifications_read_own_or_admin" on public.notifications
for select to authenticated
using (recipient_id = (select auth.uid()) or (select public.is_markethub_admin()));
drop policy if exists "admins_create_notifications" on public.notifications;
create policy "admins_create_notifications" on public.notifications
for insert to authenticated
with check ((select public.is_markethub_admin()));
drop policy if exists "admins_update_notifications" on public.notifications;
create policy "admins_update_notifications" on public.notifications
for update to authenticated
using ((select public.is_markethub_admin()))
with check ((select public.is_markethub_admin()));

-- IMPORTANT: Set the first admin manually from the Supabase SQL editor after
-- the intended user has registered and their profile row exists:
-- update public.profiles set role = 'admin' where id = '<AUTH_USER_UUID>';
-- Never expose a service-role key in the browser.
