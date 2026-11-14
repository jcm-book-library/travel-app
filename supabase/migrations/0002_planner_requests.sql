-- 0002_planner_requests: changes requested by the Trip Planner app
-- (travel-planner: supabase/requests/for-travel-app.md, 14 Nov 26 update).
-- Run after 0001_core.sql.

-- CR-04: trips can be drafts. The Planner builds a draft and "hands over" by
-- setting it to active; the Companion ignores drafts. Dates are already optional.
alter table trips drop constraint trips_status_check;
alter table trips add constraint trips_status_check
  check (status in ('draft', 'active', 'archived'));

-- Members can edit a trip while it is a draft or active; archived stays read-only.
create or replace function trip_is_writable(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_trip_member(t)
     and exists (select 1 from trips
                 where id = t and status in ('draft', 'active') and deleted_at is null);
$$;

-- CR-06: cities are the city level of a trip (instead of a new trip_stops table).
-- A draft stop may not have a time zone yet; the app must cope with a null tz.
alter table cities alter column tz drop not null;
alter table cities add column country_code char(2)
  check (country_code ~ '^[A-Z]{2}$');

-- CR-02: visits can be logged at country level (ISO 3166-1 alpha-2, upper case).
alter table visits add column country_code char(2)
  check (country_code ~ '^[A-Z]{2}$');
