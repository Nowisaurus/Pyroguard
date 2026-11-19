# Room sensors visible in both Admin and Homeowner views

- Admin Overview: shared responsive Room Sensor Coverage section after the analytics widgets.
- Admin Devices: shared Room Sensor Coverage before existing device management.
- Homeowner Overview and Devices: existing room coverage retained and styled with the same reusable compact cards.
- Four independent combinations: ESP32-001/Sala, ESP32-001/Bedroom, ESP32-002/Sala, ESP32-002/Bedroom.
- The RoomSensorService now reads the most recent row for each group separately, avoiding starvation when one sensor group generates more readings.
- Freshness threshold: 2 minutes. Missing/stale readings are not shown as healthy or replaced by zeros. Sensor status is not a guarantee of fire safety.
- Responsive grid: 4 columns at >=1000px, 2 at >=540px, 1 below.
- Existing camera/PTZ, legacy controller sensor cards, admin tools, user onboarding and database mappings are preserved.

## Database rollout
Run existing migrations `database/migrations/20261101_room_sensor_groups_supabase.sql` and `20261101_room_sensor_groups_mysql.sql` if not already applied. The worker's tables.json includes `pyroguard_room_sensor_readings`.

## Important integration boundary
No ESP32 firmware endpoint, sensor pin map or ingestion Edge Function is included. The cards cannot show actual sensor measurements until both ESP32 boards send independently labelled, authenticated sensor-group readings. A user must have appropriately scoped RLS access to their records. Do not insert dummy measurements and do not embed service_role secrets on ESP32s.

## Validate
From project root: `flutter pub get`, `flutter analyze`, `flutter run -d chrome`. From `deployment/local-mysql-sync` with your private `.env`: `npm ci`, `npm test`, `npm run once`, then `npm start` for continuous sync. Confirm equal records and correct user access in both databases. Live testing was not available in this environment.
