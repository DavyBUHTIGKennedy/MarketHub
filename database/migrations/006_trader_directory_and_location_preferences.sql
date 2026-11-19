-- MarketHub migration 006: organisation-scoped trader directory and location eligibility.
-- Traders are records independent of website login accounts, so invitation links can
-- work without requiring traders to create or use a password.
-- A missing location preference is not used to mean "not eligible": triggers create
-- explicit YES rows for every current location/trader and keep defaults in sync.

begin;

create table if not exists public.market_traders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null check (email = lower(btrim(email)) and email <> ''),
  full_name text not null default '',
  business_name text,
  phone text,
  auth_user_id uuid references auth.users(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);

create unique index if not exists market_traders_org_email
  on public.market_traders (organization_id, lower(email));
create unique index if not exists market_traders_org_auth_user
  on public.market_traders (organization_id, auth_user_id)
  where auth_user_id is not null;
create index if not exists market_traders_org_active
  on public.market_traders (organization_id, active);

create table if not exists public.market_trader_location_preferences (
  organization_id uuid not null,
  trader_id uuid not null,
  location_id uuid not null,
  is_eligible boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (trader_id, location_id),
  foreign key (trader_id, organization_id)
    references public.market_traders(id, organization_id) on delete cascade,
  foreign key (location_id, organization_id)
    references public.market_locations(id, organization_id) on delete cascade
);

create index if not exists trader_location_preferences_org_location
  on public.market_trader_location_preferences (organization_id, location_id, is_eligible);

-- Backfill existing organisation trader accounts into the new directory.
-- Existing profiles, memberships, bookings and payments are not changed.
insert into public.market_traders (
  organization_id, email, full_name, business_name, phone, auth_user_id
)
select
  m.organization_id,
  lower(btrim(u.email)),
  coalesce(p.full_name, ''),
  p.business_name,
  p.phone,
  m.user_id
from public.organization_memberships m
join auth.users u on u.id = m.user_id
left join public.profiles p on p.id = m.user_id
where m.role = 'trader'
  and u.email is not null
  and btrim(u.email) <> ''
on conflict do nothing;

-- Existing traders are eligible at every existing location unless the owner later
-- changes a specific preference to NO.
insert into public.market_trader_location_preferences (
  organization_id, trader_id, location_id, is_eligible
)
select t.organization_id, t.id, l.id, true
from public.market_traders t
join public.market_locations l on l.organization_id = t.organization_id
on conflict (trader_id, location_id) do nothing;

-- Keep new traders eligible at every existing location by default.
create or replace function public.add_default_trader_location_preferences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.market_trader_location_preferences (
    organization_id, trader_id, location_id, is_eligible
  )
  select new.organization_id, new.id, l.id, true
  from public.market_locations l
  where l.organization_id = new.organization_id
  on conflict (trader_id, location_id) do nothing;
  return new;
end;
$$;

-- Keep existing traders eligible at every newly-created location by default.
create or replace function public.add_default_location_trader_preferences()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.market_trader_location_preferences (
    organization_id, trader_id, location_id, is_eligible
  )
  select t.organization_id, t.id, new.id, true
  from public.market_traders t
  where t.organization_id = new.organization_id
  on conflict (trader_id, location_id) do nothing;
  return new;
end;
$$;

drop trigger if exists market_trader_default_locations on public.market_traders;
create trigger market_trader_default_locations
after insert on public.market_traders
for each row execute function public.add_default_trader_location_preferences();

drop trigger if exists market_location_default_traders on public.market_locations;
create trigger market_location_default_traders
after insert on public.market_locations
for each row execute function public.add_default_location_trader_preferences();

alter table public.market_traders enable row level security;
alter table public.market_trader_location_preferences enable row level security;

drop policy if exists market_traders_read_own_or_admin on public.market_traders;
create policy market_traders_read_own_or_admin
on public.market_traders
for select to authenticated
using (
  public.is_org_member(organization_id)
  and (
    auth_user_id = (select auth.uid())
    or public.is_org_admin(organization_id)
  )
);

drop policy if exists market_traders_admin_write on public.market_traders;
create policy market_traders_admin_write
on public.market_traders
for all to authenticated
using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

drop policy if exists trader_location_preferences_read_own_or_admin
on public.market_trader_location_preferences;
create policy trader_location_preferences_read_own_or_admin
on public.market_trader_location_preferences
for select to authenticated
using (
  public.is_org_member(organization_id)
  and (
    public.is_org_admin(organization_id)
    or exists (
      select 1
      from public.market_traders t
      where t.id = trader_id
        and t.organization_id = organization_id
        and t.auth_user_id = (select auth.uid())
    )
  )
);

drop policy if exists trader_location_preferences_admin_write
on public.market_trader_location_preferences;
create policy trader_location_preferences_admin_write
on public.market_trader_location_preferences
for all to authenticated
using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

grant select, insert, update, delete
on table public.market_traders, public.market_trader_location_preferences
to authenticated;

revoke all on function public.add_default_trader_location_preferences() from public, anon, authenticated;
revoke all on function public.add_default_location_trader_preferences() from public, anon, authenticated;

comment on table public.market_traders is
  'Organisation-scoped trader contact records. A Supabase Auth account is optional; invitation links do not require login.';
comment on table public.market_trader_location_preferences is
  'Permanent location eligibility. New trader/location pairs default to eligible; owners can set is_eligible=false for an individual pair.';

commit;
