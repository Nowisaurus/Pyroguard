-- PyroGuard (2026-11-24): dashboard analytics timed out (code 57014).
-- Same access rules, but the per-user checks run once per query instead of
-- once per row. Run in Supabase -> SQL Editor. Safe to run more than once.
drop policy if exists pg_room_sensor_read on public.pyroguard_room_sensor_readings;
create policy pg_room_sensor_read on public.pyroguard_room_sensor_readings for select to authenticated
  using (user_id = (select auth.uid()) or (select public.pg_ticket_admin()));
drop policy if exists pyroguard_shared_home_read on public.pyroguard_room_sensor_readings;
create policy pyroguard_shared_home_read on public.pyroguard_room_sensor_readings for select to authenticated
  using ((select public.pyroguard_can_view_hardware())
         and (controller_device_id in ('ESP32-001','ESP32-002')
              or public.pyroguard_is_shared_device(controller_device_id)));
create index if not exists pg_room_sensor_fireconf_idx
  on public.pyroguard_room_sensor_readings (received_at desc) where fire_confirmed is not null;
