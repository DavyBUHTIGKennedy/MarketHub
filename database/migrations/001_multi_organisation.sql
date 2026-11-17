-- MarketHub multi-organisation upgrade.
-- Apply AFTER database/schema.sql in the Supabase SQL Editor.
-- This migration makes each market's operational data tenant-scoped.
-- It preserves the existing single-market demo data under "MarketHub Demo Market".

begin;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'trader' check (role in ('owner','admin','trader')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

insert into public.organizations (name, slug)
values ('MarketHub Demo Market', 'markethub-demo')
on conflict (slug) do nothing;

-- Backfill the existing prototype into one organisation, then require a tenant ID.
alter table public.market_locations add column if not exists organization_id uuid references public.organizations(id);
alter table public.pitches add column if not exists organization_id uuid references public.organizations(id);
alter table public.market_events add column if not exists organization_id uuid references public.organizations(id);
alter table public.bookings add column if not exists organization_id uuid references public.organizations(id);
alter table public.payments add column if not exists organization_id uuid references public.organizations(id);
alter table public.compliance_documents add column if not exists organization_id uuid references public.organizations(id);
alter table public.notifications add column if not exists organization_id uuid references public.organizations(id);
alter table public.audit_log add column if not exists organization_id uuid references public.organizations(id);

do $$
declare
  demo_org uuid;
begin
  select id into demo_org from public.organizations where slug = 'markethub-demo';
  update public.market_locations set organization_id = demo_org where organization_id is null;
  update public.pitches p set organization_id = l.organization_id
    from public.market_locations l where p.location_id = l.id and p.organization_id is null;
  update public.market_events set organization_id = demo_org where organization_id is null;
  update public.bookings b set organization_id = e.organization_id
    from public.market_events e where b.event_id = e.id and b.organization_id is null;
  update public.payments p set organization_id = b.organization_id
    from public.bookings b where p.booking_id = b.id and p.organization_id is null;
  update public.compliance_documents set organization_id = demo_org where organization_id is null;
  update public.notifications n set organization_id = coalesce(e.organization_id, demo_org)
    from public.market_events e where n.event_id = e.id and n.organization_id is null;
  update public.notifications set organization_id = demo_org where organization_id is null;
  update public.audit_log set organization_id = demo_org where organization_id is null;
end $$;

alter table public.market_locations alter column organization_id set not null;
alter table public.pitches alter column organization_id set not null;
alter table public.market_events alter column organization_id set not null;
alter table public.bookings alter column organization_id set not null;
alter table public.payments alter column organization_id set not null;
alter table public.compliance_documents alter column organization_id set not null;
alter table public.notifications alter column organization_id set not null;
alter table public.audit_log alter column organization_id set not null;

-- Location names are unique within an organisation, not across the whole platform.
alter table public.market_locations drop constraint if exists market_locations_name_key;
create unique index if not exists market_locations_org_name
  on public.market_locations(organization_id, name);
create index if not exists pitches_org_location on public.pitches(organization_id, location_id);
create index if not exists events_org_date on public.market_events(organization_id, event_date);
create index if not exists bookings_org_trader on public.bookings(organization_id, trader_id);
create index if not exists payments_org_trader on public.payments(organization_id, trader_id);
create index if not exists compliance_org_trader on public.compliance_documents(organization_id, trader_id);
create index if not exists notifications_org_recipient on public.notifications(organization_id, recipient_id);

-- Tenant-aware authorization helpers. SECURITY DEFINER avoids recursive RLS evaluation.
create or replace function public.is_org_member(target_org uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.organization_memberships m
    where m.organization_id = target_org and m.user_id = (select auth.uid())
  );
$$;

create or replace function public.is_org_admin(target_org uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.organization_memberships m
    where m.organization_id = target_org
      and m.user_id = (select auth.uid())
      and m.role in ('owner','admin')
  );
$$;

revoke all on function public.is_org_member(uuid) from public;
revoke all on function public.is_org_admin(uuid) from public;
grant execute on function public.is_org_member(uuid) to authenticated;
grant execute on function public.is_org_admin(uuid) to authenticated;

-- Existing profile role is legacy. Membership role is now authoritative.
-- Keep the existing profile-role protection trigger: users cannot promote themselves.

-- Ensure a booking's event, requested/allocated pitches and trader membership all belong
-- to the same organisation. Replaces the original single-market validation trigger.
create or replace function public.validate_market_booking()
returns trigger language plpgsql set search_path = public
as $$
declare
  ev public.market_events%rowtype;
  requested_pitch public.pitches%rowtype;
  allocated_pitch public.pitches%rowtype;
begin
  select * into ev from public.market_events where id = new.event_id;
  select * into requested_pitch from public.pitches where id = new.preferred_pitch_id;
  if ev.id is null or requested_pitch.id is null then
    raise exception 'Market date or pitch does not exist';
  end if;
  if new.organization_id is distinct from ev.organization_id
     or new.organization_id is distinct from requested_pitch.organization_id then
    raise exception 'Market, pitch and booking must belong to the same organisation';
  end if;
  if ev.status <> 'scheduled' or not requested_pitch.active then
    raise exception 'This market or pitch is not available';
  end if;
  if ev.location_id is distinct from requested_pitch.location_id then
    raise exception 'The selected pitch does not belong to this market location';
  end if;
  if not exists (
    select 1 from public.organization_memberships m
    where m.organization_id = new.organization_id and m.user_id = new.trader_id
  ) then
    raise exception 'Trader must be a member of this market organisation';
  end if;
  if new.status = 'pending' and new.allocated_pitch_id is not null then
    raise exception 'Pending applications cannot allocate a pitch';
  end if;
  if new.status in ('approved','reallocated') and new.allocated_pitch_id is null then
    new.allocated_pitch_id := new.preferred_pitch_id;
  end if;
  if new.allocated_pitch_id is not null then
    select * into allocated_pitch from public.pitches where id = new.allocated_pitch_id;
    if allocated_pitch.id is null
       or allocated_pitch.organization_id is distinct from new.organization_id
       or allocated_pitch.location_id is distinct from ev.location_id
       or not allocated_pitch.active then
      raise exception 'Allocated pitch does not belong to this market location and organisation';
    end if;
  end if;
  return new;
end;
$$;

-- Remove the former global policies. All exposed data is now scoped by organisation membership.
drop policy if exists profiles_read_own_or_admin on public.profiles;
drop policy if exists profiles_update_own_or_admin on public.profiles;
drop policy if exists locations_read_authenticated on public.market_locations;
drop policy if exists locations_admin_write on public.market_locations;
drop policy if exists pitches_read_authenticated on public.pitches;
drop policy if exists pitches_admin_write on public.pitches;
drop policy if exists events_read_authenticated on public.market_events;
drop policy if exists events_admin_write on public.market_events;
drop policy if exists bookings_read_own_or_admin on public.bookings;
drop policy if exists bookings_trader_create_own on public.bookings;
drop policy if exists bookings_admin_write on public.bookings;
drop policy if exists payments_read_own_or_admin on public.payments;
drop policy if exists payments_admin_write on public.payments;
drop policy if exists compliance_read_own_or_admin on public.compliance_documents;
drop policy if exists compliance_trader_submit_own on public.compliance_documents;
drop policy if exists compliance_admin_write on public.compliance_documents;
drop policy if exists notifications_read_own_or_admin on public.notifications;
drop policy if exists notifications_admin_write on public.notifications;
drop policy if exists audit_log_admin_read on public.audit_log;
drop policy if exists audit_log_no_client_write on public.audit_log;

alter table public.organizations enable row level security;
alter table public.organization_memberships enable row level security;

drop policy if exists organizations_member_read on public.organizations;
create policy organizations_member_read on public.organizations
for select to authenticated using (public.is_org_member(id));
drop policy if exists organizations_admin_update on public.organizations;
create policy organizations_admin_update on public.organizations
for update to authenticated using (public.is_org_admin(id))
with check (public.is_org_admin(id));

drop policy if exists memberships_member_read on public.organization_memberships;
create policy memberships_member_read on public.organization_memberships
for select to authenticated
using (user_id = (select auth.uid()) or public.is_org_admin(organization_id));
drop policy if exists memberships_admin_insert on public.organization_memberships;
create policy memberships_admin_insert on public.organization_memberships
for insert to authenticated with check (public.is_org_admin(organization_id));
drop policy if exists memberships_admin_update on public.organization_memberships;
create policy memberships_admin_update on public.organization_memberships
for update to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));
drop policy if exists memberships_admin_delete on public.organization_memberships;
create policy memberships_admin_delete on public.organization_memberships
for delete to authenticated using (public.is_org_admin(organization_id));

