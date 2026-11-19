-- MarketHub migration 007: secure invitation records for market dates.
-- Raw invitation tokens are never stored in the database. Only SHA-256 hashes
-- are persisted; issuance and public token resolution run through Edge Functions.

begin;

alter table public.market_traders
  add column if not exists is_priority boolean not null default false;

create table if not exists public.market_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_id uuid not null,
  trader_id uuid not null,
  token_hash text not null unique
    check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending','viewed','expired','cancelled','accepted')),
  event_name text not null,
  event_date date not null,
  location_name text not null,
  opening_time time,
  pitch_price numeric(10,2) not null check (pitch_price >= 0),
  trader_name text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  viewed_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, trader_id),
  foreign key (event_id, organization_id)
    references public.market_events(id, organization_id) on delete cascade,
  foreign key (trader_id, organization_id)
    references public.market_traders(id, organization_id) on delete cascade
);

create index if not exists market_invitations_org_event
  on public.market_invitations (organization_id, event_id, status);
create index if not exists market_invitations_expiry
  on public.market_invitations (expires_at)
  where status in ('pending','viewed');

alter table public.market_invitations enable row level security;

drop policy if exists market_invitations_admin_read
  on public.market_invitations;
create policy market_invitations_admin_read
on public.market_invitations
for select to authenticated
using (public.is_org_admin(organization_id));

-- No direct authenticated or anonymous writes/reads by token. Edge Functions
-- use the service role after checking the caller's organisation role.
revoke all on table public.market_invitations from anon, authenticated;
grant select on table public.market_invitations to authenticated;

comment on table public.market_invitations is
  'One invitation per trader per market date. Stores only a SHA-256 token hash and event price/details snapshot; raw tokens are issued by a trusted Edge Function.';
comment on column public.market_traders.is_priority is
  'Owner-managed priority flag for staged market invitation rounds.';

commit;
