-- MarketHub event pricing: £35 default with an immutable-per-event price snapshot.
-- Existing market dates are backfilled at £35. This migration does not change
-- bookings or payments already recorded in the legacy tables.

begin;

alter table public.market_locations
  add column if not exists default_pitch_price numeric(10,2) not null default 35.00;

alter table public.market_locations
  drop constraint if exists market_locations_default_pitch_price_check;
alter table public.market_locations
  add constraint market_locations_default_pitch_price_check
  check (default_pitch_price >= 0);

alter table public.market_events
  add column if not exists pitch_price numeric(10,2);

update public.market_events
set pitch_price = 35.00
where pitch_price is null;

alter table public.market_events
  alter column pitch_price set default 35.00,
  alter column pitch_price set not null;

alter table public.market_events
  drop constraint if exists market_events_pitch_price_check;
alter table public.market_events
  add constraint market_events_pitch_price_check
  check (pitch_price >= 0);

comment on column public.market_locations.default_pitch_price is
  'Owner-managed default price per pitch in GBP for future market dates.';
comment on column public.market_events.pitch_price is
  'Price per pitch in GBP snapshotted when this market date is created; later default-price changes do not alter this event price.';

commit;
