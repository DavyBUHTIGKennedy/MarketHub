-- Simple location-level pitch capacity with a per-event snapshot.
-- Existing individual pitch records are retained; this migration does not delete or rewrite them.

alter table public.market_locations
  add column if not exists default_pitch_capacity integer not null default 0;

update public.market_locations l
set default_pitch_capacity = (
  select count(*)::integer
  from public.pitches p
  where p.location_id = l.id and p.active = true
)
where l.default_pitch_capacity = 0;

alter table public.market_locations
  drop constraint if exists market_locations_default_pitch_capacity_check;
alter table public.market_locations
  add constraint market_locations_default_pitch_capacity_check
  check (default_pitch_capacity >= 0);

alter table public.market_events
  add column if not exists pitch_capacity integer;

update public.market_events e
set pitch_capacity = coalesce(
  (select l.default_pitch_capacity from public.market_locations l where l.id = e.location_id),
  0
)
where e.pitch_capacity is null;

alter table public.market_events
  alter column pitch_capacity set default 0,
  alter column pitch_capacity set not null;

alter table public.market_events
  drop constraint if exists market_events_pitch_capacity_check;
alter table public.market_events
  add constraint market_events_pitch_capacity_check
  check (pitch_capacity >= 0);
