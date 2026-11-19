-- ============================================================================
-- PYROGUARD - FALSE-FIRE GUARD + FOUR ROOMS + DOOR/WINDOW (SUPABASE)
-- DATE: 2026-11-04 (b)            Run in Supabase SQL Editor. Back up first.
--
--  1. Room keys: entrance, sala (ESP32-001) and kitchen, bedroom (ESP32-002).
--     Old rows are kept as they are (NOT VALID check).
--  2. New safety columns on pyroguard_room_sensor_readings:
--       fire_confirmed  firmware confirmed smoke AND flame in that room
--       flame_fault     flame input stuck/chattering (ignored as fire)
--       smoke_fault     smoke input stuck (ignored as fire)
--  3. The CRITICAL_FIRE incident trigger now needs fire_confirmed = true in two
--     consecutive readings of the same room. Old-firmware readings, flame + high
--     temperature or smoke + high temperature never create a "fire" record.
--  4. Door/window current state table (if missing) + live updates.
-- Safe to run more than once. No rows are deleted.
-- ============================================================================

BEGIN;

-- 1. Room keys ---------------------------------------------------------------
DO $rk$
DECLARE c record;
BEGIN
    FOR c IN
        SELECT con.conname
          FROM pg_constraint con
          JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
         WHERE con.conrelid = 'public.pyroguard_room_sensor_readings'::regclass
           AND con.contype = 'c' AND att.attname = 'room_key'
    LOOP
        EXECUTE format('ALTER TABLE public.pyroguard_room_sensor_readings DROP CONSTRAINT %I', c.conname);
    END LOOP;
END;
$rk$;
ALTER TABLE public.pyroguard_room_sensor_readings
    ADD CONSTRAINT pyroguard_room_sensor_readings_room_key_check
    CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom')) NOT VALID;

-- 2. Safety columns ----------------------------------------------------------
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS fire_confirmed boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS flame_fault boolean;
ALTER TABLE public.pyroguard_room_sensor_readings ADD COLUMN IF NOT EXISTS smoke_fault boolean;
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_idx
    ON public.pyroguard_room_sensor_readings(controller_device_id, room_key, received_at DESC);
CREATE INDEX IF NOT EXISTS pg_room_sensor_received_all_idx
    ON public.pyroguard_room_sensor_readings(received_at);

-- 3. CRITICAL_FIRE incidents only from confirmed fire ------------------------
CREATE OR REPLACE FUNCTION public.pyroguard_record_multisensor_room_alert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    previous public.pyroguard_room_sensor_readings%ROWTYPE;
    event_key text;
    label text;
