-- PyroGuard: verify the local MySQL mirror (filled by
-- deployment/local-mysql-sync, which copies the Supabase tables).
-- Run in MySQL Workbench / phpMyAdmin on the laptop database.

SELECT device_id, wifi_ok, camera_ok, ptz_ok, mq2_ok, dht22_ok, local_ip, updated_at
FROM pyroguard_device_heartbeats WHERE device_id = 'ESP32-001';

SELECT camera_device_id, camera_ip, status, motion_detected, motion_pixels,
       pan_angle, tilt_angle, updated_at
FROM pyroguard_pyroguard_camera_telemetry
WHERE camera_device_id = 'pyroguard_camera_001';

SELECT device_id, pan_position, tilt_position, moving, updated_at
FROM pyroguard_ptz_state WHERE device_id = 'ESP32-001';

SELECT created_at, record_key, message, severity,
       JSON_EXTRACT(payload_json, '$.pan') AS pan,
       JSON_EXTRACT(payload_json, '$.auto_follow') AS auto_follow
FROM pyroguard_event_history
WHERE device_id = 'ESP32-001' AND event_type = 'MOTION'
ORDER BY created_at DESC LIMIT 20;

SELECT created_at, command, mode, pan, tilt, status
FROM pyroguard_ptz_commands
WHERE device_id = 'pyroguard_camera_001'
ORDER BY created_at DESC LIMIT 20;
