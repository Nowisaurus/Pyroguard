-- Four independent room sensor groups: 2 per controller.
-- Execute only in Supabase SQL Editor. Back up before applying.
CREATE TABLE IF NOT EXISTS public.pyroguard_room_sensor_readings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  controller_device_id text NOT NULL,
  room_key text NOT NULL CHECK (room_key IN ('sala','bedroom')),
  temperature numeric,
  humidity numeric,
  smoke_raw numeric,
  smoke_status text,
  flame_detected boolean,
  buzzer_active boolean,
  sampled_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pg_room_controller_check CHECK (controller_device_id IN ('ESP32-001','ESP32-002'))
);
CREATE INDEX IF NOT EXISTS pg_room_sensor_latest_idx
 ON public.pyroguard_room_sensor_readings(controller_device_id,room_key,sampled_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_owner_idx
 ON public.pyroguard_room_sensor_readings(user_id, sampled_at DESC);
ALTER TABLE public.pyroguard_room_sensor_readings ENABLE ROW LEVEL SECURITY;
-- Homeowners see only their own records; active admins can inspect telemetry.
DROP POLICY IF EXISTS pg_room_sensor_read ON public.pyroguard_room_sensor_readings;
CREATE POLICY pg_room_sensor_read ON public.pyroguard_room_sensor_readings
 FOR SELECT TO authenticated USING (
   user_id = (select auth.uid()) OR EXISTS (
     SELECT 1 FROM public.admin_accounts a
     WHERE a.user_id = (select auth.uid()) AND a.active = true
   )
 );
-- ESP32 devices must ingest through an authenticated server/Edge Function,
-- not by shipping privileged Supabase credentials inside firmware.
GRANT SELECT ON public.pyroguard_room_sensor_readings TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.pyroguard_room_sensor_readings TO service_role;
