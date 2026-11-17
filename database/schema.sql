-- MarketHub production starter schema for Supabase / PostgreSQL.
-- Apply in the Supabase SQL Editor. All application tables use RLS.
-- The browser must use ONLY the project URL + anon/publishable key, never service_role.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  business_name text,
  phone text,
  role text not null default 'trader' check (role in ('admin','trader')),
  created_at timestamptz not null default now()
);

create table if not exists public.market_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.pitches (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.market_locations(id),
  pitch_code text not null,
  description text,
  weekly_price numeric(10,2) not null default 0 check (weekly_price >= 0),
  active boolean not null default true,
  unique(location_id, pitch_code)
);

create table if not exists public.market_events (
  id uuid primary key default gen_random_uuid(),
  location_id uuid references public.market_locations(id),
  name text not null,
  event_date date not null,
  opening_time time,
  status text not null default 'scheduled' check (status in ('scheduled','cancelled','completed')),
  cancellation_message text,
  created_at timestamptz not null default now()
);

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.market_events(id),
  trader_id uuid not null references public.profiles(id),
  preferred_pitch_id uuid not null references public.pitches(id),
  allocated_pitch_id uuid references public.pitches(id),
  status text not null default 'pending' check (status in ('pending','approved','reallocated','rejected','cancelled')),
  trader_notes text,
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id),
  trader_id uuid not null references public.profiles(id),
  amount numeric(10,2) not null check (amount >= 0),
  currency char(3) not null default 'GBP',
  status text not null default 'due' check (status in ('due','pending','paid','refunded','failed')),
  provider_reference text,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.compliance_documents (
  id uuid primary key default gen_random_uuid(),
  trader_id uuid not null references public.profiles(id),
  document_type text not null,
  storage_path text,
  expires_on date,
  review_status text not null default 'pending' check (review_status in ('pending','approved','rejected','expired')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid references public.profiles(id),
  event_id uuid references public.market_events(id),
  channel text not null default 'in_app' check (channel in ('in_app','email','sms','whatsapp')),
  message text not null,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id),
  action text not null,
  table_name text not null,
  record_id text,
  created_at timestamptz not null default now()
);

-- Upgrade older prototype schema safely.
alter table public.market_events add column if not exists opening_time time;
alter table public.profiles alter column full_name set default '';

-- Security helper: SECURITY DEFINER avoids recursive profile RLS checks.
create or replace function public.is_market_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin'
  );
$$;

revoke all on function public.is_market_admin() from public;
grant execute on function public.is_market_admin() to authenticated;

-- Create a trader profile automatically when a user signs up.
-- Role is deliberately fixed to trader; an admin must promote the manager manually.
create or replace function public.handle_new_market_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, business_name, phone, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    nullif(new.raw_user_meta_data ->> 'business_name', ''),
    nullif(new.raw_user_meta_data ->> 'phone', ''),
    'trader'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_markethub on auth.users;
create trigger on_auth_user_created_markethub
after insert on auth.users
for each row execute procedure public.handle_new_market_user();

-- Prevent users from changing their own role or administrator review fields.
create or replace function public.protect_market_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.role is distinct from old.role and not public.is_market_admin() then
    raise exception 'Only a market administrator can change account roles';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_market_profile_role on public.profiles;
create trigger protect_market_profile_role
before update on public.profiles
for each row execute procedure public.protect_market_profile_role();

create or replace function public.validate_market_booking()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  ev public.market_events%rowtype;
  pp public.pitches%rowtype;
begin
  select * into ev from public.market_events where id = new.event_id;
  select * into pp from public.pitches where id = new.preferred_pitch_id;
  if ev.id is null or pp.id is null then
    raise exception 'Market date or pitch does not exist';
  end if;
  if ev.status <> 'scheduled' or not pp.active then
    raise exception 'This market or pitch is not available';
  end if;
  if ev.location_id is distinct from pp.location_id then
    raise exception 'The selected pitch does not belong to this market location';
  end if;
  if new.status = 'pending' and new.allocated_pitch_id is not null then
    raise exception 'Pending applications cannot allocate a pitch';
  end if;
  if new.status in ('approved','reallocated') and new.allocated_pitch_id is null then
    new.allocated_pitch_id := new.preferred_pitch_id;
  end if;
  if new.allocated_pitch_id is not null and not exists (
    select 1 from public.pitches p
    where p.id = new.allocated_pitch_id and p.location_id = ev.location_id and p.active
  ) then
    raise exception 'Allocated pitch does not belong to this market location';
  end if;
  return new;
end;
$$;

drop trigger if exists validate_market_booking on public.bookings;
create trigger validate_market_booking
before insert or update on public.bookings
for each row execute procedure public.validate_market_booking();

-- A pitch cannot be requested or allocated twice for the same event.
-- COALESCE makes pending preferences conflict with approved allocations too.
drop index if exists public.bookings_one_pending_preference;
drop index if exists public.bookings_one_active_allocation;
create unique index if not exists bookings_one_active_pitch_per_event
on public.bookings(event_id, (coalesce(allocated_pitch_id, preferred_pitch_id)))
where status in ('pending','approved','reallocated');

