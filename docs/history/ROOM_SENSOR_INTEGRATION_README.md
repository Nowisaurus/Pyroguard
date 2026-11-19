# PyroGuard: two sensor groups per ESP32

Scope: **4 room groups**, not four controllers or new cameras. The existing camera, PTZ, security controls and legacy controller sensor snapshots are preserved.

| Controller | Group | Room | Sensors |
|---|---|---|---|
| ESP32-001 | 1 | Sala | DHT22, MQ-2, IR flame, 3.3V active buzzer |
| ESP32-001 | 2 | Bedroom | DHT22, MQ-2, IR flame, 3.3V active buzzer |
| ESP32-002 | 1 | Sala | DHT22, MQ-2, IR flame, 3.3V active buzzer |
| ESP32-002 | 2 | Bedroom | DHT22, MQ-2, IR flame, 3.3V active buzzer |

The four new panels appear on the homeowner Overview and Device screen. Data is read from `pyroguard_room_sensor_readings`. A panel is fresh only when its actual sample timestamp is no more than two minutes old. Missing fields are reported, never assumed normal or zero.

## Deployment order
1. Back up Supabase and MySQL.
2. Run `database/migrations/20261101_room_sensor_groups_supabase.sql` in Supabase.
3. Run `database/migrations/20261101_room_sensor_groups_mysql.sql` in MySQL Workbench.
4. Restore the existing private worker `.env`, run `npm ci`, `npm test`, `npm run once` under `deployment/local-mysql-sync`.
5. Update both ESP32 controller firmwares to post independent **signed, authenticated** sensor samples for each group to a protected ingestion endpoint. No ingestion endpoint or firmware wiring changes have been implemented by this patch. Do not put service_role keys on devices.
6. Each inserted Supabase record requires `id` (or default-generated ID), `user_id` (real homeowner UUID), `controller_device_id`, `room_key`, `sampled_at`, and actual sensor measurements. Insert two records per sample cycle for each ESP32, one for sala and one for bedroom; never copy one room into another. The worker mirrors committed rows by `id`.

Sample JSON shape **for a protected server**, not direct unauthorized client insert:
```json
{"controller_device_id":"ESP32-001","room_key":"sala","temperature":29.5,"humidity":65,"smoke_raw":310,"smoke_status":"CLEAR","flame_detected":false,"buzzer_active":false,"sampled_at":"2026-11-01T03:00:00Z"}
```
The numeric values above are an illustrative payload only and are never inserted as dummy records.

## Hardware cautions
Two MQ-2 sensors draw significant heater current. Use a correctly sized common-ground external supply, suitable regulation, and an ADC-safe divider if the MQ-2 module output exceeds 3.3 V. Do not power several heaters/servos from the ESP32 3.3 V output. ESP32 ADC2 conflicts with Wi-Fi; choose ADC1 inputs carefully after checking the existing pin allocations. DHT22 modules need appropriate pull-ups. Each buzzer must be driven within GPIO current limits or via a transistor. The firmware must define separate pin assignments and alarm logic for each sensor group. Existing camera/PTZ wiring must not be disturbed. This application is not certified fire-safety equipment.

## Verification
- Confirm four distinct controller/room combinations in Supabase, each with its own sample timestamp.
- Confirm the authenticated homeowner can see only their own samples.
- Confirm all four panels update independently when the corresponding hardware sensor changes.
- Run `npm run once` and confirm the four records exist in MySQL with matching IDs and values.
- Check alert and buzzer behavior on each ESP32 independently; firmware must fail safe even without Wi-Fi.
