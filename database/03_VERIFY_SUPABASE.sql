-- ============================================================================
-- PYROGUARD - SUPABASE VERIFY (read-only)                     2026-11-19
-- Run in the Supabase SQL Editor after 01_SUPABASE_FINAL_SYNC_FIX.sql.
-- Run each block separately (the editor shows one result at a time).
-- ============================================================================

-- 1. Hardware registered with an owner (expect ESP32-001 and ESP32-002, owner not null)
SELECT device_id, user_id IS NOT NULL AS has_owner, device_type, status
  FROM public.devices
 WHERE device_id IN ('ESP32-001','ESP32-002')
 ORDER BY device_id;

-- 2. Four rooms: newest reading each (NO DATA = controller not sending yet)
WITH expected(controller_device_id, room_key, label) AS (
    VALUES ('ESP32-001','entrance','Entrance'), ('ESP32-001','sala','Sala'),
           ('ESP32-002','kitchen','Kitchen'),   ('ESP32-002','bedroom','Bedroom'))
SELECT e.controller_device_id, e.label, r.temperature, r.humidity, r.smoke_status,
       r.flame_detected, r.fire_confirmed, r.flame_fault, r.smoke_fault, r.received_at,
       CASE WHEN r.received_at IS NULL THEN 'NO DATA'
            WHEN now() - r.received_at <= interval '30 seconds' THEN 'FRESH'
            ELSE 'STALE' END AS status
  FROM expected e
  LEFT JOIN LATERAL (
        SELECT * FROM public.pyroguard_room_sensor_readings t
         WHERE t.controller_device_id = e.controller_device_id AND t.room_key = e.room_key
         ORDER BY t.received_at DESC LIMIT 1) r ON true
 ORDER BY e.controller_device_id, e.room_key;

-- 3. Live controller state + heartbeat + door/window
SELECT s.device_id, s.alert_status, s.incident_type, s.smoke_status, s.door_status, s.window_status,
       s.updated_at AS state_at, h.updated_at AS heartbeat_at, h.local_ip
  FROM public.device_current_state s
  LEFT JOIN public.device_heartbeats h ON h.device_id = s.device_id
 ORDER BY s.device_id;

SELECT device_id, contact_type, room_key, is_open, received_at,
       now() - received_at <= interval '2 minutes' AS fresh
  FROM public.pyroguard_contact_current_state ORDER BY device_id, contact_type;

-- 4. Camera 1 (the only camera): registry ONLINE time, telemetry, newest photos
SELECT device_id, ip_address, last_seen_at, now() - last_seen_at < interval '90 seconds' AS app_shows_online
  FROM public.pyroguard_camera_registry;

SELECT camera_device_id, device_id AS controller, camera_ip, status, motion_detected, wifi_rssi, updated_at
  FROM public.pyroguard_camera_telemetry ORDER BY camera_device_id;

SELECT created_at, device_id, event_type, snapshot_url, payload_json ->> 'reason' AS reason
  FROM public.camera_events ORDER BY created_at DESC LIMIT 10;

SELECT name, created_at FROM storage.objects
 WHERE bucket_id = 'incident-media' ORDER BY created_at DESC LIMIT 10;

SELECT id, public, file_size_limit FROM storage.buckets WHERE id IN ('incident-media','assets');

-- 5. Incidents and e-mails
SELECT created_at, device_id, event_type, severity, message
  FROM public.event_history
 WHERE event_type IN ('CRITICAL_FIRE','DOOR_OPEN','WINDOW_OPEN','MOTION','ARMED','DISARMED')
 ORDER BY created_at DESC LIMIT 20;

SELECT created_at, event_type, status, provider, array_length(recipients,1) AS recipients,
       photo_path IS NOT NULL AS had_photo, error
  FROM public.pyroguard_incident_emails ORDER BY created_at DESC LIMIT 20;

-- 6. Home 1 access for every verified account
SELECT u.email,
       u.raw_app_meta_data ->> 'provider' AS signed_in_with,
       CASE WHEN public.pyroguard_is_admin_account(u.id, u.email) THEN 'administrator'
            ELSE coalesce(m.member_role || ' / ' || m.membership_status, 'NOT ENROLLED') END AS home_1_access
  FROM auth.users u
  LEFT JOIN public.pyroguard_home_members m
         ON m.user_id = u.id AND m.home_id = public.pyroguard_shared_home_id()
 WHERE u.email_confirmed_at IS NOT NULL AND u.deleted_at IS NULL
 ORDER BY u.created_at;

-- 7. Support tickets (counts from real rows)
SELECT status, severity, count(*) AS tickets, count(*) FILTER (WHERE archived_at IS NOT NULL) AS archived
  FROM public.support_tickets GROUP BY status, severity ORDER BY status, severity;

-- 8. Sync backlog waiting for the MySQL worker (should drain to ~0)
SELECT 'sensor_history' AS t, count(*) FROM public.sensor_history WHERE mysql_synced = false
UNION ALL SELECT 'event_history', count(*) FROM public.event_history WHERE mysql_synced = false
UNION ALL SELECT 'support_tickets', count(*) FROM public.support_tickets WHERE mysql_synced = false;

SELECT worker_id, heartbeat_at, mysql_connected, completed_at,
       CASE WHEN heartbeat_at > now() - interval '90 seconds' AND mysql_connected THEN 'CONNECTED'
            ELSE 'NOT CONNECTED' END AS worker
  FROM public.pyroguard_local_sync_status;

-- 9. Policies installed by the fix (broad "any signed-in user" policies must be gone)
SELECT tablename, policyname, cmd FROM pg_policies
 WHERE schemaname IN ('public','storage')
   AND (policyname LIKE 'pyroguard_%' OR policyname LIKE 'ticket_%' OR policyname LIKE 'pg_room%')
 ORDER BY tablename, policyname;
SELECT count(*) AS broad_policies_left_should_be_0 FROM pg_policies
 WHERE policyname = 'pyroguard_shared_authenticated_read';
