-- MarketHub security hardening: organisation roles are authoritative.
-- Apply AFTER 001_multi_organisation.sql.
-- This migration keeps legacy profile.role for backwards compatibility but prevents
-- browser clients from changing it. Organisation membership is the sole permission source.

begin;

-- The old global admin flag is no longer part of the authorisation model.
drop trigger if exists protect_market_profile_role on public.profiles;
drop function if exists public.protect_market_profile_role();
drop function if exists public.is_market_admin();

-- Traders may edit only their own basic contact fields. Organisation administrators
-- may edit member contact fields through the existing RLS policy, but nobody using
-- the authenticated browser role may change the legacy profile.role column.
revoke update on table public.profiles from authenticated;
grant update (full_name, business_name, phone)
  on table public.profiles to authenticated;

comment on column public.profiles.role is
  'Legacy compatibility field only. Do not use for authorization; use organization_memberships.role. Authenticated clients cannot update this column.';

-- Explicit owner helper, separate from the broader owner/admin check.
create or replace function public.is_org_owner(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_memberships m
    where m.organization_id = target_org
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  );
$$;

revoke all on function public.is_org_owner(uuid) from public;
grant execute on function public.is_org_owner(uuid) to authenticated;

-- Admins may manage trader memberships. Only owners may grant/revoke admin or owner
-- roles. The last owner cannot accidentally be demoted or removed. Trusted SQL
-- administration (where auth.uid() is null) remains available for recovery/bootstrap.
create or replace function public.guard_org_membership_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  remaining_owners integer;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;

  if tg_op = 'INSERT' then
    select m.role into actor_role
    from public.organization_memberships m
    where m.organization_id = new.organization_id
      and m.user_id = (select auth.uid());

    if actor_role is null or actor_role not in ('owner', 'admin') then
      raise exception 'Only an organisation owner or administrator can add members';
    end if;
    if actor_role = 'admin' and new.role <> 'trader' then
      raise exception 'Only an organisation owner can grant administrator or owner roles';
    end if;
    return new;
  end if;

  if new.organization_id is distinct from old.organization_id
     or new.user_id is distinct from old.user_id then
    raise exception 'Membership organisation and user cannot be changed';
  end if;

  select m.role into actor_role
  from public.organization_memberships m
  where m.organization_id = old.organization_id
    and m.user_id = (select auth.uid());

  if actor_role = 'owner' then
    if old.role = 'owner' and new.role is distinct from 'owner' then
      select count(*) into remaining_owners
      from public.organization_memberships m
      where m.organization_id = old.organization_id
        and m.role = 'owner'
        and m.user_id <> old.user_id;
      if remaining_owners < 1 then
        raise exception 'An organisation must retain at least one owner';
      end if;
    end if;
    return new;
  end if;

  if actor_role = 'admin' then
    if old.role <> 'trader' or new.role <> 'trader' then
      raise exception 'Administrators may manage trader memberships only';
    end if;
    return new;
  end if;

  raise exception 'Only an organisation owner or administrator can change memberships';
end;
$$;

drop trigger if exists guard_org_membership_change on public.organization_memberships;
create trigger guard_org_membership_change
before insert or update on public.organization_memberships
for each row execute function public.guard_org_membership_change();

create or replace function public.guard_org_membership_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  remaining_owners integer;
begin
  if auth.uid() is null then
    return old;
  end if;

  select m.role into actor_role
  from public.organization_memberships m
  where m.organization_id = old.organization_id
    and m.user_id = (select auth.uid());

  if actor_role = 'owner' then
    if old.role = 'owner' then
      select count(*) into remaining_owners
      from public.organization_memberships m
      where m.organization_id = old.organization_id
        and m.role = 'owner'
        and m.user_id <> old.user_id;
      if remaining_owners < 1 then
        raise exception 'An organisation must retain at least one owner';
      end if;
    end if;
    return old;
  end if;

  if actor_role = 'admin' and old.role = 'trader' then
    return old;
  end if;

  raise exception 'Administrators may remove trader memberships only';
end;
$$;

drop trigger if exists guard_org_membership_delete on public.organization_memberships;
create trigger guard_org_membership_delete
before delete on public.organization_memberships
for each row execute function public.guard_org_membership_delete();

-- Keep RLS as the outer boundary and apply the same owner/admin distinction there.
drop policy if exists memberships_admin_insert on public.organization_memberships;
create policy memberships_admin_insert on public.organization_memberships
for insert to authenticated
with check (
  public.is_org_admin(organization_id)
  and (role = 'trader' or public.is_org_owner(organization_id))
);

drop policy if exists memberships_admin_update on public.organization_memberships;
create policy memberships_admin_update on public.organization_memberships
for update to authenticated
using (public.is_org_admin(organization_id))
with check (
  public.is_org_admin(organization_id)
  and (role = 'trader' or public.is_org_owner(organization_id))
);

drop policy if exists memberships_admin_delete on public.organization_memberships;
create policy memberships_admin_delete on public.organization_memberships
for delete to authenticated
using (public.is_org_admin(organization_id));

commit;
