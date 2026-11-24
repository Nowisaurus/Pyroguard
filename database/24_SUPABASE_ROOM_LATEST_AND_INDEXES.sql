-- 2026-11-24 (APPLIED): database overload fix.
-- 1) Index matching the app's "latest reading per room" order (DESC NULLS LAST).
create index if not exists pg_room_sensor_latest_idx on public.pyroguard_room_sensor_readings (controller_device_id, room_key, received_at desc nulls last);
create index if not exists pg_room_sensor_received_nl_idx on public.pyroguard_room_sensor_readings (received_at desc nulls last);
create index if not exists event_history_type_time_idx on public.event_history (event_type, created_at desc);
create index if not exists event_history_time_idx on public.event_history (created_at desc);

-- 2) 4-row table with the latest + previous reading of every room, kept by a trigger.
create table if not exists public.pyroguard_room_sensor_latest (
  controller_device_id text not null,
  room_key text not null,
  user_id uuid,
  latest jsonb not null,
  previous jsonb,
  received_at timestamptz,
  primary key (controller_device_id, room_key)
);
alter table public.pyroguard_room_sensor_latest enable row level security;
drop policy if exists pg_room_latest_read on public.pyroguard_room_sensor_latest;
create policy pg_room_latest_read on public.pyroguard_room_sensor_latest for select to authenticated
  using (user_id = (select auth.uid()) or (select public.pg_ticket_admin()) or (select public.pyroguard_can_view_hardware()));
grant select on public.pyroguard_room_sensor_latest to authenticated;

create or replace function public.pyroguard_room_latest_upsert()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.pyroguard_room_sensor_latest as l
    (controller_device_id, room_key, user_id, latest, previous, received_at)
  values (new.controller_device_id, new.room_key, new.user_id, to_jsonb(new), null, new.received_at)
  on conflict (controller_device_id, room_key) do update
    set previous = l.latest, latest = excluded.latest, user_id = excluded.user_id, received_at = excluded.received_at
    where excluded.received_at >= coalesce(l.received_at, '-infinity'::timestamptz);
  return null;
end $$;
drop trigger if exists pyroguard_room_latest_trg on public.pyroguard_room_sensor_readings;
create trigger pyroguard_room_latest_trg after insert on public.pyroguard_room_sensor_readings
  for each row execute function public.pyroguard_room_latest_upsert();
