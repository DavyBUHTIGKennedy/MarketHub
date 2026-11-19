-- MarketHub migration 008: invitation-linked reservations and Stripe payment ledger.
-- This deliberately leaves legacy bookings/payments untouched. The new invitation
-- flow uses market_traders (which do not require website accounts) and event-level
-- capacity, with a row lock on market_events to serialize the final available pitch.

begin;

create table if not exists public.market_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  trader_id uuid not null,
  invitation_id uuid not null unique references public.market_invitations(id) on delete restrict,
  status text not null default 'held'
    check (status in ('held','confirmed','expired','cancelled','refund_required','refunded')),
  amount numeric(10,2) not null check (amount >= 0),
  currency char(3) not null default 'GBP' check (currency = 'GBP'),
  hold_expires_at timestamptz not null,
  stripe_checkout_session_id text unique,
  stripe_checkout_url text,
  stripe_payment_intent_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  unique (event_id, trader_id),
  foreign key (event_id, organization_id)
    references public.market_events(id, organization_id) on delete cascade,
  foreign key (trader_id, organization_id)
    references public.market_traders(id, organization_id) on delete cascade
);

create index if not exists market_reservations_event_capacity
  on public.market_reservations(event_id, status, hold_expires_at);

create table if not exists public.market_payment_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  reservation_id uuid not null references public.market_reservations(id) on delete restrict,
  stripe_checkout_session_id text not null unique,
  stripe_payment_intent_id text unique,
  checkout_url text not null,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null default 'GBP' check (currency = 'GBP'),
  status text not null default 'checkout_open'
    check (status in ('checkout_open','paid','expired','failed','refund_required','refunded')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  paid_at timestamptz
);

create index if not exists market_payment_transactions_reservation
  on public.market_payment_transactions(reservation_id, created_at desc);

create table if not exists public.market_stripe_webhook_events (
  stripe_event_id text primary key,
  event_type text not null,
  processed_at timestamptz not null default now()
);

alter table public.market_reservations enable row level security;
alter table public.market_payment_transactions enable row level security;
alter table public.market_stripe_webhook_events enable row level security;

revoke all on table public.market_reservations,
  public.market_payment_transactions,
  public.market_stripe_webhook_events from anon, authenticated;

grant all on table public.market_reservations,
  public.market_payment_transactions,
  public.market_stripe_webhook_events to service_role;