-- Profiles are personal accounts. An organisation administrator can see profiles
-- only for people who are members of that same organisation.
create policy profiles_read_own_or_org_admin on public.profiles
for select to authenticated using (
  id = (select auth.uid()) or exists (
    select 1 from public.organization_memberships target
    join public.organization_memberships actor
      on actor.organization_id = target.organization_id
    where target.user_id = profiles.id
      and actor.user_id = (select auth.uid())
      and actor.role in ('owner','admin')
  )
);
create policy profiles_update_own_or_org_admin on public.profiles
for update to authenticated using (
  id = (select auth.uid()) or exists (
    select 1 from public.organization_memberships target
    join public.organization_memberships actor
      on actor.organization_id = target.organization_id
    where target.user_id = profiles.id
      and actor.user_id = (select auth.uid())
      and actor.role in ('owner','admin')
  )
) with check (
  id = (select auth.uid()) or exists (
    select 1 from public.organization_memberships target
    join public.organization_memberships actor
      on actor.organization_id = target.organization_id
    where target.user_id = profiles.id
      and actor.user_id = (select auth.uid())
      and actor.role in ('owner','admin')
  )
);

create policy locations_member_read on public.market_locations
for select to authenticated using (public.is_org_member(organization_id));
create policy locations_admin_write on public.market_locations
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy pitches_member_read on public.pitches
for select to authenticated using (public.is_org_member(organization_id));
create policy pitches_admin_write on public.pitches
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy events_member_read on public.market_events
for select to authenticated using (public.is_org_member(organization_id));
create policy events_admin_write on public.market_events
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy bookings_read_own_or_org_admin on public.bookings
for select to authenticated using (
  public.is_org_member(organization_id)
  and (trader_id = (select auth.uid()) or public.is_org_admin(organization_id))
);
create policy bookings_trader_create_own on public.bookings
for insert to authenticated with check (
  public.is_org_member(organization_id)
  and trader_id = (select auth.uid())
  and status = 'pending'
  and allocated_pitch_id is null
  and reviewed_by is null
  and reviewed_at is null
);
create policy bookings_admin_write on public.bookings
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy payments_read_own_or_org_admin on public.payments
for select to authenticated using (
  public.is_org_member(organization_id)
  and (trader_id = (select auth.uid()) or public.is_org_admin(organization_id))
);
create policy payments_admin_write on public.payments
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy compliance_read_own_or_org_admin on public.compliance_documents
for select to authenticated using (
  public.is_org_member(organization_id)
  and (trader_id = (select auth.uid()) or public.is_org_admin(organization_id))
);
create policy compliance_trader_submit_own on public.compliance_documents
for insert to authenticated with check (
  public.is_org_member(organization_id)
  and trader_id = (select auth.uid())
  and review_status = 'pending'
  and reviewed_by is null
  and reviewed_at is null
);
create policy compliance_admin_write on public.compliance_documents
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy notifications_read_own_or_org_admin on public.notifications
for select to authenticated using (
  public.is_org_member(organization_id)
  and (recipient_id = (select auth.uid()) or public.is_org_admin(organization_id))
);
create policy notifications_admin_write on public.notifications
for all to authenticated using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

create policy audit_log_admin_read on public.audit_log
for select to authenticated using (public.is_org_admin(organization_id));
create policy audit_log_no_client_write on public.audit_log
for all to authenticated using (false) with check (false);

commit;

-- MANAGER BOOTSTRAP (run separately after creating the manager's Supabase Auth user):
-- Replace MANAGER-AUTH-USER-UUID with that user's exact auth.users UUID.
-- insert into public.organization_memberships (organization_id, user_id, role)
-- select id, 'MANAGER-AUTH-USER-UUID', 'owner'
-- from public.organizations where slug = 'markethub-demo'
-- on conflict (organization_id, user_id) do update set role = 'owner';
