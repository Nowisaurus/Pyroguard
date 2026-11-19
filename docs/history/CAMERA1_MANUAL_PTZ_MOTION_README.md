# PyroGuard: Camera, Servo, Motion, Sensors and Databases

## How everything talks (local Wi-Fi + Supabase + MySQL, no PC script)

```
Camera 1 (DFR1154) -- analyses its own frames, serves video (:81) and /motion
      ^  GET /link 4x per second (key, IP, servo angles)
      |  reply: where the motion is
ESP32-001 (main)   -- sensors, buzzer, servos; DECIDES auto-follow moves
      |  HTTPS (background task)
      v
Supabase           -- sensor-ingest  : sensor readings (every 5 s)
                      device-command : device_heartbeats (20 s), pyroguard_camera_telemetry (15 s),
                                       ptz_state (15 s + after moves), event_history MOTION
      |  local-mysql-sync worker (tables.json)
      v
MySQL (laptop)     -- same tables, mirrored automatically

Flutter app -- live video, transparent PTZ overlay, auto-follow switch,
               motion badge, stored-motion list; manual PTZ goes app -> Camera 1 -> ESP32-001
               and is saved in Supabase ptz_commands (mirrored to MySQL).
```

## Camera roles

| Camera | Role | Controls on the video |
|---|---|---|
| **Camera 1** (DFR1154, built-in mic + speaker) | **Two-way + PTZ** | Listen/Mute, Speak, Record, Call BFP, ZM, PTZ pad (auto-follow), CH, snapshot |
| **Camera 2** (ESP32-CAM OV2640) | **Monitoring only** | Record, Call BFP, ZM, CH, snapshot. No audio and no pan/tilt commands. |

Camera 2 still streams live video. It also shows motion if its firmware provides `/motion`,
and saves snapshots and recordings to Evidence (Supabase + MySQL).

## What you see in the app

The camera screen and the full-screen view (⛶) for both cameras have **compact,
transparent controls over the live video**:

| Button | What it does |
|---|---|
| **Listen / Mute** | Turns the camera microphone audio on or off |
| **Record** | Saves evidence frames, 1 per second for up to 60 s, to Supabase storage plus a `camera_history` row (Supabase + MySQL). Tap again to stop. The ESP32 camera sends JPEG frames, not a video file. |
| **Speak** | Hold to talk through the camera speaker |
| **Call BFP** | Opens the dialer for the saved BFP contact (set it in Settings) and logs the action |
| **ZM + / −** | Digital zoom, 1× to 3× (the camera has no optical zoom) |
| **PTZ pad** | Tap = 10° step, hold = keep moving, release = stop, ⌂ = centre |
| **CH ▲ / ▼** | Switches between Camera 1 and Camera 2 |
| **📷 (top right)** | Snapshot to Evidence (Supabase + MySQL) |
| **AUTO-FOLLOW pill** | Camera 1 auto-follow on/off; manual moves pause it for 20 s |

Other things on screen:
- The **video quality is fixed**: VGA 640×480, JPEG 10.
- The **MOTION badge**, the **"Stored motion events"** list on the Camera tab, and
  **HARDWARE CONNECTED** in the sidebar once ESP32-001 heartbeats arrive.

## One-time setup (needed for database storage)

1. **Register ESP32-001 with its owner.** `public.devices` must contain `device_id = 'ESP32-001'`
   with the homeowner's `user_id`. Check it with query 0 in
   `database/VERIFY_CAMERA_PTZ_MOTION_SUPABASE.sql`.
2. **Match the device key.** ESP32-001's `DEVICE_COMMAND_KEY` must equal the Supabase Edge
   Function secret `PYROGUARD_DEVICE_KEY`. By default it uses the same value as
   `DEVICE_INGEST_KEY`; if your secrets differ, put the `PYROGUARD_DEVICE_KEY` value there.
3. **Deploy `device-command`.** It is already in `supabase/functions` (`verify_jwt = false`):
   `supabase functions deploy device-command`
4. **Run the MySQL sync worker** on the laptop (`deployment/local-mysql-sync/start-sync.bat`).
   It already mirrors `event_history`, `device_heartbeats`,
   `pyroguard_camera_telemetry`, `ptz_state` and `ptz_commands`.

## Flashing (ESP32 board package 3.x)

- **ESP32-001**: `firmware/PyroGuard_ESP32_001_MultiSensor/…ino`
  - Board: ESP32 Dev Module.
  - Libraries: DHT sensor library, Adafruit Unified Sensor, ESP32Servo.