create or replace function public.create_market_reservation(p_token_hash text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.market_invitations%rowtype;
  ev public.market_events%rowtype;
  trader public.market_traders%rowtype;
  existing_res public.market_reservations%rowtype;
  active_reservations integer;
  legacy_bookings integer;
  event_capacity integer;
  hold_until timestamptz;
  reservation_id uuid;
begin
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'This invitation link is invalid.';
  end if;

  select * into inv
  from public.market_invitations
  where token_hash = p_token_hash
  for update;

  if inv.id is null or inv.status not in ('pending','viewed') or inv.expires_at <= now() then
    raise exception 'This invitation has expired or is no longer available.';
  end if;

  select * into ev
  from public.market_events
  where id = inv.event_id and organization_id = inv.organization_id
  for update;

  if ev.id is null or ev.status <> 'scheduled' or ev.pitch_capacity <= 0 then
    raise exception 'This market is not accepting bookings.';
  end if;

  if ev.event_date <= current_date then
    raise exception 'This market date has passed.';
  end if;

  select * into trader
  from public.market_traders
  where id = inv.trader_id and organization_id = inv.organization_id and active;

  if trader.id is null then
    raise exception 'This trader is no longer eligible to book.';
  end if;

  if not exists (
    select 1 from public.market_trader_location_preferences pref
    where pref.organization_id = inv.organization_id
      and pref.trader_id = inv.trader_id
      and pref.location_id = ev.location_id
      and pref.is_eligible
  ) then
    raise exception 'This trader is not eligible for this market location.';
  end if;

  select * into existing_res
  from public.market_reservations
  where event_id = inv.event_id and trader_id = inv.trader_id
  for update;

  if existing_res.id is not null and existing_res.status in ('confirmed','refund_required') then
    raise exception 'This trader already has a confirmed booking or a payment requiring organiser review.';
  end if;

  if existing_res.id is not null
     and existing_res.status = 'held'
     and existing_res.hold_expires_at > now()
     and existing_res.stripe_checkout_url is not null then
    return jsonb_build_object(
      'reservation_id', existing_res.id,
      'organization_id', existing_res.organization_id,
      'amount', existing_res.amount,
      'currency', existing_res.currency,
      'hold_expires_at', existing_res.hold_expires_at,
      'checkout_session_id', existing_res.stripe_checkout_session_id,
      'checkout_url', existing_res.stripe_checkout_url,
      'reused', true
    );
  end if;

  if trader.auth_user_id is not null and exists (
    select 1 from public.bookings b
    where b.organization_id = inv.organization_id
      and b.event_id = inv.event_id
      and b.trader_id = trader.auth_user_id
      and b.status in ('pending','approved','reallocated')
  ) then
    raise exception 'This trader already has a booking or application for this market date.';
  end if;

  select count(*)::integer into active_reservations
  from public.market_reservations r
  where r.event_id = inv.event_id
    and r.status in ('confirmed','held')
    and (r.status = 'confirmed' or r.hold_expires_at > now())
    and (existing_res.id is null or r.id <> existing_res.id);

  select count(*)::integer into legacy_bookings
  from public.bookings b
  where b.organization_id = inv.organization_id
    and b.event_id = inv.event_id
    and b.status in ('pending','approved','reallocated');

  event_capacity := ev.pitch_capacity;
  if active_reservations + legacy_bookings >= event_capacity then
    raise exception 'Sorry, all pitches for this market date have been taken.';
  end if;

  hold_until := now() + interval '35 minutes';

  if existing_res.id is null then
    insert into public.market_reservations (
      organization_id, event_id, trader_id, invitation_id,
      status, amount, currency, hold_expires_at
    ) values (
      inv.organization_id, inv.event_id, inv.trader_id, inv.id,
      'held', inv.pitch_price, 'GBP', hold_until
    ) returning id into reservation_id;
  else
    update public.market_reservations
    set invitation_id = inv.id,
        status = 'held',
        amount = inv.pitch_price,
        currency = 'GBP',
        hold_expires_at = hold_until,
        stripe_checkout_session_id = null,
        stripe_checkout_url = null,
        stripe_payment_intent_id = null,
        updated_at = now()
    where id = existing_res.id
    returning id into reservation_id;
  end if;

  return jsonb_build_object(
    'reservation_id', reservation_id,
    'organization_id', inv.organization_id,
    'amount', inv.pitch_price,
    'currency', 'GBP',
    'hold_expires_at', hold_until,
    'checkout_session_id', null,
    'checkout_url', null,
    'reused', false
  );
end;
$$;

create or replace function public.process_market_stripe_event(
  p_stripe_event_id text,
  p_event_type text,
  p_checkout_session_id text,
  p_payment_intent_id text,
  p_amount_total bigint,
  p_currency text,
  p_payment_status text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tx public.market_payment_transactions%rowtype;
  reservation public.market_reservations%rowtype;
  expected_minor bigint;
  inserted_rows integer;
  stale_attempt boolean;
begin
  insert into public.market_stripe_webhook_events(stripe_event_id,event_type)
  values (p_stripe_event_id,p_event_type)
  on conflict do nothing;

  get diagnostics inserted_rows = row_count;
  if inserted_rows = 0 then
    return jsonb_build_object('result','duplicate');
  end if;

  select * into tx
  from public.market_payment_transactions
  where stripe_checkout_session_id = p_checkout_session_id
  for update;

  if tx.id is null then
    -- Stripe can deliver a webhook immediately after Checkout creation, before
    -- the Edge Function has stored the session mapping. Do not consume the event;
    -- Stripe's retry can then process it once the mapping exists.
    delete from public.market_stripe_webhook_events
    where stripe_event_id = p_stripe_event_id;
    return jsonb_build_object('result','unknown_session');
  end if;

  select * into reservation
  from public.market_reservations
  where id = tx.reservation_id
  for update;

  if reservation.id is null then
    return jsonb_build_object('result','unknown_reservation');
  end if;

  -- A trader may retry after an expired hold. Never let an old Checkout session
  -- confirm the replacement hold. The 35-minute hold starts at
  -- hold_expires_at minus 35 minutes.
  stale_attempt := tx.created_at < (reservation.hold_expires_at - interval '35 minutes');

  if p_event_type = 'checkout.session.completed' and p_payment_status = 'paid' then
    if stale_attempt or tx.status <> 'checkout_open' then
      update public.market_payment_transactions
      set status = 'refund_required',
          stripe_payment_intent_id = p_payment_intent_id,
          updated_at = now()
      where id = tx.id;
      return jsonb_build_object('result','refund_required','payment_intent_id',p_payment_intent_id);
    end if;

    expected_minor := round(reservation.amount * 100)::bigint;
    if p_amount_total <> expected_minor or lower(p_currency) <> 'gbp' then
      update public.market_payment_transactions
      set status = 'refund_required',
          stripe_payment_intent_id = p_payment_intent_id,
          updated_at = now()
      where id = tx.id;
      if not stale_attempt then
        update public.market_reservations
        set status = 'refund_required',
            stripe_payment_intent_id = p_payment_intent_id,
            updated_at = now()
        where id = reservation.id and status = 'held';
      end if;
      return jsonb_build_object('result','refund_required','payment_intent_id',p_payment_intent_id);
    end if;

    if reservation.status = 'held' and reservation.hold_expires_at > now() then
      update public.market_reservations
      set status = 'confirmed',
          stripe_payment_intent_id = p_payment_intent_id,
          confirmed_at = now(),
          updated_at = now()
      where id = reservation.id;

      update public.market_payment_transactions
      set status = 'paid',
          stripe_payment_intent_id = p_payment_intent_id,
          paid_at = now(),
          updated_at = now()
      where id = tx.id;

      update public.market_invitations
      set status = 'accepted', updated_at = now()
      where id = reservation.invitation_id;

      return jsonb_build_object('result','confirmed');
    end if;

    update public.market_reservations
    set status = 'refund_required',
        stripe_payment_intent_id = p_payment_intent_id,
        updated_at = now()
    where id = reservation.id;
    update public.market_payment_transactions
    set status = 'refund_required',
        stripe_payment_intent_id = p_payment_intent_id,
        updated_at = now()
    where id = tx.id;
    return jsonb_build_object('result','refund_required','payment_intent_id',p_payment_intent_id);
  elsif p_event_type = 'checkout.session.expired' then
    if not stale_attempt then
      update public.market_reservations
      set status = 'expired', updated_at = now()
      where id = reservation.id and status = 'held';
    end if;
    update public.market_payment_transactions
    set status = 'expired', updated_at = now()
    where id = tx.id and status = 'checkout_open';
    return jsonb_build_object('result','expired');
  elsif p_event_type in ('checkout.session.async_payment_failed','payment_intent.payment_failed') then
    if not stale_attempt then
      update public.market_reservations
      set status = 'cancelled', updated_at = now()
      where id = reservation.id and status = 'held';
    end if;
    update public.market_payment_transactions
    set status = 'failed', updated_at = now()
    where id = tx.id and status = 'checkout_open';
    return jsonb_build_object('result','failed');
  end if;

  return jsonb_build_object('result','ignored');
end;
$$;

revoke all on function public.create_market_reservation(text) from public, anon, authenticated;
revoke all on function public.process_market_stripe_event(text,text,text,text,bigint,text,text) from public, anon, authenticated;
grant execute on function public.create_market_reservation(text) to service_role;
grant execute on function public.process_market_stripe_event(text,text,text,text,bigint,text,text) to service_role;

comment on table public.market_reservations is
  'Invitation-linked capacity holds and confirmed bookings. One trader per market date; capacity is serialized by locking the market event row.';
comment on table public.market_payment_transactions is
  'Stripe Checkout payment attempts for invitation-linked market reservations. No card details are stored.';
comment on table public.market_stripe_webhook_events is
  'Stripe webhook event IDs for idempotent payment processing.';

commit;
