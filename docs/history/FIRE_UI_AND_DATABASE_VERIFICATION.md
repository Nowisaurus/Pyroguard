# PyroGuard consolidated fire dashboard update

## Changed Flutter files
- `lib/screens/admin/admin_screen.dart` — equal-height compact ticket/incident row, card-style empty/error states.
- `lib/screens/dashboard/room_sensor_panel.dart` — compact responsive metric tiles, single missing-data state per group, concise admin snapshot.
- `lib/screens/dashboard/dashboard_home.dart` — homeowner incident history displays compact placeholder cards rather than text-heavy messages.

No database schema columns were added by this UI change. Original room-sensor migrations remain under `database/migrations/20261101_room_sensor_groups_*.sql`; do not apply them repeatedly without first checking whether they have already been run.

## Data architecture
- Supabase is the primary sensor/event store.
- The local MySQL worker maps `pyroguard_room_sensor_readings` to `pyroguard_room_sensor_readings` and preserves the other configured mappings in `deployment/local-mysql-sync/tables.json`.
- Run the two **read-only** `database/VERIFY_FIRE_SENSOR_DATA_*.sql` queries in their respective editors and compare group IDs, latest timestamps and row totals. A complete reconciliation requires comparing individual records, not counts alone.
- `npm run once` performs a worker verification cycle; `npm start` starts continuous sync when the private `.env` is restored. Do not expose `.env` or the server role key in Flutter.

## Verification commands
From the Flutter root: `flutter pub get`, `dart format lib/screens/admin/admin_screen.dart lib/screens/dashboard/room_sensor_panel.dart lib/screens/dashboard/dashboard_home.dart`, `flutter analyze`, `flutter run -d chrome`.

From `deployment/local-mysql-sync`: `npm ci`, `npm test`, `npm run once`, then `npm start`.

## Safety and remaining work
- These are UI changes; physical ESP32 wiring, authenticated per-room data ingestion, calibrated MQ-2 thresholds, independent local buzzer activation and end-to-end alarm testing are still required before declaring a functioning fire-safety installation.
- Missing readings, stale timestamps or failed queries must not be interpreted as normal conditions.
- Fresh sensor values are not proof of calibrated smoke/fire detection or notification delivery.
- Existing cameras, PTZ, settings, tutorials, navigation and admin access are retained.
