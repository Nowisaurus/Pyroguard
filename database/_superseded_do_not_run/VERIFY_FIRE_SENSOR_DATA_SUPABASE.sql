-- Supabase PostgreSQL only. READ ONLY.
-- Confirm table exists and compare exact room-group record counts with MySQL verification output.
SELECT controller_device_id, room_key,
       count(*) AS stored_readings,
       max(sampled_at) AS latest_sample
FROM public.pyroguard_room_sensor_readings
GROUP BY controller_device_id, room_key
ORDER BY controller_device_id, room_key;

-- Verify recorded incident counts separately; absence of events is not proof of device health.
SELECT count(*) AS recorded_events FROM public.event_history;
