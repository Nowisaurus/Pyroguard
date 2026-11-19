-- ============================================================================
-- PYROGUARD - MOVE THE OLD FALSE-FIRE DATA OUT OF THE APP (SUPABASE)
-- DATE: 2026-11-04 (c)            Run in Supabase SQL Editor. Back up first.
--
-- The old ESP32 sketch reported electrical noise on the flame input as
-- "flame", which filled Analytics, Events and Calendar with false fires.
-- This MOVES (does not destroy) that data into archive tables:
--   * room readings saved by the old sketch (fire_confirmed IS NULL)
--   * CRITICAL_FIRE events created before the guarded firmware started
--     (and not confirmed by it)
-- New readings from the updated sketch are never touched.
-- Undo: INSERT the rows back from the *_archive tables.
-- Run it AFTER 20261104b_false_fire_and_rooms_supabase.sql. Safe to re-run.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.pyroguard_room_sensor_readings_archive
    (LIKE public.pyroguard_room_sensor_readings INCLUDING DEFAULTS);
ALTER TABLE public.pyroguard_room_sensor_readings_archive
    ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.pyroguard_room_sensor_readings_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pyroguard_room_sensor_readings_archive FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.event_history_archive
    (LIKE public.event_history INCLUDING DEFAULTS);
ALTER TABLE public.event_history_archive
    ADD COLUMN IF NOT EXISTS archived_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.event_history_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.event_history_archive FROM anon, authenticated;

DO $move$
DECLARE
    v_cutoff timestamptz;
    v_cols text;
    v_rooms int;
    v_events int;
BEGIN
    -- Start of the guarded firmware = its first saved reading (or now).
    SELECT coalesce(min(received_at), now()) INTO v_cutoff
      FROM public.pyroguard_room_sensor_readings
     WHERE fire_confirmed IS NOT NULL;

    -- Room readings from the old sketch
    SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) INTO v_cols
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'pyroguard_room_sensor_readings';
    EXECUTE format(
        'WITH moved AS (DELETE FROM public.pyroguard_room_sensor_readings
                         WHERE fire_confirmed IS NULL RETURNING %1$s)
         INSERT INTO public.pyroguard_room_sensor_readings_archive (%1$s) SELECT %1$s FROM moved',
        v_cols);
    GET DIAGNOSTICS v_rooms = ROW_COUNT;

    -- False CRITICAL_FIRE events (created before the guarded firmware)
    SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) INTO v_cols
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'event_history';
    EXECUTE format(
        'WITH moved AS (DELETE FROM public.event_history
                         WHERE event_type = ''CRITICAL_FIRE''
                           AND created_at < $1
                           AND coalesce(payload_json ->> ''fire_confirmed'', '''') <> ''true''
                         RETURNING %1$s)
         INSERT INTO public.event_history_archive (%1$s) SELECT %1$s FROM moved',
        v_cols) USING v_cutoff;
    GET DIAGNOSTICS v_events = ROW_COUNT;

    RAISE NOTICE 'Archived % old room readings and % false fire events (cutoff %).', v_rooms, v_events, v_cutoff;
END;
$move$;

COMMIT;

-- What is left (should be only data from the updated firmware)
SELECT controller_device_id, room_key, count(*) AS readings,
       count(*) FILTER (WHERE fire_confirmed) AS confirmed_fire_readings,
       max(received_at) AS newest
  FROM public.pyroguard_room_sensor_readings
 GROUP BY controller_device_id, room_key
 ORDER BY controller_device_id, room_key;

SELECT (SELECT count(*) FROM public.pyroguard_room_sensor_readings_archive) AS archived_readings,
       (SELECT count(*) FROM public.event_history_archive) AS archived_events;
