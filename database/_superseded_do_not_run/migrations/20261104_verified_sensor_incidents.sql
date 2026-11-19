-- OPTIONAL: Run in Supabase SQL Editor after backing up production.
-- Adds incidents only from authenticated firmware-ingested room rows.
-- The source of trust is the existing sensor-ingest Edge Function.
-- This is a *multi-sensor alert* not a determination that a real fire exists.
-- Check the event_history columns/constraints before applying.
CREATE OR REPLACE FUNCTION public.pyroguard_record_multisensor_room_alert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  previous public.pyroguard_room_sensor_readings%ROWTYPE;
  smoke_alarm boolean;
  prior_smoke_alarm boolean;
  qualifies boolean;
  prior_qualifies boolean;
  event_key text;
BEGIN
  IF NEW.controller_device_id NOT IN ('ESP32-001', 'ESP32-002') OR
     NEW.room_key NOT IN ('entrance','sala','kitchen','bedroom') OR
     NEW.received_at IS NULL OR
     NEW.received_at < now() - interval '30 seconds' OR
     NEW.received_at > now() + interval '10 seconds' THEN
    RETURN NEW;
  END IF;
  SELECT * INTO previous FROM public.pyroguard_room_sensor_readings p
   WHERE p.controller_device_id = NEW.controller_device_id
     AND p.room_key = NEW.room_key
     AND p.received_at < NEW.received_at
     AND p.received_at >= NEW.received_at - interval '30 seconds'
   ORDER BY p.received_at DESC LIMIT 1;
  IF NOT FOUND OR previous.received_at IS NULL THEN RETURN NEW; END IF;
  smoke_alarm := upper(coalesce(NEW.smoke_status,'')) IN ('ALARM','SMOKE_ALARM','DANGER','CRITICAL','FIRE');
  prior_smoke_alarm := upper(coalesce(previous.smoke_status,'')) IN ('ALARM','SMOKE_ALARM','DANGER','CRITICAL','FIRE');
  qualifies := ((NEW.flame_detected IS TRUE AND smoke_alarm)
      OR (NEW.flame_detected IS TRUE AND NEW.temperature >= 50)
      OR (smoke_alarm AND NEW.temperature >= 50));
  prior_qualifies := ((previous.flame_detected IS TRUE AND prior_smoke_alarm)
      OR (previous.flame_detected IS TRUE AND previous.temperature >= 50)
      OR (prior_smoke_alarm AND previous.temperature >= 50));
  IF NOT qualifies OR NOT prior_qualifies THEN RETURN NEW; END IF;
  -- At most one warning per device/room per five minutes: auditable, no floods.
  event_key := NEW.controller_device_id || ':MULTISENSOR:' || NEW.room_key || ':' ||
      floor(extract(epoch FROM NEW.received_at)/300)::bigint::text;
  INSERT INTO public.event_history
      (user_id, device_id, event_type, record_key, message, severity, payload_json, mysql_synced, created_at)
  VALUES
      (NEW.user_id, NEW.controller_device_id, 'CRITICAL_FIRE', event_key,
       'Multi-sensor fire warning, ' || NEW.room_key || '. Verify physically; recorded from live hardware.',
       2, jsonb_build_object('room_key',NEW.room_key,'source','pyroguard_room_sensor_readings',
             'first_received_at',previous.received_at,'last_received_at',NEW.received_at,
             'smoke_status',NEW.smoke_status,'flame_detected',NEW.flame_detected,
             'temperature',NEW.temperature,'confirmation','two_recent_same_room_samples'),
       false, NEW.received_at)
  ON CONFLICT (record_key) DO NOTHING;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS pyroguard_multisensor_incident_on_room_insert
  ON public.pyroguard_room_sensor_readings;
CREATE TRIGGER pyroguard_multisensor_incident_on_room_insert
AFTER INSERT ON public.pyroguard_room_sensor_readings
FOR EACH ROW EXECUTE FUNCTION public.pyroguard_record_multisensor_room_alert();