- **Camera 1**: `firmware/PyroGuard_Camera1_DFR1154/…ino`
  - Board: ESP32S3 Dev Module.
  - USB CDC On Boot: Enabled, PSRAM: OPI PSRAM, Flash: 16MB.

## Serial Monitor (115200) on ESP32-001

| Line | Meaning |
|---|---|
| `[CAMERA1] LINK OK` | Camera 1 and ESP32-001 are talking |
| `[AUTO] motion x=.. -> pan right 7 ...` | The servo is following motion |
| `[CLOUD] STORED reading #..` | Sensor readings saved |
| `[DB] STORED motion event in Supabase event_history` | Motion saved |
| `[DB] System records stored: N ok` | Heartbeat, camera and PTZ rows saved (logged every minute) |
| `[DB] ... 401` | The device key does not match `PYROGUARD_DEVICE_KEY` |
| `[DB] ... 404` | ESP32-001 is not registered in `devices` |
| `[DB] ... 409` | See the note at the end of the Supabase verify script |

## Test checklist

1. **Hardware connected:** within about 30 s of power-up the sidebar shows HARDWARE CONNECTED.
2. **Overlay:** Camera 1 shows LIVE video with the transparent PTZ overlay. Full screen works
   for both cameras.
3. **Motion and auto-follow:** walk in front of Camera 1. The badge shows MOTION and the camera
   turns toward you in smooth steps. Standing still, it stays still.
4. **Manual override:** press an arrow. The camera obeys and AUTO-FOLLOW shows PAUSED.
5. **Stored motion:** the Camera tab, "Stored motion events", shows the new row.
   It turns "MySQL synced" after the sync worker runs.
6. **Supabase:** run `database/VERIFY_CAMERA_PTZ_MOTION_SUPABASE.sql`. You should see a fresh
   heartbeat, camera status, servo position, motion events and your manual PTZ commands.
7. **MySQL:** run `database/VERIFY_CAMERA_PTZ_MOTION_MYSQL.sql`. You should see the same rows.
8. **Sensors:** flame, smoke, DHT22, door and window readings still update and store as before.

## Tuning (ESP32-001)

| Setting | Effect |
|---|---|
| `AUTO_FOLLOW_DEFAULT` | Follow motion after power-up |
| `AUTO_DEADBAND_X / _Y` | Larger = moves less often |
| `AUTO_GAIN`, `AUTO_MAX_STEP_DEG` | Larger = turns further per move |
| `AUTO_INVERT_PAN / _TILT` | Set true if the camera turns away from motion |
| `AUTO_MANUAL_HOLD_MS` | How long a manual press pauses auto-follow |
| `MOTION_EVENT_MIN_GAP_MS` | Minimum time between stored motion events (30 s) |
| `HEARTBEAT_INTERVAL_MS`, `CAMERA_TELEMETRY_INTERVAL_MS`, `PTZ_STATE_INTERVAL_MS` | How often status rows are stored |

## If the servos AND sensors stop working (ESP32-001)

When everything stops at once, the board is usually **restarting over and over**. The
servos pull the supply voltage down (a "brownout") and the ESP32 resets before the sensors,
Wi-Fi or cloud can run. The firmware now:

- **Prints why it last restarted:**
  - `[BOOT] reset_reason=… (BROWNOUT - supply voltage dropped)` means the power is too weak.
  - `CRASH (panic/watchdog)` means it crashed. Send the Serial log.
- **Protects the sensors after a brownout.** The servos stay off until the first PTZ
  command, so sensors, Wi-Fi and the cloud keep working.
- **Starts the servos gently.** It waits 3 s after boot (after the Wi-Fi start-up current),
  then attaches them one at a time. There is no automatic sweep at boot anymore.
- **Prints a health summary every 10 s:**

```
[HEALTH] uptime=… wifi=OK ip=… sensor_age=…
[HEALTH] sensors: dht=OK temp=… hum=… mq2=READY smoke=no flame=no door=closed window=closed
[HEALTH] servo: attached=OK pan=90/90 tilt=90/90 | cam1 link=OK motion=no auto=ON moves=…
[HEALTH] cloud: sensor ok=… fail=… | records ok=… fail=… | stack free link=… cloud=…
```

**Servo wiring (most important):**

| Wire | Connect to |
|---|---|
| Servo red (+) | Separate **5 V, 2 A** supply. **Not** the ESP32 3.3 V pin, and not the USB 5 V pin when both servos are used. |
| Servo brown/black (−) | Supply GND **and** ESP32 GND (common ground) |
| Signal | Pan → **GPIO13**, tilt → **GPIO14** |

