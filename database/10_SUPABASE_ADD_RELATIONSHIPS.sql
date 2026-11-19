-- ============================================================================
-- PYROGUARD - ADD THE MISSING TABLE RELATIONSHIPS (FOREIGN KEYS)   2026-11-20
-- Run in the SUPABASE SQL Editor (not MySQL Workbench), after 00, 01 and 08.
--
-- Why: the schema diagram only draws a line for a real foreign key. Most
-- hardware/history tables stored "ESP32-001" or a user id without declaring the
-- link, so they appeared unconnected. This adds those links.
--
-- Safe:
--   * Safe to run more than once (skips links that already exist).
--   * NOT VALID first, so existing old rows never make the script fail; it then
--     tries to validate each link and only reports (does not delete) any
--     orphan rows it finds.
--   * Device links are only added where the server guarantees the value is a
--     registered controller (ESP32-001/002) or camera (pyroguard_camera_001).
--     Mixed-id logs (event_history, emergency_action_logs, audio_sessions,
--     camera_history, mirror/ledger, incident emails, sensor_readings) get only
--     their user link, so real events can never be rejected.
--   * Archive tables are left unlinked on purpose: archived rows must survive.
-- ============================================================================

CREATE OR REPLACE FUNCTION pg_temp.pyroguard_link(
    p_table text, p_column text, p_ref_schema text, p_ref_table text, p_ref_column text,
    p_on_delete text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_name text := left(p_table || '_' || p_column || '_fkey', 63);
    v_nullable boolean;
    v_action text;
BEGIN
    IF to_regclass('public.' || quote_ident(p_table)) IS NULL THEN
        RETURN p_table || '.' || p_column || ': table missing, skipped';
    END IF;
    SELECT is_nullable = 'YES' INTO v_nullable
      FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = p_table AND column_name = p_column;
    IF v_nullable IS NULL THEN
        RETURN p_table || '.' || p_column || ': column missing, skipped';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint c
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
         WHERE c.contype = 'f' AND c.conrelid = ('public.' || quote_ident(p_table))::regclass
           AND a.attname = p_column) THEN
        RETURN p_table || '.' || p_column || ': already linked';
    END IF;

    -- Nullable columns are cleared when the parent is deleted; required
    -- columns follow the parent (CASCADE) unless the caller asked otherwise.
    v_action := coalesce(p_on_delete, CASE WHEN v_nullable THEN 'SET NULL' ELSE 'CASCADE' END);

    EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I.%I(%I) ON UPDATE CASCADE ON DELETE %s NOT VALID',
        p_table, v_name, p_column, p_ref_schema, p_ref_table, p_ref_column, v_action);
    BEGIN
        EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', p_table, v_name);
        RETURN p_table || '.' || p_column || ' -> ' || p_ref_table || ': linked';
    EXCEPTION WHEN foreign_key_violation THEN
        RETURN p_table || '.' || p_column || ' -> ' || p_ref_table
               || ': linked for new rows; some OLD rows point to a missing ' || p_ref_table || ' row (kept, not deleted)';
    END;
END
$fn$;

-- auth.users(id) cannot be referenced ON UPDATE CASCADE from every client
-- setup, but ids never change, so the clause is harmless.
SELECT r AS result FROM (
  -- ── People (user accounts) ───────────────────────────────────────────────
  SELECT pg_temp.pyroguard_link('system_state',                   'user_id',      'auth', 'users', 'id') AS r UNION ALL
  SELECT pg_temp.pyroguard_link('system_state',                   'acting_user',  'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('device_commands',                'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('device_commands',                'requested_by', 'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('ptz_commands',                   'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('sensor_history',                 'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_room_sensor_readings', 'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('event_history',                  'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('camera_events',                  'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('camera_history',                 'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('audio_sessions',                 'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('emergency_action_logs',          'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('mirror_records',                 'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('dual_record_ledger',             'user_id',      'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('support_ticket_events',          'actor_id',     'auth', 'users', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_home_members',         'user_id',      'auth', 'users', 'id') UNION ALL

  -- ── Home 1 ───────────────────────────────────────────────────────────────
  SELECT pg_temp.pyroguard_link('pyroguard_home_members',         'home_id',      'public', 'homes', 'id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_shared_home',          'home_id',      'public', 'homes', 'id') UNION ALL

  -- ── Controllers ESP32-001 / ESP32-002 (devices.device_id) ────────────────
  -- live state: follows the device
  SELECT pg_temp.pyroguard_link('device_current_state',           'device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('device_heartbeats',              'device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('system_state',                   'device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('ptz_state',                      'device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_contact_current_state','device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_camera_telemetry',     'device_id',            'public', 'devices', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_camera_registry',      'controller_device_id', 'public', 'devices', 'device_id') UNION ALL
  -- history/commands: NO ACTION, so a device with history cannot be deleted by accident
  SELECT pg_temp.pyroguard_link('device_commands',                'target_device_id',     'public', 'devices', 'device_id', 'NO ACTION') UNION ALL
  SELECT pg_temp.pyroguard_link('sensor_history',                 'device_id',            'public', 'devices', 'device_id', 'NO ACTION') UNION ALL
  SELECT pg_temp.pyroguard_link('pyroguard_room_sensor_readings', 'controller_device_id', 'public', 'devices', 'device_id', 'NO ACTION') UNION ALL

  -- ── Camera 1 (pyroguard_camera_registry.device_id) ───────────────────────
  SELECT pg_temp.pyroguard_link('pyroguard_camera_telemetry',     'camera_device_id',     'public', 'pyroguard_camera_registry', 'device_id') UNION ALL
  SELECT pg_temp.pyroguard_link('camera_events',                  'device_id',            'public', 'pyroguard_camera_registry', 'device_id', 'NO ACTION') UNION ALL
  SELECT pg_temp.pyroguard_link('ptz_commands',                   'device_id',            'public', 'pyroguard_camera_registry', 'device_id', 'NO ACTION')
) links;

-- Ask the API to pick up the new relationships (used by Supabase joins).
NOTIFY pgrst, 'reload schema';
