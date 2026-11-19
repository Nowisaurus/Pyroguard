# PyroGuard fire sensor dashboard consolidation

## Included
- One combined room-sensor block per admin page (the duplicated separate diagnostics listing was removed from those pages).
- Admin-only live summary with fresh group counts, active signals, stale group counts, incomplete group counts, and four-room temperature comparison based on actual current records.
- Homeowner overview/device views retain the existing four responsive room cards with temperature, humidity, MQ-2 raw value, smoke status, flame and buzzer indicators. Missing fields correctly show **INCOMPLETE**, not **FRESH**.
- Recorded temperature trend inside the existing paginated room-history sheet. Only the records fetched from Supabase are plotted; missing values are not made up. The chart is explicitly labeled as loaded history rather than complete lifetime history.
- Existing cameras, navigation, ticket administration, Supabase/MySQL mappings and database migrations preserved.

## Still required before fire-system operational claims
- Each ESP32 firmware must separately sample both Sala and Bedroom DHT22, MQ-2 and flame sensors and drive each room's buzzer using local logic, even without internet.
- ESP32 must submit authenticated room-specific records to public.pyroguard_room_sensor_readings using an authorized server endpoint; do not embed service-role secrets in firmware.
- Smoke detection needs a calibrated sensor warm-up, threshold policy and validation; raw MQ-2 values alone are not a reliable fire classifier.
- Validate both room mappings on both physical controllers, timing, loss of Wi-Fi, missing sensors, alert latency and notification paths; verify Supabase inserts and MySQL mirror read-back.
- For longitudinal incident counts across *all* records, use database aggregation rather than the currently paged preview.

## Deployment
- This update changes only Flutter view widgets; no new SQL migration is required beyond the existing 20261101 room sensor migrations.
- Run `flutter pub get`, `dart format lib/screens/admin/admin_screen.dart lib/screens/dashboard/room_sensor_panel.dart`, then `flutter analyze` and test with real hardware.
- MySQL worker tests: 11/11 passed in this build; live Supabase/MySQL connectivity not tested.
