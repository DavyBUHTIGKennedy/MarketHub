-- MarketHub migration 003: grant authenticated users table privileges
-- Row-level security policies remain responsible for deciding which rows
-- each organisation member can read or change.
grant select, insert, update, delete
  on table public.market_locations, public.pitches, public.market_events
  to authenticated;
