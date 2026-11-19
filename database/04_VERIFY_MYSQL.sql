-- ============================================================================
-- PYROGUARD - MYSQL VERIFY (read-only, MySQL Workbench)        2026-11-19
-- Run after 02_MYSQL_FINAL_SYNC_FIX.sql and one worker cycle (npm run once).
-- Every number here should match 03_VERIFY_SUPABASE.sql within one sync cycle.
-- ============================================================================
USE pyroguard_db;

-- 1. Worker archive per table (rows copied + verified)
SELECT source_table, COUNT(*) AS archived_rows, SUM(is_deleted) AS tombstones, MAX(synced_at) AS last_copy
  FROM pyroguard_local_source_records GROUP BY source_table ORDER BY source_table;

-- 2. Four rooms: newest mirrored reading each
SELECT e.controller_device_id, e.label, r.temperature, r.humidity, r.smoke_status,
       r.flame_detected, r.fire_confirmed, r.received_at
FROM (SELECT 'ESP32-001' AS controller_device_id, 'entrance' AS room_key, 'Entrance' AS label
      UNION ALL SELECT 'ESP32-001','sala','Sala'
      UNION ALL SELECT 'ESP32-002','kitchen','Kitchen'
      UNION ALL SELECT 'ESP32-002','bedroom','Bedroom') e
LEFT JOIN pyroguard_room_sensor_readings r
       ON r.id = (SELECT x.id FROM pyroguard_room_sensor_readings x
                   WHERE x.controller_device_id = e.controller_device_id AND x.room_key = e.room_key
                   ORDER BY x.received_at DESC LIMIT 1)
ORDER BY e.controller_device_id, e.room_key;

-- 3. Controllers, heartbeats, door/window
SELECT device_id, alert_status, incident_type, door_status, window_status, updated_at
  FROM pyroguard_device_current_state ORDER BY device_id;
SELECT device_id, wifi_ok, camera_ok, ptz_ok, mq2_ok, dht22_ok, local_ip, updated_at
  FROM pyroguard_device_heartbeats ORDER BY device_id;
SELECT device_id, contact_type, room_key, is_open, received_at
  FROM pyroguard_contact_current_state ORDER BY device_id, contact_type;

-- 4. Camera telemetry, PTZ and photos
SELECT camera_device_id, device_id AS controller, camera_ip, status, motion_detected, pan_angle, tilt_angle, updated_at
  FROM pyroguard_pyroguard_camera_telemetry ORDER BY camera_device_id;
SELECT device_id, pan_position, tilt_position, moving, updated_at
  FROM pyroguard_ptz_state ORDER BY device_id;
-- PTZ commands are stored against the controller (ESP32-001) or the camera id,
-- depending on which screen sent them, so both are listed.
SELECT created_at, device_id, command, mode, pan, tilt, status
  FROM pyroguard_ptz_commands
 WHERE device_id IN ('ESP32-001','pyroguard_camera_001')
 ORDER BY created_at DESC LIMIT 20;
SELECT created_at, device_id, event_type, snapshot_url,
       JSON_UNQUOTE(JSON_EXTRACT(payload_json, '$.reason')) AS reason
  FROM pyroguard_camera_events ORDER BY created_at DESC LIMIT 10;

-- 5. Incidents and e-mails
SELECT created_at, device_id, event_type, severity, message
  FROM pyroguard_event_history
 WHERE event_type IN ('CRITICAL_FIRE','DOOR_OPEN','WINDOW_OPEN','MOTION','ARMED','DISARMED')
 ORDER BY created_at DESC LIMIT 20;
SELECT created_at, event_type, status, provider, photo_path IS NOT NULL AS had_photo, error
  FROM pyroguard_incident_emails ORDER BY created_at DESC LIMIT 20;

-- 6. Motion events with position (Camera 1)
SELECT created_at, record_key, severity,
       JSON_EXTRACT(payload_json, '$.motion_x') AS x, JSON_EXTRACT(payload_json, '$.motion_y') AS y,
       JSON_EXTRACT(payload_json, '$.pan') AS pan, JSON_EXTRACT(payload_json, '$.auto_follow') AS auto_follow
  FROM pyroguard_event_history
 WHERE device_id = 'ESP32-001' AND event_type = 'MOTION'
 ORDER BY created_at DESC LIMIT 20;

-- 7. Tickets
SELECT 'support_tickets' AS entity, COUNT(*) AS stored_rows FROM pyroguard_support_tickets
UNION ALL SELECT 'support_ticket_messages', COUNT(*) FROM pyroguard_support_ticket_messages
UNION ALL SELECT 'support_ticket_events', COUNT(*) FROM pyroguard_support_ticket_events;
SELECT status, severity, COUNT(*) AS tickets, SUM(archived_at IS NOT NULL) AS archived
  FROM pyroguard_support_tickets GROUP BY status, severity ORDER BY status, severity;

-- 8. Row counts to compare with Supabase
SELECT 'room_readings' AS t, COUNT(*) FROM pyroguard_room_sensor_readings
UNION ALL SELECT 'sensor_history', COUNT(*) FROM pyroguard_sensor_history
UNION ALL SELECT 'event_history', COUNT(*) FROM pyroguard_event_history
UNION ALL SELECT 'camera_events', COUNT(*) FROM pyroguard_camera_events
UNION ALL SELECT 'home_members', COUNT(*) FROM pyroguard_home_members
UNION ALL SELECT 'devices', COUNT(*) FROM pyroguard_devices;
