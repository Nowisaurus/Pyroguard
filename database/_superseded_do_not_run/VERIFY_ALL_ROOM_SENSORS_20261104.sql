-- Read-only verification for four physical rooms. A missing room appears as NO DATA.
WITH expected(controller_device_id, room_key) AS (
  VALUES ('ESP32-001','entrance'), ('ESP32-001','sala'),
         ('ESP32-002','kitchen'), ('ESP32-002','bedroom')
)
SELECT e.controller_device_id, e.room_key,
       r.temperature, r.humidity, r.smoke_status, r.flame_detected,
       r.received_at,
       ROUND(EXTRACT(EPOCH FROM (now() - r.received_at))::numeric,1) AS seconds_old,
       CASE WHEN r.received_at IS NULL THEN 'NO DATA'
            WHEN now() - r.received_at <= interval '30 seconds' THEN 'FRESH'
            ELSE 'STALE' END AS status
FROM expected e
LEFT JOIN LATERAL (
   SELECT temperature, humidity, smoke_status, flame_detected, received_at
   FROM public.pyroguard_room_sensor_readings t
   WHERE t.controller_device_id=e.controller_device_id AND t.room_key=e.room_key
   ORDER BY t.received_at DESC LIMIT 1
) r ON true
ORDER BY e.controller_device_id,e.room_key;
-- Optional reed-switch table, run separately once migration is applied:
-- SELECT device_id, room_key, contact_type, is_open, received_at
-- FROM public.pyroguard_contact_current_state ORDER BY device_id, contact_type;
