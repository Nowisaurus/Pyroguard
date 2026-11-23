-- PyroGuard panel suggestions (2026-11-21 defense):
--  1) Incident history map: past fires in the AREA (BFP / news / residents),
--     shown as a timeline + fire-prone zones around the home.
--  2) Sensor maintenance: install date per sensor -> replacement reminders.
-- Run in: SUPABASE SQL editor (safe to run more than once).

create table if not exists public.pyroguard_area_incidents (
  id            bigint generated always as identity primary key,
  reported_by   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  latitude      double precision not null check (latitude between -90 and 90),
  longitude     double precision not null check (longitude between -180 and 180),
  occurred_on   date not null default current_date,
  incident_type text not null default 'FIRE'
                check (incident_type in ('FIRE','SMOKE','GAS_LEAK','ELECTRICAL','OTHER')),
  description   text not null default '' check (char_length(description) <= 300),
  source        text not null default 'Resident'
                check (source in ('PyroGuard','BFP','News','Resident','Barangay')),
  created_at    timestamptz not null default now()
);
create index if not exists pyroguard_area_incidents_loc_idx
  on public.pyroguard_area_incidents (latitude, longitude);
create index if not exists pyroguard_area_incidents_date_idx
  on public.pyroguard_area_incidents (occurred_on desc);

alter table public.pyroguard_area_incidents enable row level security;
drop policy if exists area_incidents_read on public.pyroguard_area_incidents;
create policy area_incidents_read on public.pyroguard_area_incidents
  for select to authenticated using (true);           -- shared community history
drop policy if exists area_incidents_insert on public.pyroguard_area_incidents;
create policy area_incidents_insert on public.pyroguard_area_incidents
  for insert to authenticated with check (reported_by = auth.uid());
drop policy if exists area_incidents_delete on public.pyroguard_area_incidents;
create policy area_incidents_delete on public.pyroguard_area_incidents
  for delete to authenticated using (reported_by = auth.uid());

create table if not exists public.pyroguard_sensor_maintenance (
  id            bigint generated always as identity primary key,
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  device_id     text not null,
  room_key      text not null,
  sensor_kind   text not null check (sensor_kind in ('DHT22','MQ2','FLAME','REED','BUZZER','SERVO','CAMERA')),
  installed_on  date not null default current_date,
  last_checked_on date,
  notes         text not null default '' check (char_length(notes) <= 300),
  updated_at    timestamptz not null default now(),
  unique (user_id, device_id, room_key, sensor_kind)
);
alter table public.pyroguard_sensor_maintenance enable row level security;
drop policy if exists sensor_maintenance_own on public.pyroguard_sensor_maintenance;
create policy sensor_maintenance_own on public.pyroguard_sensor_maintenance
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, delete on public.pyroguard_area_incidents to authenticated;
grant select, insert, update, delete on public.pyroguard_sensor_maintenance to authenticated;
notify pgrst, 'reload schema';
