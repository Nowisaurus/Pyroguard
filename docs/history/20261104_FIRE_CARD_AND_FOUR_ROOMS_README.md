# PyroGuard: four-room hardware readings and verified fire assistance

## Current wiring and device mapping

ESP32-001 = Entrance (DHT GPIO4, MQ-2 digital GPIO26, flame GPIO35, buzzer GPIO18) and Sala (DHT GPIO16, MQ-2 digital GPIO19, flame GPIO21, buzzer GPIO22). Entrance reed door GPIO33, Sala reed window GPIO32. ESP32-002 is a SEPARATE controller for Kitchen and Bedroom and needs its own firmware, physical sensor wiring, and device credential. ESP32-001 cannot transmit data for unwired ESP32-002 sensors.

## Fixes in this source

- RoomSensorService queries entrance/sala/kitchen/bedroom separately, refreshes on Supabase Realtime or every 10 seconds, retains the latest two actual readings per room, and does not invent values.
- `MainShell` no longer uses a latched legacy alarm boolean as proof of a fire. The BFP assistance card appears only when **two successive readings from the same room** are within 30 seconds and separately satisfy a multi-sensor criterion: (flame AND smoke ALARM), (flame AND temperature >= 50C), or (smoke ALARM AND temperature >= 50C). The readings must have distinct timestamps, at most 30 s apart. These are application display criteria, not laboratory-certified fire detection thresholds. An isolated flame reading remains a warning in the Room Sensor panel. Test emergency-response policy with qualified safety personnel before operational use.
- The assistance UI is a restrained, scrollable card with an existing transparent PyroGuard logo and BFP contact details. The Call BFP button is a *user-initiated* `tel:` dialer action through existing `NotificationService.callBFP`; the app does not itself place a completed call or dispatch responders. A phone-capable device and confirmed BFP number are required; web desktop browsers may have no tel handler.
- The Dashboard summary and analytics no longer classify a lone flame digital comparator as a confirmed multi-sensor fire. Room history is retained.
- Door/window activity reads the optional `pyroguard_contact_current_state` first (fresh <=2 minutes), then existing device state and event-history fallback. No fabricated closed states.
- The packaged ESP32-001 firmware is the most recent two-sensor-set diagnostic version; it sends `entrance` and `sala` and checks the two-record sensor-ingest acknowledgment. Existing sensor pins, manual PTZ, camera integration, and security sync are preserved.
- This package also includes a sensor-ingest Edge Function and optional contact table SQL; they require manual deployment. No Supabase database was modified by packaging.

## Installation (Windows)

1. Back up the original Flutter folder and Supabase schema/data.
2. Extract this ZIP to a new folder; open PowerShell in the folder with `pubspec.yaml`.
3. Run `flutter pub get`, `flutter analyze`, then `flutter run -d chrome`. The source was not compiled in the build environment (Flutter SDK unavailable).
4. Review and apply `database/migrations/20261104_contact_state.sql` in Supabase SQL Editor **only if the table is not yet present**; deploy `supabase/functions/sensor-ingest/index.ts` with existing verified JWT/device secrets. Do not overwrite deployed functions without backing up existing versions and checking compatible payloads.
5. Open the ESP32-001 `.ino` from `firmware/PyroGuard_ESP32_001_MultiSensor` in Arduino IDE. Confirm existing physical wiring and secrets. Compile, upload, and monitor at 115200 baud. The exact board, libraries and physical sensors could not be tested in this build environment.
6. Rotate the Wi-Fi and device secrets that were previously pasted into chat or included in firmware. Never put a service-role key in Flutter or on device.
7. Use `database/VERIFY_ALL_ROOM_SENSORS_20261104.sql` in Supabase. Confirm two recent real rows for Entrance and Sala, and for ESP32-002 only when that independent controller is installed and transmitting. Check flame raw GPIO35 and GPIO21 safely; GPIO35 has no internal pull-up and a floating signal can cause false detection. **Never bypass genuine hazards:** evacuate/call emergency services whenever you observe real danger.
8. For BFP calling, configure and confirm a valid BFP phone in Settings, then tap the card button *on a device with an installed dialer*. Verify the phone dialer opens; call completion requires human action.

## Important limits

Actual physical sensor health, hardware flashing, Supabase RLS credentials, true fire conditions, ESP32-002 firmware, and live phone calls are NOT verified by this ZIP. This is a code integration and review package, not a certified safety system. An actual flame-only incident can still be dangerous even if the multi-sensor BFP card does not appear; the app maintains a warning for that case.
