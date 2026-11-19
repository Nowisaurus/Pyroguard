# PyroGuard: setup and current state (2026-11-04c)

Older notes are in `docs/history/`.

## Deploy in this order
1. **Flash both boards**: `firmware/PyroGuard_ESP32_001_MultiSensor` and `..._002_...`.
   The app treats only readings from this sketch as real fire data.
2. **Supabase SQL Editor**:
   - run `database/migrations/20261104b_false_fire_and_rooms_supabase.sql`
   - then `database/migrations/20261104c_archive_false_fire_data_supabase.sql`. This moves the old
     false-fire readings and events into archive tables, so Analytics, Events and Calendar start clean.
     It doesn't delete them.
3. **Supabase functions**: deploy `sensor-ingest` and `device-command` (commands in section 2 below).
4. **MySQL**: run `database/migrations/20261104b_mysql_sync_fix.sql`, then start the worker (section 3).
5. **Flutter**: `flutter pub get` then `flutter run -d chrome`.

## Rules the app now follows
- **Fire siren, Call BFP card and the Analytics fire count:** only when the board sends
  `fire_confirmed = true` for a room. That means smoke + flame in the same room for 5 s, with no faulty
  sensor. Readings from the old sketch never count as fire.
- **Flame-only or smoke-only:** a warning. It must last 8 s, and repeats are quiet for 5 minutes.
- **"HARDWARE CONNECTED":** shows as soon as the board sends a heartbeat or a sensor reading.

---

# Details: false-fire fix, two-board firmware, MySQL sync fix

## 1. Firmware: one sketch, two boards

| Folder | Board | Areas | Door / window labels |
|---|---|---|---|
| `firmware/PyroGuard_ESP32_001_MultiSensor` | ESP32-001 (Batch 1) | Entrance + Sala | Entrance door / Sala window |
| `firmware/PyroGuard_ESP32_002_MultiSensor` | ESP32-002 (Batch 2) | Kitchen + Bedroom | Fire exit door / Bedroom window |

The two files are identical except for `#define PYROGUARD_BATCH 1` or `2`. Both use the pin map from your
attached sketch (DHT 4/16, MQ-2 DO 26/19, flame DO 35/21, buzzers 18/22, door 33, window 32).
ESP32-002 has no camera link or servos.

**How false fires are now prevented**

- **FIRE** needs smoke AND flame in the **same room**, both on together for **5 seconds**.
- A flame or smoke input that is already active at boot isn't trusted until it reads CLEAR once.
  That covers a floating GPIO35 or a mis-set sensitivity knob.
- **FLAME FAULT:** the input flickers more than 16 times in 10 s (noise, loose wire, missing pull-up), or
  stays on for 2 minutes with no smoke. While faulted it's ignored.
- **SMOKE FAULT:** the MQ-2 never reads clear in the first minute after warm-up. That usually means the
  knob is set too sensitive.
- Faults appear in the app as **CHECK SENSOR**, never as fire.
- Serial commands: `faults` shows the guard state and `faultreset` clears it.

These rules were simulated on a PC, including a flame stuck at boot, a chattering flame, a real fire,
flame in one room with smoke in the other, a stuck flame and a stuck smoke sensor. All passed.

**Door / window**

Type `contacts` in the Serial Monitor (115200). Move each magnet: the raw pin must change.
If a contact reports OPEN when it's closed, type `door invert` or `window invert`. The setting is saved
on the board, so you don't need to upload again.

The ESP32-002 copy uses the same `DEVICE_INGEST_KEY` as ESP32-001.

## 2. Supabase

1. In the SQL Editor, run `database/migrations/20261104b_false_fire_and_rooms_supabase.sql`. It:
   - allows the room keys entrance, sala, kitchen and bedroom
   - adds the `fire_confirmed`, `flame_fault` and `smoke_fault` columns
   - makes the fire-incident trigger use confirmed fire only
   - adds the door/window state table
2. Deploy the functions from the project folder that contains `package.json`:
   ```powershell
   npm install
   npx supabase login
   npx supabase functions deploy sensor-ingest --project-ref gljzunjbmmsbkayxtyfc --no-verify-jwt
   npx supabase functions deploy device-command --project-ref gljzunjbmmsbkayxtyfc --no-verify-jwt
   ```
   `sensor-ingest` accepts either the `PYROGUARD_DEVICE_KEY` secret or the SHA-256 secrets
   (`SENSOR_DEVICE_KEY_SHA256`, `SENSOR_DEVICE_KEY_SHA256_ESP32_002`).

## 3. MySQL sync

**The cause:** `core.mjs` saves every copied row into `pyroguard_local_source_records.payload_raw`, but no
script ever created that column. Every row copy failed with `Unknown column 'payload_raw'`, so nothing synced.

**Fixed in `deployment/local-mysql-sync`:**
- The worker adds the missing column itself.
- A live row that changes while it's being copied (for example `device_current_state`, which updates every
  5 s) is retried on the next cycle instead of failing the whole table.
- Each verified row is acknowledged even if another table has an error. Before, one error blocked all
  acknowledgements.
- Room readings, `sensor_history` and `event_history` sync only the recent window. They used to re-read the
  whole table every cycle.
- `start-sync.bat` no longer points to the old `PyroGuard_` folder.

**Run it:**
1. In MySQL Workbench, run `database/migrations/20261104b_mysql_sync_fix.sql`.
2. Copy your existing private `.env` into `deployment/local-mysql-sync`.
3. In that folder, run:
   ```powershell
   npm ci
   npm test
   npm run once
   ```
   Expect `VERIFIED: ... 0 errors`. Then keep it running with `start-sync.bat`.

## 4. Flutter

- **Fire siren and Call BFP card:** both appear only after two consecutive readings, from one room, in which
  the board confirmed a fire. A single controller snapshot no longer starts the siren. Closing the card also
  stops the siren.
- **Warnings:** a warning must last 8 seconds before it beeps. The same warning beeps at most once every
  5 minutes; repeats only update the in-app banner.
- **Buzzer:** the board's buzzer output (for example a door chime) is no longer treated as a hazard.
- **Camera temperature:** removed from the dashboard and the Camera page.
- **Shared Home 1 changes are carried over:** no device-ID step at sign-up, no new-owner provisioning, the
  installation-code screen is removed, shared history is shown, and the connection indicators refresh on
  their own.

## Old data note

An earlier version of the shared-access script renamed ESP32-001 `entrance` rows to `sala`. That step has
been removed. To see whether it affected any rows, run:

```sql
SELECT count(*) FROM (SELECT received_at FROM pyroguard_room_sensor_readings
 WHERE controller_device_id='ESP32-001' AND room_key='sala'
 GROUP BY received_at HAVING count(*) > 1) x;
```

A count above 0 means some older Entrance readings are labelled Sala. Those rows can't be told apart
afterwards. New readings are stored correctly.
