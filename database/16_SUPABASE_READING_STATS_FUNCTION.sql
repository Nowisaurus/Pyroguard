-- PyroGuard v17 (2026-11-23): recorded temperature / humidity / smoke ranges per room
-- (Monitoring > Testing Data). Runs with the caller's permissions (RLS applies).
create or replace function public.pyroguard_reading_stats(days integer default 0)
returns table (
  controller_device_id text, room_key text, readings bigint,
  first_at timestamptz, last_at timestamptz,
  temp_min numeric, temp_max numeric, temp_avg numeric,
  hum_min numeric, hum_max numeric, hum_avg numeric,
  smoke_max numeric, smoke_alarms bigint, flame_events bigint, fires bigint
)
language sql stable security invoker set search_path = public as $$
  select r.controller_device_id, r.room_key, count(*),
         min(r.received_at), max(r.received_at),
         round(min(r.temperature)::numeric,1), round(max(r.temperature)::numeric,1), round(avg(r.temperature)::numeric,1),
         round(min(r.humidity)::numeric,1), round(max(r.humidity)::numeric,1), round(avg(r.humidity)::numeric,1),
         round(max(r.smoke_raw)::numeric,0),
         count(*) filter (where r.smoke_status = 'ALARM'),
         count(*) filter (where r.flame_detected),
         count(*) filter (where r.fire_confirmed)
  from public.pyroguard_room_sensor_readings r
  where days <= 0 or r.received_at >= now() - make_interval(days => days)
  group by r.controller_device_id, r.room_key
  order by r.controller_device_id, r.room_key;
$$;
grant execute on function public.pyroguard_reading_stats(integer) to authenticated;