-- Enable row-level security on every exposed table.
alter table public.profiles enable row level security;
alter table public.market_locations enable row level security;
alter table public.pitches enable row level security;
alter table public.market_events enable row level security;
alter table public.bookings enable row level security;
alter table public.payments enable row level security;
alter table public.compliance_documents enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_log enable row level security;

-- Profiles: traders see/edit their own contact/profile fields; admins manage all.
drop policy if exists profiles_read_own_or_admin on public.profiles;
create policy profiles_read_own_or_admin on public.profiles
for select to authenticated
using (id = (select auth.uid()) or public.is_market_admin());

drop policy if exists profiles_update_own_or_admin on public.profiles;
create policy profiles_update_own_or_admin on public.profiles
for update to authenticated
using (id = (select auth.uid()) or public.is_market_admin())
with check (id = (select auth.uid()) or public.is_market_admin());

-- Market setup is visible to signed-in users; only admins can change it.
drop policy if exists locations_read_authenticated on public.market_locations;
create policy locations_read_authenticated on public.market_locations
for select to authenticated using (true);
drop policy if exists locations_admin_write on public.market_locations;
create policy locations_admin_write on public.market_locations
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

drop policy if exists pitches_read_authenticated on public.pitches;
create policy pitches_read_authenticated on public.pitches
for select to authenticated using (true);
drop policy if exists pitches_admin_write on public.pitches;
create policy pitches_admin_write on public.pitches
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

drop policy if exists events_read_authenticated on public.market_events;
create policy events_read_authenticated on public.market_events
for select to authenticated using (true);
drop policy if exists events_admin_write on public.market_events;
create policy events_admin_write on public.market_events
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

-- Traders can create/read their own applications. Only admins can review/change them.
drop policy if exists bookings_read_own_or_admin on public.bookings;
create policy bookings_read_own_or_admin on public.bookings
for select to authenticated
using (trader_id = (select auth.uid()) or public.is_market_admin());
drop policy if exists bookings_trader_create_own on public.bookings;
create policy bookings_trader_create_own on public.bookings
for insert to authenticated
with check (
  trader_id = (select auth.uid())
  and status = 'pending'
  and allocated_pitch_id is null
  and reviewed_by is null
  and reviewed_at is null
);
drop policy if exists bookings_admin_write on public.bookings;
create policy bookings_admin_write on public.bookings
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

-- Payments are visible to the relevant trader and administrators; only admins write.
drop policy if exists payments_read_own_or_admin on public.payments;
create policy payments_read_own_or_admin on public.payments
for select to authenticated
using (trader_id = (select auth.uid()) or public.is_market_admin());
drop policy if exists payments_admin_write on public.payments;
create policy payments_admin_write on public.payments
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

-- Traders can view and submit their own compliance metadata; admins review/manage.
drop policy if exists compliance_read_own_or_admin on public.compliance_documents;
create policy compliance_read_own_or_admin on public.compliance_documents
for select to authenticated
using (trader_id = (select auth.uid()) or public.is_market_admin());
drop policy if exists compliance_trader_submit_own on public.compliance_documents;
create policy compliance_trader_submit_own on public.compliance_documents
for insert to authenticated
with check (
  trader_id = (select auth.uid())
  and review_status = 'pending'
  and reviewed_by is null
  and reviewed_at is null
);
drop policy if exists compliance_admin_write on public.compliance_documents;
create policy compliance_admin_write on public.compliance_documents
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

-- Notifications are private to the recipient and administrators.
drop policy if exists notifications_read_own_or_admin on public.notifications;
create policy notifications_read_own_or_admin on public.notifications
for select to authenticated
using (recipient_id = (select auth.uid()) or public.is_market_admin());
drop policy if exists notifications_admin_write on public.notifications;
create policy notifications_admin_write on public.notifications
for all to authenticated using (public.is_market_admin())
with check (public.is_market_admin());

-- Audit log is administrator-only. Writes will be performed by trusted server-side code later.
drop policy if exists audit_log_admin_read on public.audit_log;
create policy audit_log_admin_read on public.audit_log
for select to authenticated using (public.is_market_admin());
drop policy if exists audit_log_no_client_write on public.audit_log;
create policy audit_log_no_client_write on public.audit_log
for all to authenticated using (false) with check (false);

-- Seed the two agreed market locations and their seven pitches each.
insert into public.market_locations (name)
values ('Newcastle'), ('Downpatrick')
on conflict (name) do nothing;

insert into public.pitches (location_id, pitch_code, weekly_price)
select l.id, p.pitch_code, 35
from public.market_locations l
cross join (values ('Food 1'),('Food 2'),('Food 3'),('Food 4'),('Food 5'),('Coffee 1'),('Coffee 2')) as p(pitch_code)
where l.name in ('Newcastle','Downpatrick')
on conflict (location_id, pitch_code) do nothing;

-- IMPORTANT ADMIN BOOTSTRAP:
-- 1. Create the manager's account using Supabase Auth.
-- 2. In the SQL Editor, run this with the manager's exact auth.users UUID:
--    update public.profiles set role = 'admin' where id = 'MANAGER-AUTH-USER-UUID';
-- Do not expose the service_role key in the website or GitHub.
