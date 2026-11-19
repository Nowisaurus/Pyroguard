-- Run each section in Supabase SQL Editor after applying the migration.
-- Sensor freshness: each physical room has its own independent last sample.
SELECT controller_device_id,room_key,max(received_at) AS last_received,
 round(extract(epoch from (now()-max(received_at)))::numeric,1) AS seconds_old,
 count(*) AS stored_history_rows
FROM public.pyroguard_room_sensor_readings
GROUP BY controller_device_id,room_key
ORDER BY controller_device_id,room_key;

-- Heartbeat state is independent from sensor-feed freshness.
SELECT device_id,updated_at,
 round(extract(epoch from (now()-updated_at))::numeric,1) AS seconds_old
FROM public.device_heartbeats
WHERE device_id IN ('ESP32-001','ESP32-002')
ORDER BY updated_at DESC LIMIT 10;

-- Pending/applied/failed arm commands: APPLIED requires hardware ACK.
SELECT target_device_id,command,status,created_at,applied_at,result_message
FROM public.device_commands
WHERE target_device_id IN ('ESP32-001','ESP32-002')
ORDER BY created_at DESC LIMIT 20;

-- Actual persisted security state after acknowledgement.
SELECT device_id,arm_mode,door_enabled,window_enabled,motion_enabled,updated_at
FROM public.system_state
WHERE device_id IN ('ESP32-001','ESP32-002');

-- Verify the currently deployed row-security policies. Never expose secrets.
SELECT tablename,policyname,cmd,roles,qual
FROM pg_policies
WHERE schemaname='public'
AND tablename IN ('pyroguard_room_sensor_readings','device_commands','system_state','device_heartbeats')
ORDER BY tablename,policyname;
