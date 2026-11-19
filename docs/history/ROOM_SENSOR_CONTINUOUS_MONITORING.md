# PyroGuard room sensor continuous monitoring

## Implemented in this revision
- Four independent groups: ESP32-001 and ESP32-002, each with Sala and Bedroom.
- Shared homeowner room cards using saved Supabase readings (no artificial sensor values).
- Admin Overview and Admin Devices now also show an independent diagnostics summary: fresh/stale/alert/no data, elapsed time since sample and missing individual sensor fields.
- Automatic latest-reading refresh every 10 seconds while the service runs. A Supabase Realtime INSERT listener refreshes sooner when Realtime publication and RLS allow it; polling is the fallback.
- History loads in pages of 100 records, with additional pages on demand instead of limiting the total accessible history. A single HTTP query must still be bounded for stability.
- Existing camera, alerts, controller views, and sync worker preserved.

## Required deployment (not performed here)
1. Execute `database/migrations/20261101_room_sensor_groups_supabase.sql` in the Supabase SQL editor and the MySQL counterpart in MySQL Workbench, if not yet applied. Do not rerun destructive SQL; these create tables if missing.
2. Ensure homeowners' assigned user_id is saved on every room-sensor record and verified against the deployed RLS policies.
3. ESP32 firmware must transmit a separate authenticated payload for *each* controller/room pair. Do not place a service-role key in firmware. Configure Edge Function or service ingestion, validate ranges and timestamps, and use local fire/smoke buzzer logic even when the internet is down.
4. If faster-than-polling Realtime updates are wanted, enable Realtime for the room sensor table and ensure publication permissions; 10-second polling continues if Realtime is unavailable.
5. Confirm the local MySQL worker has its private `.env`, tables.json includes the room sensor table and `npm run once` verifies every configured table. Run `npm start` for continuous mirroring on a connected machine.

## Verification
- In a test homeowner session, submit individual Sala and Bedroom telemetry for both controllers; confirm none of the four panels borrows readings from another room.
- Verify an inactive/unpowered device becomes STALE after two minutes, not falsely healthy.
- Omit one sensor field and confirm admin sees it as 'Not reported'.
- Trigger a known safe test input and confirm the alert status as well as the local buzzer action through hardware tests. Never use this system as a sole life-safety alarm.
- Save over 100 readings in a test room and use Load more in the history viewer. Remember identical sampled_at values at page boundaries need unique timestamps for reliable cursor pagination.
- Verify equivalent source and target record IDs in Supabase and MySQL after a sync cycle.

## Limits
Not compiled with Flutter here; no access to deployed database or ESP32 devices. Source integration does not prove hardware reads, alerts, persistence or ongoing synchronization. A historical record is not created by reading a Flutter widget; it must be ingested and saved by the device backend. History is not erased by the pagination UI. Backend retention policies may still apply.
