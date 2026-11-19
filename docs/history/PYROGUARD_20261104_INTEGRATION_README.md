# PyroGuard hardware, Supabase & Flutter integration update — November 4, 2026

## Delivered in this package

- Preserves the existing project screens, assets, tutorials, camera code, administration code, and historical database migrations.
- Maps **ESP32-001 → Entrance + Sala** and **ESP32-002 → Kitchen + Bedroom** using their actual database room keys, rather than the older `sala`/`bedroom` aliases for both.
- The existing Room Sensor Coverage service/panels now retrieve the right room-specific rows and consider the latest `received_at` when determining freshness. Missing analog MQ-2 values are not treated as fake zero or a sensor failure.
- The existing Dashboard Repository retrieves fresh sensor records for both controllers independently, and its System Connections + Live Home Status widgets can display recent sensor telemetry without waiting for another table's heartbeat. Heartbeat is labeled separately; a fresh sensor feed is **not** falsely described as a verified heartbeat.
- Analytics now reads real persisted room sensor history (the most recent 1,000 records), not only `sensor_history` which may still be empty. Counts represent **samples**, not distinct incidents.
- Arm/disarm commands remain pending in Flutter until the hardware acknowledges. The ESP32-001 firmware is patched to apply the command payload before acknowledging; the `device-command` Edge Function is patched to persist `system_state` after a successful hardware ACK and attempt the MySQL mirror. Unacknowledged commands must not display as applied.
- `database/migrations/20261104_shared_read_only_home1.sql` lets *all authenticated users* read **operational** telemetry and system status without enrollment/approval. It does not create memberships, restore revoked membership rows, assign new owners, modify existing owners/admins, grant command-writing rights, or touch historical records. **Caution:** any verified/signed-in PyroGuard account will be able to view this shared monitoring data, even if not associated with the property. Treat this as a single shared-installation decision, not multi-tenant policy.

## Deployment sequence

1. Back up the Supabase database. Review and run `database/migrations/20261104_shared_read_only_home1.sql` from Supabase SQL Editor. The new check is marked `NOT VALID` to avoid rewriting/deleting older rows with legacy room keys.
2. Deploy the **modified** `supabase/functions/device-command/index.ts` using your Supabase deployment workflow. Preserve existing device credentials in Supabase Secrets. Never copy a service-role key into Flutter.
3. Flash the updated `firmware/PyroGuard_ESP32_001_MultiSensor/PyroGuard_ESP32_001_MultiSensor.ino` with Arduino IDE. Recheck pins, Wi-Fi settings, camera link and cloud secrets on your device. Make sure `device-command` is reachable. Do **not** assume ESP32-002 is deployed: only ESP32-001 firmware was included in the uploaded project.
4. On your computer, in the Flutter project folder, run `flutter pub get`, `flutter analyze`, then `flutter run -d chrome`. No extra temporary duplicated dashboard widget is needed; the existing Dashboard's data services have been updated.
5. Run `database/VERIFY_PYROGUARD_SYNC_20261104.sql` in Supabase. The last 2–3 minutes of sensor rows should update independently for `entrance` and `sala`. The second pair appears when ESP32-002 is correctly provisioned and sending readings. Verify `device_heartbeats` separately.
6. While physically next to the hardware and with an authorized account, test ARM HOME, ARM AWAY, and DISARM **one at a time**. Confirm on Serial Monitor that the desired mode physically applies, then check `device_commands.status='applied'` and `system_state.arm_mode`. Do not claim applied solely because the command was queued. Check alarms with safe conditions and do not deactivate fire warning protections.
7. Log in using a previous and a newly created verified account. Both should be able to read the shared sensor cards after policy deployment. Check that admin-only routes and command writes still require their existing privileges. Do not re-enroll/reassign homes or change admin roles.

## Honest verification limits

- The source was inspected and patched, but **not compiled** in this environment (Flutter/Arduino CLI unavailable).
- Your live Supabase project cannot be altered from this ZIP: the SQL and Edge Function changes need deployment. We have not run live hardware, camera stream, door/window persistence, MySQL worker, or end-to-end authentication tests here.
- The ESP32-001 `/health` API and live Entrance/Sala database uploads were confirmed by the user earlier; no fresh post-patch measurements have been validated.
- Door/window activity still requires actual `device_current_state` or event records; room sensor readings do not persist door/window fields. No invented door/window status or heartbeat is inserted.
- The archive contains the original project's configuration and potentially embedded Wi-Fi/device credentials; keep this ZIP private and rotate credentials previously exposed in chat/logs.
