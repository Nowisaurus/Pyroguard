-- PyroGuard v17 (2026-11-23): defense panel recommendations
--  * Home layout to scale (rooms in meters, exits, evacuation area) for the fire
--    location + evacuation guide, house size and sensors per room.
--  * Evacuation area near the home (map pin).
--  * Testing records (cold / humidity / smoke & flame distance / response time).
--  * Hardware + labor cost estimate.
-- Safe to run more than once.

-- 1) Layout items, positions and sizes in meters (x to the right, y down).
create table if not exists public.pyroguard_home_layout (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  item_key   text not null,
  kind       text not null check (kind in ('room','exit')),
  label      text not null check (char_length(label) <= 60),
  x_m        numeric(6,2) not null default 0 check (x_m between 0 and 200),
  y_m        numeric(6,2) not null default 0 check (y_m between 0 and 200),
  w_m        numeric(6,2) not null default 3 check (w_m between 0 and 200),
  h_m        numeric(6,2) not null default 3 check (h_m between 0 and 200),
  controller_id text,                     -- room sensors (ESP32-001 / ESP32-002)
  room_key   text,                        -- entrance / sala / kitchen / bedroom
  notes      text check (notes is null or char_length(notes) <= 300),
  updated_at timestamptz not null default now(),
  unique (user_id, item_key)
);
alter table public.pyroguard_home_layout enable row level security;
drop policy if exists home_layout_own on public.pyroguard_home_layout;
create policy home_layout_own on public.pyroguard_home_layout
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.pyroguard_home_layout to authenticated;

-- 2) Evacuation area near the home.
alter table public.homes
  add column if not exists evac_name text check (evac_name is null or char_length(evac_name) <= 120),
  add column if not exists evac_latitude  double precision check (evac_latitude is null or evac_latitude between -90 and 90),
  add column if not exists evac_longitude double precision check (evac_longitude is null or evac_longitude between -180 and 180);

-- 3) Testing records.
create table if not exists public.pyroguard_test_records (
  id             bigint generated always as identity primary key,
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  test_type      text not null check (test_type in ('COLD','HEAT','HUMIDITY','SMOKE_DISTANCE','FLAME_DISTANCE','RESPONSE_TIME','DOOR_WINDOW','OTHER')),
  tested_on      date not null default current_date,
  controller_id  text,
  room_key       text,
  distance_cm    numeric(7,1),
  temperature_c  numeric(5,1),
  humidity_pct   numeric(5,1),
  response_s     numeric(7,2),
  result         text not null default 'PASS' check (result in ('PASS','FAIL','PARTIAL')),
  notes          text check (notes is null or char_length(notes) <= 500),
  created_at     timestamptz not null default now()
);
create index if not exists pyroguard_test_records_user_idx on public.pyroguard_test_records (user_id, tested_on desc);
alter table public.pyroguard_test_records enable row level security;
drop policy if exists test_records_own on public.pyroguard_test_records;
create policy test_records_own on public.pyroguard_test_records
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.pyroguard_test_records to authenticated;

-- 4) Hardware + labor cost items.
create table if not exists public.pyroguard_cost_items (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  category    text not null default 'Hardware' check (category in ('Hardware','Labor','Other')),
  item        text not null check (char_length(item) <= 120),
  quantity    numeric(8,2) not null default 1 check (quantity >= 0),
  unit        text not null default 'pc' check (char_length(unit) <= 20),
  unit_price  numeric(10,2) not null default 0 check (unit_price >= 0),
  sort_order  integer not null default 0,
  updated_at  timestamptz not null default now()
);
create index if not exists pyroguard_cost_items_user_idx on public.pyroguard_cost_items (user_id, sort_order);
alter table public.pyroguard_cost_items enable row level security;
drop policy if exists cost_items_own on public.pyroguard_cost_items;
create policy cost_items_own on public.pyroguard_cost_items
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.pyroguard_cost_items to authenticated;
