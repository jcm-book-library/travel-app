-- 0001_core: shared trip tables, row-level security, audit triggers.
-- Owned by travel-app; the planner app only requests changes to shared tables.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- helpers

create function set_audit() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;

-- ----------------------------------------------------------------- trips

create table trips (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  start_date  date,
  end_date    date,
  home_tz     text not null default 'Australia/Melbourne',
  status      text not null default 'active' check (status in ('active', 'archived')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz
);

create table trip_members (
  id            uuid primary key default gen_random_uuid(),
  trip_id       uuid not null references trips(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  display_name  text not null,
  colour        text not null default '#8a8a8a',
  role          text not null default 'editor' check (role in ('owner', 'editor')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references auth.users(id),
  deleted_at    timestamptz,
  unique (trip_id, user_id)
);

-- Membership checks. security definer so policies on trip_members can use them
-- without recursing into their own RLS.
create function is_trip_member(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from trip_members
    where trip_id = t and user_id = auth.uid() and deleted_at is null
  );
$$;

create function is_trip_owner(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from trip_members
    where trip_id = t and user_id = auth.uid() and role = 'owner' and deleted_at is null
  );
$$;

-- Members may write only while the trip is active (archived = read-only log).
create function trip_is_writable(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_trip_member(t)
     and exists (select 1 from trips where id = t and status = 'active' and deleted_at is null);
$$;

-- The creator of a trip becomes its owner.
create function add_trip_creator() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into trip_members (trip_id, user_id, display_name, role, updated_by)
  values (new.id, auth.uid(), 'Me', 'owner', auth.uid());
  return new;
end $$;

create trigger trips_add_creator after insert on trips
  for each row when (auth.uid() is not null) execute function add_trip_creator();

-- ---------------------------------------------------------- trip content

create table regions (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references trips(id) on delete cascade,
  name        text not null,
  sort        int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz
);

create table cities (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references trips(id) on delete cascade,
  region_id   uuid references regions(id),
  name        text not null,
  tz          text not null,                      -- IANA, e.g. Europe/Prague
  lat         double precision,
  lng         double precision,
  sort        int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz
);

create table days (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references trips(id) on delete cascade,
  date        date not null,
  city_id     uuid references cities(id),         -- where we sleep that night
  title       text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz
);
create unique index days_trip_date on days (trip_id, date) where deleted_at is null;

-- A place belongs to a user (personal, used by the planner) or to a trip.
create table places (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid references trips(id) on delete cascade,
  owner_id    uuid references auth.users(id) on delete cascade,
  city_id     uuid references cities(id),
  name        text not null,
  kind        text not null default 'other'
              check (kind in ('hotel', 'meeting', 'sight', 'restaurant', 'airport', 'other')),
  lat         double precision,
  lng         double precision,
  address     text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz,
  check ((trip_id is not null) <> (owner_id is not null))
);

-- One timeline for everything.
create table items (
  id              uuid primary key default gen_random_uuid(),
  trip_id         uuid not null references trips(id) on delete cascade,
  day_id          uuid references days(id),
  kind            text not null
                  check (kind in ('flight', 'tour', 'stay', 'day_tour', 'activity', 'transfer', 'meeting')),
  title           text not null,
  provider        text,
  booking_ref     text,
  notes           text,
  status          text not null default 'planned'
                  check (status in ('planned', 'confirmed', 'done', 'cancelled')),
  sort            int not null default 0,
  -- start
  local_date      date not null,
  start_time      time,
  tz              text not null,
  time_precision  text not null default 'none'
                  check (time_precision in ('exact', 'approx', 'part_of_day', 'none')),
  part_of_day     text check (part_of_day in ('morning', 'afternoon', 'evening')),
  -- end (flights, transfers, multi-day stays)
  end_date        date,
  end_time        time,
  end_tz          text,
  -- where
  city_id         uuid references cities(id),
  place_id        uuid references places(id),
  to_place_id     uuid references places(id),
  is_pinned       boolean not null default false,  -- pinned meeting points
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      uuid references auth.users(id),
  deleted_at      timestamptz,
  check (time_precision not in ('exact', 'approx') or start_time is not null),
  check (time_precision <> 'part_of_day' or part_of_day is not null)
);

-- "Where we've been": the place is optional, so unplanned stops can be logged.
create table visits (
  id          uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references trips(id) on delete cascade,
  day_id      uuid references days(id),
  item_id     uuid references items(id),
  place_id    uuid references places(id),
  name        text,
  lat         double precision,
  lng         double precision,
  visited_at  timestamptz,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id),
  deleted_at  timestamptz,
  check (place_id is not null or name is not null)
);

-- Reserved for the planner app. No screens in this app.
create table ideas (
  id               uuid primary key default gen_random_uuid(),
  owner_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  shared_trip_id   uuid references trips(id) on delete set null,
  title            text not null,
  kind             text,
  notes            text,
  url              text,
  tags             text[] not null default '{}',
  lat              double precision,
  lng              double precision,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  updated_by       uuid references auth.users(id),
  deleted_at       timestamptz
);

-- ------------------------------------------------------ audit + indexes

do $$
declare t text;
begin
  foreach t in array array[
    'trips', 'trip_members', 'regions', 'cities', 'days',
    'places', 'items', 'visits', 'ideas'
  ] loop
    execute format('create trigger %I before insert or update on %I
                    for each row execute function set_audit()', t || '_audit', t);
    execute format('create index %I on %I (updated_at)', t || '_updated_idx', t);
  end loop;
end $$;

create index items_trip_date on items (trip_id, local_date);
create index visits_trip_day on visits (trip_id, day_id);

-- ------------------------------------------------------------------ RLS
-- No DELETE policies anywhere: rows are soft-deleted by setting deleted_at.

alter table trips         enable row level security;
alter table trip_members  enable row level security;
alter table regions       enable row level security;
alter table cities        enable row level security;
alter table days          enable row level security;
alter table places        enable row level security;
alter table items         enable row level security;
alter table visits        enable row level security;
alter table ideas         enable row level security;

-- trips
create policy trips_select on trips for select using (is_trip_member(id));
create policy trips_insert on trips for insert with check (auth.uid() is not null);
create policy trips_update on trips for update
  using (is_trip_owner(id)) with check (is_trip_owner(id));

-- trip_members: members see each other; owners manage the list (active trips only)
create policy members_select on trip_members for select using (is_trip_member(trip_id));
create policy members_insert on trip_members for insert with check (is_trip_owner(trip_id));
create policy members_update on trip_members for update
  using (is_trip_owner(trip_id) or user_id = auth.uid())
  with check (is_trip_owner(trip_id) or user_id = auth.uid());

-- trip content: members read always, write only while the trip is active
do $$
declare t text;
begin
  foreach t in array array['regions', 'cities', 'days', 'items', 'visits'] loop
    execute format('create policy %I on %I for select using (is_trip_member(trip_id))',
                   t || '_select', t);
    execute format('create policy %I on %I for insert with check (trip_is_writable(trip_id))',
                   t || '_insert', t);
    execute format('create policy %I on %I for update
                    using (trip_is_writable(trip_id)) with check (trip_is_writable(trip_id))',
                   t || '_update', t);
  end loop;
end $$;

-- places: personal (owner_id) or trip (trip_id)
create policy places_select on places for select
  using (owner_id = auth.uid() or (trip_id is not null and is_trip_member(trip_id)));
create policy places_insert on places for insert
  with check (owner_id = auth.uid() or (trip_id is not null and trip_is_writable(trip_id)));
create policy places_update on places for update
  using (owner_id = auth.uid() or (trip_id is not null and trip_is_writable(trip_id)))
  with check (owner_id = auth.uid() or (trip_id is not null and trip_is_writable(trip_id)));

-- ideas: private to the owner unless shared to a trip
create policy ideas_select on ideas for select
  using (owner_id = auth.uid()
         or (shared_trip_id is not null and is_trip_member(shared_trip_id)));
create policy ideas_insert on ideas for insert with check (owner_id = auth.uid());
create policy ideas_update on ideas for update
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
