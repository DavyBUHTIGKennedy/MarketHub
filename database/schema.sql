-- MarketHub starter schema for PostgreSQL / Supabase.
-- Review and enable row-level security policies before production use.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  business_name text,
  phone text,
  role text not null default 'trader' check (role in ('admin','trader')),
  created_at timestamptz not null default now()
);

create table if not exists public.market_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
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
  channel text not null default 'in_app' check (channel in ('in_app','email','sms')),
  message text not null,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

-- Enable RLS as a baseline. Add reviewed policies before exposing tables to clients.
alter table public.profiles enable row level security;
alter table public.market_locations enable row level security;
alter table public.pitches enable row level security;
alter table public.market_events enable row level security;
alter table public.bookings enable row level security;
alter table public.payments enable row level security;
alter table public.compliance_documents enable row level security;
alter table public.notifications enable row level security;
