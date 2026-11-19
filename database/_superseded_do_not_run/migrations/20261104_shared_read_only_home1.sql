-- PYROGUARD: Shared authenticated visibility, without account enrollment.
-- Run in Supabase SQL Editor after backing up / verifying these table names.
-- This intentionally does NOT create or restore memberships, change owners,
-- change admin privileges, grant write access, or delete historical records.
-- Privacy trade-off: ANY signed-in account can read telemetry/status from the
-- chosen tables. Do not use this policy for an unrelated multi-household app.
BEGIN;

-- The current firmware transmits physical room keys, not legacy display aliases.
ALTER TABLE public.pyroguard_room_sensor_readings
  DROP CONSTRAINT IF EXISTS pyroguard_room_sensor_readings_room_key_check;
ALTER TABLE public.pyroguard_room_sensor_readings
  ADD CONSTRAINT pyroguard_room_sensor_readings_room_key_check
  CHECK (room_key IN ('entrance','sala','kitchen','bedroom')) NOT VALID;
-- NOT VALID preserves historical rows with legacy room labels.
-- New writes are checked immediately; historical data is not modified.

-- No memberships/approval step needed for READ access to monitoring data.
ALTER TABLE public.pyroguard_room_sensor_readings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pyroguard_shared_authenticated_read ON public.pyroguard_room_sensor_readings;
CREATE POLICY pyroguard_shared_authenticated_read
 ON public.pyroguard_room_sensor_readings FOR SELECT TO authenticated
 USING ((SELECT auth.uid()) IS NOT NULL);
GRANT SELECT ON public.pyroguard_room_sensor_readings TO authenticated;

-- Shared operational status, NOT profiles, credentials, or admin records.
-- Guard optional tables to be safe on different schema versions.
DO $do$
DECLARE tbl text;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'device_current_state', 'device_heartbeats',
    'pyroguard_camera_telemetry', 'system_state', 'sensor_history'
  ] LOOP
    IF to_regclass('public.' || tbl) IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
      EXECUTE format('DROP POLICY IF EXISTS pyroguard_shared_authenticated_read ON public.%I', tbl);
      EXECUTE format('CREATE POLICY pyroguard_shared_authenticated_read ON public.%I FOR SELECT TO authenticated USING ((SELECT auth.uid()) IS NOT NULL)', tbl);
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated', tbl);
    END IF;
  END LOOP;
END $do$;
COMMIT;

-- IMPORTANT: read visibility is NOT control authority. Leave INSERT/UPDATE
-- RLS on device_commands/system_state and all admin role policies unchanged.
-- The app must await hardware ACK before reflecting ARM/DISARM as applied.
