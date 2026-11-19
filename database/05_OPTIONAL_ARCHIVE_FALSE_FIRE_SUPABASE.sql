-- ============================================================================
-- PYROGUARD - OPTIONAL: MOVE OLD FALSE-FIRE DATA OUT OF THE APP (SUPABASE)
-- Run ONLY if Analytics/Events/Calendar are still full of noise "fires" from the
-- old sketch. Run AFTER 01_SUPABASE_FINAL_SYNC_FIX.sql and AFTER the new
-- firmware has sent at least one reading (otherwise the cutoff is "now" and
-- EVERY older CRITICAL_FIRE event is archived).
-- Rows are MOVED into *_archive tables, never destroyed.
-- Then run 06_OPTIONAL_ARCHIVE_FALSE_FIRE_MYSQL.sql so MySQL matches.
-- Undo: INSERT the rows back from the *_archive tables.
-- ============================================================================
BEGIN;

DO $move$
DECLARE v_cutoff timestamptz; v_has_new boolean; v_cols text; v_rooms int; v_events int;
BEGIN
    SELECT min(received_at), count(*) > 0 INTO v_cutoff, v_has_new
      FROM public.pyroguard_room_sensor_readings WHERE fire_confirmed IS NOT NULL;
    IF NOT v_has_new THEN
        RAISE EXCEPTION 'No reading from the new firmware yet (fire_confirmed is NULL everywhere). '
                        'Flash the new sketch, wait one minute, then run this again.';
    END IF;

    -- Columns shared by source and archive (archive has the extra archived_at)
    SELECT string_agg(quote_ident(c.column_name), ',' ORDER BY c.ordinal_position) INTO v_cols
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'pyroguard_room_sensor_readings'
       AND EXISTS (SELECT 1 FROM information_schema.columns a WHERE a.table_schema = 'public'
                     AND a.table_name = 'pyroguard_room_sensor_readings_archive' AND a.column_name = c.column_name);
    EXECUTE format(
        'WITH moved AS (DELETE FROM public.pyroguard_room_sensor_readings
                         WHERE fire_confirmed IS NULL RETURNING %1$s)
         INSERT INTO public.pyroguard_room_sensor_readings_archive (%1$s) SELECT %1$s FROM moved', v_cols);
    GET DIAGNOSTICS v_rooms = ROW_COUNT;

    SELECT string_agg(quote_ident(c.column_name), ',' ORDER BY c.ordinal_position) INTO v_cols
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = 'event_history'
       AND EXISTS (SELECT 1 FROM information_schema.columns a WHERE a.table_schema = 'public'
                     AND a.table_name = 'event_history_archive' AND a.column_name = c.column_name);
    EXECUTE format(
        'WITH moved AS (DELETE FROM public.event_history
                         WHERE event_type = ''CRITICAL_FIRE'' AND created_at < $1
                           AND coalesce(payload_json ->> ''fire_confirmed'', '''') <> ''true''
                         RETURNING %1$s)
         INSERT INTO public.event_history_archive (%1$s) SELECT %1$s FROM moved', v_cols) USING v_cutoff;
    GET DIAGNOSTICS v_events = ROW_COUNT;

    RAISE NOTICE 'Archived % old room readings and % false fire events (cutoff %).', v_rooms, v_events, v_cutoff;
END;
$move$;

COMMIT;

SELECT (SELECT count(*) FROM public.pyroguard_room_sensor_readings_archive) AS archived_readings,
       (SELECT count(*) FROM public.event_history_archive) AS archived_events,
       (SELECT min(received_at) FROM public.pyroguard_room_sensor_readings WHERE fire_confirmed IS NOT NULL) AS cutoff_used;
