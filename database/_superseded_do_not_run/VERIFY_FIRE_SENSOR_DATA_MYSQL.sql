-- MySQL Workbench only. READ ONLY.
USE pyroguard_db;
SELECT controller_device_id, room_key,
       count(*) AS stored_readings,
       max(sampled_at) AS latest_sample
FROM pyroguard_room_sensor_readings
GROUP BY controller_device_id, room_key
ORDER BY controller_device_id, room_key;

SELECT count(*) AS recorded_events FROM pyroguard_event_history;