A 470–1000 µF capacitor across the servo 5 V/GND near the servos also helps.

**Serial commands:**

| Command | Action |
|---|---|
| `servo` | Diagnostics |
| `servotest` / `st` | Sweep both servos |
| `l` / `r` / `up` / `down` / `c` | Move by hand |
| `link` | Camera 1 link state |
| `auto` / `manual` | Auto-follow on / off |

**Travel limits:** pan 40–140°, tilt 65–115° (`PAN_MIN/PAN_MAX/TILT_MIN/TILT_MAX`).

**If it turns the wrong way:** flip `RIGHT_DECREASES_ANGLE` / `UP_DECREASES_ANGLE` (buttons)
or `AUTO_INVERT_PAN` / `AUTO_INVERT_TILT` (auto-follow).

## Arm / Disarm and door/window open/close (no new registration)

This uses the **existing** ESP32-001 device, sensors and tables.

```
App (Device screen: DISARM / ARM HOME / ARM AWAY, door/window switches)
   -> Supabase system_state + device_commands            (already in the app)
ESP32-001 -> device-command "sync" every 4 s              (NEW in firmware)
   - applies ARMED/DISARMED and door/window protection on the board
   - acknowledges each command (applied/failed): SILENCE_SIREN, TEST_CHIRP, mode changes
   - stores ARMED / DISARMED confirmations in event_history
ESP32-001 -> event_history DOOR_OPEN / DOOR_CLOSED / WINDOW_OPEN / WINDOW_CLOSED (NEW)
   - severity 2 if opened while ARMED and protected (intrusion), 1 opened, 0 closed
MySQL sync worker mirrors event_history, system_state and device_commands (unchanged)
```

**In the app:** the **Door & Window Activity** panel on the Dashboard and Device screens
covers both batches. There are two reed switches per ESP32:

| Batch | Controller | Door switch | Window switch |
|---|---|---|---|
| 1 | ESP32-001 | **Entrance door** (GPIO33) | **Sala window** (GPIO32) |
| 2 | ESP32-002 | **Fire exit door** | **Bedroom window** |

- **Live state:** each switch shows OPEN or CLOSED, and whether the system was ARMED or
  DISARMED when it last changed.
- **History:** every opening and closing shows an **ARMED / DISARMED** chip, its batch and its
  MySQL mirror status. Opened while ARMED and protected is marked **INTRUSION**.
- **Notifications:** the owner is notified for every new opening, closing and arm change
  while the app is open (via the dashboard shell).
- **Names:** set in `lib/config/coverage_config.dart` (`_contactLabels`). On ESP32-001, also
  set `DOOR_LABEL` / `WINDOW_LABEL`.

**Both sensor sets on ESP32-001 are now enabled** (`ENABLE_SECOND_BATCH 1`):

| Sensor set | Room key | Sensors |
|---|---|---|
| Entrance | `sala` | DHT22 GPIO4, MQ-2 GPIO26, flame GPIO35, buzzer GPIO18 |
| Sala | `bedroom` | DHT22 GPIO16, MQ-2 GPIO19, flame GPIO21, buzzer GPIO22 |

**Only two steps:**
1. **Redeploy `device-command`** with `supabase functions deploy device-command`.
   One line changed: it now also accepts `DOOR_CLOSED` and `WINDOW_CLOSED`.
2. **Flash ESP32-001** with the new sketch.

**Check:** the app sends arm/disarm to the `device_id` in the account's metadata, and it
must be `ESP32-001`. Confirm with:
```sql
SELECT device_id, arm_mode, door_enabled, window_enabled, updated_at FROM public.system_state;
SELECT created_at, event_type, message, severity, mysql_synced FROM public.event_history
WHERE device_id = 'ESP32-001'
  AND event_type IN ('DOOR_OPEN','DOOR_CLOSED','WINDOW_OPEN','WINDOW_CLOSED','ARMED','DISARMED')
ORDER BY created_at DESC LIMIT 20;
```

**Serial Monitor:**
- `[SECURITY] Synced from app: ARM_AWAY (door protected, window protected)`
- `[SECURITY] System DISARMED from the app - confirmed by ESP32-001`
- `[DB] STORED DOOR_OPEN event in Supabase event_history`
- `[HEALTH] security: ARMED (ARM_AWAY) synced=yes door_protect=on window_protect=on intrusion=no`
