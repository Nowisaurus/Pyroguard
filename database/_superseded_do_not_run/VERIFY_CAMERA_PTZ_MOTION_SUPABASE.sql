-- PyroGuard: verify that the camera, servos, motion and controller are being
-- stored in Supabase. Run in the Supabase SQL editor.

-- 0) ESP32-001 must be registered with its owner (device-command needs this).
SELECT device_id, user_id FROM public.devices WHERE device_id = 'ESP32-001';

-- 1) Controller heartbeat (app shows HARDWARE CONNECTED). Updated every ~20 s.
SELECT device_id, wifi_ok, supabase_ok, camera_ok, ptz_ok, mq2_ok, flame_ok,
       dht22_ok, door_ok, window_ok, uptime_secs, local_ip, updated_at,
       now() - updated_at AS age
FROM public.device_heartbeats WHERE device_id = 'ESP32-001';

-- 2) Camera 1 status (online, motion, servo angles). Updated every ~15 s.
SELECT camera_device_id, device_id, camera_ip, status, motion_detected,
       motion_pixels, pan_angle, tilt_angle, wifi_rssi, uptime_ms, updated_at
FROM public.pyroguard_camera_telemetry
WHERE camera_device_id = 'pyroguard_camera_001';

-- 3) Servo position (manual and auto-follow). Updated every ~15 s and after moves.
SELECT device_id, pan_position, tilt_position, moving, last_device_at, updated_at
FROM public.ptz_state WHERE device_id = 'ESP32-001';

-- 4) Motion events from Camera 1 (newest first) and their MySQL mirror flag.
SELECT created_at, record_key, message, severity, mysql_synced,
       payload_json->>'pan' AS pan, payload_json->>'tilt' AS tilt,
       payload_json->>'auto_follow' AS auto_follow
FROM public.event_history
WHERE device_id = 'ESP32-001' AND event_type = 'MOTION'
ORDER BY created_at DESC LIMIT 20;

-- 5) Manual Camera 1 PTZ commands sent from the app.
SELECT created_at, device_id, command, mode, pan, tilt, status, applied_at
FROM public.ptz_commands
WHERE device_id = 'pyroguard_camera_001'
ORDER BY created_at DESC LIMIT 20;

-- 6) Latest sensor readings (sensor-ingest, unchanged).
SELECT * FROM public.pyroguard_room_sensor_readings
ORDER BY created_at DESC LIMIT 10;

-- If step 2 is empty and ESP32-001's Serial Monitor shows HTTP 409
-- "Camera belongs to another controller", an old camera row exists:
-- DELETE FROM public.pyroguard_camera_telemetry
-- WHERE camera_device_id = 'pyroguard_camera_001' AND device_id <> 'ESP32-001';

-- 7) Arm / disarm state from the app and what ESP32-001 recorded.
SELECT device_id, arm_mode, door_enabled, window_enabled, motion_enabled, updated_at
FROM public.system_state;

SELECT created_at, event_type, message, severity, mysql_synced
FROM public.event_history
WHERE device_id = 'ESP32-001'
  AND event_type IN ('DOOR_OPEN','DOOR_CLOSED','WINDOW_OPEN','WINDOW_CLOSED','ARMED','DISARMED')
ORDER BY created_at DESC LIMIT 20;

-- 8) App commands and the controller's acknowledgement.
SELECT created_at, command, status, result_message, applied_at
FROM public.device_commands WHERE target_device_id = 'ESP32-001'
ORDER BY created_at DESC LIMIT 20;
