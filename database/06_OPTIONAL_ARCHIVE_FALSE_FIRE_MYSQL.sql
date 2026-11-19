-- ============================================================================
-- PYROGUARD - OPTIONAL: SAME FALSE-FIRE ARCHIVE MOVE IN MYSQL
-- Run ONLY after 05_OPTIONAL_ARCHIVE_FALSE_FIRE_SUPABASE.sql succeeded.
-- Why: the worker copies history tables append-only, so rows moved out of
-- Supabase would otherwise stay in MySQL forever.
-- Uses the same rule and the same cutoff as the Supabase script.
-- ============================================================================
USE pyroguard_db;
SET @cutoff := (SELECT MIN(received_at) FROM pyroguard_room_sensor_readings WHERE fire_confirmed IS NOT NULL);
SELECT @cutoff AS cutoff_used;   -- must NOT be NULL; if NULL, stop and run the worker first

START TRANSACTION;

INSERT IGNORE INTO pyroguard_room_sensor_readings_archive
       (id, user_id, controller_device_id, room_key, temperature, humidity, smoke_raw, smoke_status,
        flame_detected, buzzer_active, fire_confirmed, flame_fault, smoke_fault, sampled_at, received_at, archived_at)
SELECT  id, user_id, controller_device_id, room_key, temperature, humidity, smoke_raw, smoke_status,
        flame_detected, buzzer_active, fire_confirmed, flame_fault, smoke_fault, sampled_at, received_at, UTC_TIMESTAMP(6)
  FROM pyroguard_room_sensor_readings
 WHERE fire_confirmed IS NULL AND @cutoff IS NOT NULL;
DELETE FROM pyroguard_room_sensor_readings WHERE fire_confirmed IS NULL AND @cutoff IS NOT NULL;

INSERT IGNORE INTO pyroguard_event_history_archive
SELECT e.*, UTC_TIMESTAMP(6) FROM pyroguard_event_history e
 WHERE e.event_type = 'CRITICAL_FIRE' AND @cutoff IS NOT NULL AND e.created_at < @cutoff
   AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(e.payload_json, '$.fire_confirmed')), '') <> 'true';
DELETE FROM pyroguard_event_history
 WHERE event_type = 'CRITICAL_FIRE' AND @cutoff IS NOT NULL AND created_at < @cutoff
   AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.fire_confirmed')), '') <> 'true';

COMMIT;

SELECT (SELECT COUNT(*) FROM pyroguard_room_sensor_readings_archive) AS archived_readings,
       (SELECT COUNT(*) FROM pyroguard_event_history_archive) AS archived_events;