BEGIN
    IF NEW.controller_device_id NOT IN ('ESP32-001', 'ESP32-002')
       OR NEW.received_at IS NULL
       OR NEW.received_at < now() - interval '30 seconds'
       OR NEW.received_at > now() + interval '10 seconds' THEN
        RETURN NEW;
    END IF;

    -- Confirmed fire in THIS sample: only the guarded firmware's fire_confirmed
    -- counts (never a faulty sensor, never temperature-only, never old firmware).
    IF NOT (coalesce(NEW.flame_fault, false) = false AND coalesce(NEW.smoke_fault, false) = false AND
            NEW.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;

    SELECT * INTO previous
      FROM public.pyroguard_room_sensor_readings p
     WHERE p.controller_device_id = NEW.controller_device_id
       AND p.room_key = NEW.room_key
       AND p.id <> NEW.id
       AND p.received_at < NEW.received_at
       AND p.received_at >= NEW.received_at - interval '30 seconds'
     ORDER BY p.received_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;
    IF NOT (coalesce(previous.flame_fault, false) = false AND coalesce(previous.smoke_fault, false) = false AND
            previous.fire_confirmed IS TRUE) THEN
        RETURN NEW;
    END IF;

    label := CASE NEW.room_key WHEN 'entrance' THEN 'Entrance' WHEN 'sala' THEN 'Sala'
                               WHEN 'kitchen' THEN 'Kitchen' WHEN 'bedroom' THEN 'Bedroom'
                               ELSE NEW.room_key END;
    -- At most one record per room per five minutes.
    event_key := NEW.controller_device_id || ':FIRE:' || NEW.room_key || ':' ||
                 floor(extract(epoch FROM NEW.received_at) / 300)::bigint::text;
    INSERT INTO public.event_history
        (user_id, device_id, event_type, record_key, message, severity, payload_json, mysql_synced, created_at)
    VALUES
        (NEW.user_id, NEW.controller_device_id, 'CRITICAL_FIRE', event_key,
         'Fire confirmed by smoke + flame sensors in ' || label || ' (two consecutive readings). Verify and call BFP if needed.',
         2,
         jsonb_build_object('room_key', NEW.room_key, 'source', 'pyroguard_room_sensor_readings',
                            'first_received_at', previous.received_at, 'last_received_at', NEW.received_at,
                            'smoke_status', NEW.smoke_status, 'flame_detected', NEW.flame_detected,
                            'fire_confirmed', NEW.fire_confirmed, 'temperature', NEW.temperature),
         false, NEW.received_at)
    ON CONFLICT (record_key) DO NOTHING;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pyroguard_multisensor_incident_on_room_insert ON public.pyroguard_room_sensor_readings;
CREATE TRIGGER pyroguard_multisensor_incident_on_room_insert
    AFTER INSERT ON public.pyroguard_room_sensor_readings
    FOR EACH ROW EXECUTE FUNCTION public.pyroguard_record_multisensor_room_alert();

-- 4. Door / window current state ---------------------------------------------
CREATE TABLE IF NOT EXISTS public.pyroguard_contact_current_state (
    device_id text NOT NULL,
    room_key text NOT NULL,
    contact_type text NOT NULL CHECK (contact_type IN ('door', 'window')),
    is_open boolean NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, contact_type),
    CONSTRAINT contact_room_key_valid CHECK (room_key IN ('entrance', 'sala', 'kitchen', 'bedroom'))
);
ALTER TABLE public.pyroguard_contact_current_state ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pyroguard_contact_authenticated_read ON public.pyroguard_contact_current_state;
CREATE POLICY pyroguard_contact_authenticated_read ON public.pyroguard_contact_current_state
    FOR SELECT TO authenticated USING (true);
REVOKE ALL ON public.pyroguard_contact_current_state FROM anon;
GRANT SELECT ON public.pyroguard_contact_current_state TO authenticated;
GRANT ALL ON public.pyroguard_contact_current_state TO service_role;

-- Live updates
DO $rt$
DECLARE t text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        FOREACH t IN ARRAY ARRAY['pyroguard_room_sensor_readings', 'pyroguard_contact_current_state',
                                 'device_current_state', 'event_history'] LOOP
            IF to_regclass(format('public.%I', t)) IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM pg_publication_tables
                 WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
                EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
            END IF;
        END LOOP;
    END IF;
END;
$rt$;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- ============================================================================
-- VERIFY
-- ============================================================================
-- Newest reading per room (fresh = last 2 minutes)
SELECT DISTINCT ON (controller_device_id, room_key)
       controller_device_id, room_key, temperature, humidity, smoke_status, flame_detected,
       fire_confirmed, flame_fault, smoke_fault, received_at,
       now() - received_at <= interval '2 minutes' AS fresh
  FROM public.pyroguard_room_sensor_readings
 WHERE room_key IN ('entrance', 'sala', 'kitchen', 'bedroom')
 ORDER BY controller_device_id, room_key, received_at DESC;

-- Door / window
SELECT device_id, contact_type, room_key, is_open, received_at,
       now() - received_at <= interval '2 minutes' AS fresh
  FROM public.pyroguard_contact_current_state ORDER BY device_id, contact_type;
