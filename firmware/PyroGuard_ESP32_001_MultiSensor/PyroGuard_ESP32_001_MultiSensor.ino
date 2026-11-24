/*
 * PyroGuard - Multi-Sensor + Door/Window + Buzzer Alerts (ESP32 WROOM-32)
 * ONE SKETCH FOR BOTH CONTROLLERS - set PYROGUARD_BATCH below:
 *   1 = ESP32-001  Entrance + Sala   (Camera 1 PTZ link enabled)
 *   2 = ESP32-002  Kitchen + Bedroom (no camera / PTZ on this board)
 * Both boards use the SAME pin map (see PINS).
 *
 * FALSE-FIRE GUARD (2026-11-04b):
 *   - A room is FIRE only when its smoke AND flame inputs are BOTH confirmed
 *     and stay on together for FIRE_CONFIRM_MS (5 s). Smoke in one room and a
 *     flame in the other room is never a fire.
 *   - A flame/smoke input that is already active at boot is not trusted until
 *     it has read CLEAR once (floating GPIO35 / mis-set comparator pot).
 *   - A flame input that flickers on/off very fast (electrical noise, loose
 *     wire, no pull-up) or stays on for minutes without any smoke is marked
 *     FLAME FAULT and ignored. A smoke input that never clears after warm-up
 *     is marked SMOKE FAULT. Faults are reported to the app as "check sensor",
 *     never as fire.
 *   - Serial "faults" shows the guard state, "faultreset" clears it.
 *
 * 2026-11-19 PIN MAP + DISPLAY UPDATE (matches the team's breadboard wiring):
 *   MQ-2 #1 AO GPIO34, MQ-2 #2 AO GPIO32 (analog, 10k/20k divider; DO unused)
 *   Flame #1 GPIO35, Flame #2 GPIO33, DHT22 GPIO4 / GPIO16
 *   Door reed GPIO25, Window reed GPIO26 (NC -> GPIO26, COM -> GND)
 *   4 active buzzers GPIO18/19/21/22 - all four always sound together
 *   Pan servo GPIO13, Tilt servo GPIO27 (servos run only when PYROGUARD_BATCH 1)
 *   Serial Monitor: one clean status table every 5 s (type d to show it now);
 *   noisy raw logs are off (set VERBOSE_RAW_LOGS true to see them again).
 *
 * DOOR / WINDOW: "contacts" shows raw pins; if one reads backwards type
 *   "door invert" or "window invert" - saved in flash, no re-upload needed.
 * Board  : ESP32 Dev Module | Serial Monitor: 115200, "Both NL & CR"
 * Sensors: MQ-2 smoke (AO, analog), IR flame (DO), DHT22, Reed switches (door, window)
 * Outputs: Pan GPIO 13, Tilt GPIO 27, 4 active buzzers GPIO 18/19/21/22
 *
 * BATCH 1 coverage (ESP32-001 + Camera 1):
 *   first sensor set  -> "Entrance"  (cloud room_key "entrance")
 *   second sensor set -> "Sala"      (cloud room_key "sala")
 *
 * OPTIONAL legacy automatic motion-following: disabled by default.
 *   - 4x per second ESP32-001 calls Camera 1 GET /link (key-protected),
 *     reports its IP/servo angles and reads where Camera 1 sees motion;
 *   - when Camera 1 confirms motion away from the picture centre, ESP32-001
 *     turns the servos toward it with a dead-band, proportional steps,
 *     step/speed limits and a settle pause (no shaking, no chasing itself);
 *   - Camera 1 ignores motion while the servos move, so the camera never
 *     follows its own movement.
 * MANUAL PTZ always wins: the app sends buttons to Camera 1 POST /ptz, Camera 1
 *   relays them to POST /ptz here, and auto-follow pauses for AUTO_MANUAL_HOLD_MS.
 *   The app can switch auto-follow on/off (actions auto_on / auto_off).
 * No PC, laptop or Python script is needed.
 *
 * Libraries: "DHT sensor library" + "Adafruit Unified Sensor" (Adafruit), "ESP32Servo"
 *
 * BUZZER TEST - type a sensor name to hear its sound:
 *   fire, intrusion, flame, smoke, temp  -> repeat until "stop"
 *   door, window, closed, startup        -> play once
 *   stop                                 -> stop the sound
 *
 * Other commands:
 *   m  or mute                -> silence the current alarm
 *   t  or test                -> play every alert sound once
 *   a  or arm                 -> arm / disarm intrusion alert
 *   50right / right 50 / r50  -> turn 50 degrees to the right
 *   50left  / left 50  / l50  -> turn 50 degrees to the left
 *   c  or center              -> face straight ahead
 *   s  or sweep               -> full left-right test
 *   p  or pos                 -> show current position
 *   x  or halt                -> stop the servos where they are
 *   auto / manual             -> auto-follow on / off
 *   link                      -> show the Camera 1 link state
 *   q  or quiet               -> pause/resume sensor printing
 */

#include <DHT.h>
#include <ESP32Servo.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>
#include <esp_system.h>
#include <Preferences.h>
#include <ESPmDNS.h>

// ================== WHICH CONTROLLER IS THIS? ==================
#ifndef PYROGUARD_BATCH
#define PYROGUARD_BATCH 1      // 1 = ESP32-001 (Entrance + Sala), 2 = ESP32-002 (Kitchen + Bedroom)
#endif
#define FIRMWARE_VERSION "2026-11-23-v16"

#if PYROGUARD_BATCH == 2
  #define BATCH_DEVICE_ID        "ESP32-002"
  #define BATCH_ROOM1_KEY        "kitchen"
  #define BATCH_ROOM2_KEY        "bedroom"
  #define PRIMARY_COVERAGE_NAME  "Kitchen"
  #define SECOND_COVERAGE_NAME   "Bedroom"
  #define DOOR_LABEL             "Fire exit door"
  #define WINDOW_LABEL           "Bedroom window"
  #define BATCH_HAS_CAMERA_PTZ   false   // no camera on this board (Camera 1 is on ESP32-001)
  #define BATCH_NAME             "Batch 2"
#else
  #define BATCH_DEVICE_ID        "ESP32-001"
  #define BATCH_ROOM1_KEY        "entrance"
  #define BATCH_ROOM2_KEY        "sala"
  #define PRIMARY_COVERAGE_NAME  "Entrance"
  #define SECOND_COVERAGE_NAME   "Sala"
  #define DOOR_LABEL             "Entrance door"
  #define WINDOW_LABEL           "Sala window"
  #define BATCH_HAS_CAMERA_PTZ   true
  #define BATCH_NAME             "Batch 1"
#endif

// ================== DEMO / TESTING SENSITIVITY ==================
// true  = small-lighter demo: a lit lighter flame alone becomes FIRE after
//         ~2 s, a puff of UNLIT lighter gas raises GAS DETECTED, heat alarm
//         at 38 C, and the MQ-2 warm-up is 60 s instead of 3 min.
// false = normal false-fire guard (smoke AND flame together for 5 s, 45 C).
// Set back to false after the demo.
#define DEMO_SENSITIVE_MODE    true

// ================== FALSE-FIRE GUARD ==================
#if DEMO_SENSITIVE_MODE
  #define FIRE_CONFIRM_MS      2000UL   // demo: confirmed fire after 2 s
  #define DEMO_FLAME_ALONE_IS_FIRE true // demo: lighter flame counts without smoke
#else
  #define FIRE_CONFIRM_MS      5000UL   // smoke + flame must stay on TOGETHER this long
  #define DEMO_FLAME_ALONE_IS_FIRE false
#endif
#define INPUT_TRUST_CLEAR_MS   2000UL   // input must read CLEAR this long once before it is trusted
#define FLAME_CHATTER_WINDOW_MS 10000UL // flicker counting window
#if DEMO_SENSITIVE_MODE
  #define FLAME_CHATTER_MAX    200      // demo: a flickering lighter flame is not "noise"
#else
  #define FLAME_CHATTER_MAX    16       // more raw changes than this per window = noise -> FAULT
#endif
// A flame flickers, so the sensor output blinks. Treat it as still ON for
// this long after the last ON blink (otherwise confirmation keeps restarting).
#define FLAME_FLICKER_BRIDGE_MS 400UL
// Flame / smoke stay reported to the app at least this long after they
// clear, so even a 1-second lighter test reaches the dashboard.
#define HAZARD_REPORT_HOLD_MS  6000UL
#define FLAME_FAULT_HOLD_MS    60000UL  // keep a chatter fault at least this long
#define FLAME_STUCK_MS         120000UL // flame ON this long with NO smoke in that room -> FAULT
#define SMOKE_NEVER_CLEAR_MS   60000UL  // after warm-up, smoke must clear once within this time

// ================== PINS ==================
#define DHT_PIN      4   // DHT22 DATA
#define MQ2_AO_PIN   34   // MQ-2 #1 AO -> 10k -> GPIO34 -> 20k -> GND (analog smoke level)
#define MQ2_DO_PIN   MQ2_AO_PIN   // legacy name; smoke is now read from AO
#define FLAME_PIN    35   // CONFIRMED: first-batch flame DO; GPIO35 is INPUT-ONLY, no internal pull-up
#define PAN_PIN      13   // Pan servo signal
#define TILT_PIN     27   // Tilt servo signal
#define DOOR_PIN     25   // Door reed switch signal, other wire to GND
#define WINDOW_PIN   26   // Window reed switch NC, COM to GND
#define BUZZER_PIN   18   // Active buzzer 1
#define BUZZER_PIN_B 19   // Active buzzer 2 (same sound)
#define DHT_TYPE     DHT22

// ========== SECOND SENSOR SET (BATCH 1 "SALA") - CONNECT LATER ==========
// The second room uses its real Supabase room key: sala. Historical data stays unchanged.
// Set ENABLE_SECOND_BATCH true ONLY after all sensors are wired and checked.
// GPIOs selected to avoid all currently assigned first-batch/PTZ pins.
// If your ESP32 board uses these pins for other hardware, change them first.
#define ENABLE_SECOND_BATCH 1  // Both sensor sets on this ESP32 are installed (Entrance + Sala)
#define DHT2_PIN       16    // Second-set DHT22; GPIO18 is already used by first buzzer
#define MQ2_2_AO_PIN   32    // Second MQ-2 AO -> 10k -> GPIO32 -> 20k -> GND (analog)
#define MQ2_2_DO_PIN   MQ2_2_AO_PIN   // legacy name; smoke is now read from AO
#define FLAME2_PIN     33    // Second flame sensor DO
#define BUZZER2_PIN_B  21    // Active buzzer 3 (same sound)
#define BUZZER2_PIN    22    // Active buzzer 4 (same sound)
#define SECOND_ROOM_KEY BATCH_ROOM2_KEY   // database key (sala on ESP32-001, bedroom on ESP32-002)


// ================== OPTIONS ==================
#define USE_WINDOW        true    // window reed switch is installed on GPIO 26
// Names shown to the owner for the two reed switches on THIS controller.
// (ESP32-002 uses "Fire exit door" and "Bedroom window" in the app.)
// DOOR_LABEL / WINDOW_LABEL are set per batch at the top of the sketch.
#define CONTACT_REVERSED  false   // legacy default; overridden independently below
// Door reed switch (both batches), same as the window:
// magnet NEAR (door shut) = CLOSED, magnet FAR (door open) = OPEN.
// If a door reads backwards, type "doorinvert" in Serial (saved, no re-upload).
#define DOOR_CONTACT_REVERSED true  // GPIO25: LOW = OPEN, HIGH = CLOSED
#define WINDOW_CONTACT_REVERSED true  // GPIO26: LOW = OPEN, HIGH = CLOSED. Serial "window invert" flips it
// IR flame modules often output LOW on detection, but check your module's DO polarity.
#define FLAME_ACTIVE_LOW true  // Common LM393 flame modules: LOW on flame; change only if RAW proves opposite
#if DEMO_SENSITIVE_MODE
  #define FLAME_CONFIRM_MS 600UL  // demo: lighter flame registers in ~0.6 s
#else
  #define FLAME_CONFIRM_MS 1500UL // Confirm sustained Entrance flame signal; does NOT hide stuck-active inputs
#endif
#define FLAME_CLEAR_MS 350  // prevent noisy transitions from clearing an alert instantly
#define SMOKE_CONFIRM_MS 250 // DO signal must stay active to suppress single-sample glitches
#define SMOKE_CLEAR_MS 500
#define FLAME_RAW_LOG_MS 2000 // Print the raw GPIO reading even when detection state does not change
#define FLAME2_ACTIVE_LOW true
#if DEMO_SENSITIVE_MODE
  #define FLAME2_CONFIRM_MS 600UL  // demo
#else
  #define FLAME2_CONFIRM_MS 1200UL // Reject brief infrared/electrical spikes; sustained alarms remain actionable
#endif
#define FLAME2_CLEAR_MS 700UL
#define SMOKE2_ACTIVE_LOW true  // Confirm using the raw digital output of the physical Sala MQ-2 module
#define SMOKE2_CONFIRM_MS 1500UL // Debounce Sala smoke DO independently (previously every 2 seconds)
#define SMOKE2_CLEAR_MS 700UL
#define SALA_RAW_LOG_MS 2000UL   // Print both digital pins even when unchanged
#define BUZZER_ACTIVE_LOW false   // set true if the buzzer is ON when it should be OFF

// ===== OPTIONAL LOCAL-WIFI PTZ CONTROL =====
// Keep disabled for safe USB testing. To enable LAN control, enter
// credentials and a long random device key, then set ENABLE_WIFI true.
// Do NOT put a Supabase service_role key into firmware.
#define ENABLE_WIFI true

// Single source of truth for controller and first room. Do not redeclare below.
const char* DEVICE_ID = BATCH_DEVICE_ID;
const char* ROOM_KEY = BATCH_ROOM1_KEY;

const char* WIFI_SSID = "Pyroguard_Team";
const char* WIFI_PASSWORD = "Pyroguard4";
const char* SUPABASE_INGEST_URL =
    "https://gljzunjbmmsbkayxtyfc.supabase.co/functions/v1/sensor-ingest";
// System records (heartbeat, camera status, servo position, motion events) go
// to the existing "device-command" Edge Function, which stores them in Supabase
// tables that the local MySQL sync worker already mirrors.
const char* DEVICE_COMMAND_URL =
    "https://gljzunjbmmsbkayxtyfc.supabase.co/functions/v1/device-command";
const char* DEVICE_HTTP_KEY = "BE16B76655384080D1C3D15AE03CAC962DE1BBC4924BD5AC687C7144421A7A10";
const char* DEVICE_INGEST_KEY =
    "ed9013b82a5fac0e6de7781337d293bf17b5be2bb5698ef8d18f0041978034a2";
// device-command checks the Supabase secret PYROGUARD_DEVICE_KEY. By default
// the same 64-hex key as DEVICE_INGEST_KEY is used; if your secrets differ,
// replace this with the PYROGUARD_DEVICE_KEY value.
#define DEVICE_COMMAND_KEY DEVICE_INGEST_KEY
#define ENABLE_SUPABASE_UPLOAD true
#define ENABLE_PTZ_SERVOS BATCH_HAS_CAMERA_PTZ   // servos only on the Camera 1 controller
#define ENABLE_CLOUD_DIAGNOSTICS true
#define CLOUD_MIN_FREE_HEAP 30000U
#define ENABLE_LOCAL_API true // status and protected PTZ plus unauthenticated minimal /health

// ----- Camera 1 <-> ESP32-001 direct LAN link -----
// Camera 1 gets its address from the router (any Wi-Fi). ESP32-001 finds it by
// its network name "pyroguard-cam1" (mDNS); the last address found is saved.
#define CAMERA1_DEFAULT_HOST "192.168.8.99"   // first guess only
#define CAMERA1_MDNS_NAME "pyroguard-cam1"
#define ENABLE_CAMERA1_LINK BATCH_HAS_CAMERA_PTZ  // report IP/servo position, read motion
#define CAMERA1_LINK_INTERVAL_MS 250UL    // 4x per second for responsive following
#define CAMERA1_LINK_TIMEOUT_MS 700

// ----- Automatic motion-following (decided here, on the main controller) -----
#define AUTO_FOLLOW_DEFAULT true           // follow Camera 1 motion after boot (app/Serial choice is saved)
#define CAMERA_HFOV_DEG 100.0f            // usable horizontal view of the 160-degree lens
#define CAMERA_VFOV_DEG 75.0f             // usable vertical view
#define AUTO_GAIN 0.5f                    // correct half the error per move: smooth, no overshoot
#define AUTO_DEADBAND_X 0.12f             // ignore motion within 12% of centre (left/right)
#define AUTO_DEADBAND_Y 0.15f             // ignore motion within 15% of centre (up/down)
#define AUTO_MIN_STEP_DEG 2               // smallest automatic move
#define AUTO_MAX_STEP_DEG 12              // largest automatic move per decision
#define AUTO_SERVO_STEP_MS 25UL           // slower sweep during auto moves (~40 deg/s)
#define AUTO_SETTLE_MS 450UL              // pause after a move before trusting new motion
#define AUTO_MANUAL_HOLD_MS 20000UL       // a manual command pauses auto-follow this long
#define AUTO_HOME_AFTER_IDLE_MS 0UL       // 0 = stay; e.g. 60000 = re-centre after 60 s idle
#define AUTO_INVERT_PAN false             // set true if auto turns AWAY from motion (left/right)
#define AUTO_INVERT_TILT false            // set true if auto tilts AWAY from motion (up/down)
// Camera motion is reported in /status and the Serial Monitor only.
// Set true ONLY if Camera 1 motion should also raise INTRUSION while ARMED.
#define CAMERA1_MOTION_TRIGGERS_INTRUSION false
#define CAMERA1_MOTION_TIMEOUT_MS 10000UL
#define CAMERA1_DEVICE_ID "pyroguard_camera_001"

// ----- Supabase system records (mirrored to MySQL by the sync worker) -----
#define ENABLE_SYSTEM_RECORDS true
#define HEARTBEAT_INTERVAL_MS 20000UL        // device_heartbeats   (app: HARDWARE CONNECTED)
#define CAMERA_TELEMETRY_INTERVAL_MS 15000UL // pyroguard_camera_telemetry (Camera 1 status)
#define PTZ_STATE_INTERVAL_MS 15000UL        // ptz_state (servo position), also after moves
#define MOTION_EVENT_MIN_GAP_MS 30000UL      // event_history MOTION rows, at most 1 per 30 s

// ----- Arm / disarm from the app + door/window open/close records -----
// Uses the EXISTING device and tables (no new registration):
//   device-command "sync"  -> system_state (arm_mode, door/window/motion
//                             protection) + pending device_commands
//   device-command "ack"   -> marks each command applied/failed
//   device-command "record_event" -> event_history DOOR_OPEN / DOOR_CLOSED /
//                             WINDOW_OPEN / WINDOW_CLOSED / ARMED / DISARMED
#define ENABLE_SECURITY_SYNC true
#define SECURITY_SYNC_INTERVAL_MS 2000UL     // how fast app arm/disarm reaches the board (fair queue: other uploads still get turns)
#define ENABLE_DOOR_WINDOW_EVENTS true
#define CONTACT_EVENT_MIN_GAP_MS 2000UL      // ignore open/close chatter faster than this
#define CLOUD_INTERVAL_MS 4000UL  // routine upload period (changes are still sent at once)
#define CLOUD_URGENT_GAP_MS 600UL // a state change (door, smoke, flame, arm...) is sent after at most this gap
#define CLOUD_TIMEOUT_MS 3500
#define MAX_SENSOR_AGE_MS 4500UL  // Refuse stale DHT22 readings
static const char SUPABASE_CA_ROOTS[] = R"PEM(
-----BEGIN CERTIFICATE-----
MIIFVzCCAz+gAwIBAgINAgPlk28xsBNJiGuiFzANBgkqhkiG9w0BAQwFADBHMQsw
CQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEU
MBIGA1UEAxMLR1RTIFJvb3QgUjEwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAw
MDAwWjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZp
Y2VzIExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjEwggIiMA0GCSqGSIb3DQEBAQUA
A4ICDwAwggIKAoICAQC2EQKLHuOhd5s73L+UPreVp0A8of2C+X0yBoJx9vaMf/vo
27xqLpeXo4xL+Sv2sfnOhB2x+cWX3u+58qPpvBKJXqeqUqv4IyfLpLGcY9vXmX7w
Cl7raKb0xlpHDU0QM+NOsROjyBhsS+z8CZDfnWQpJSMHobTSPS5g4M/SCYe7zUjw
TcLCeoiKu7rPWRnWr4+wB7CeMfGCwcDfLqZtbBkOtdh+JhpFAz2weaSUKK0Pfybl
qAj+lug8aJRT7oM6iCsVlgmy4HqMLnXWnOunVmSPlk9orj2XwoSPwLxAwAtcvfaH
szVsrBhQf4TgTM2S0yDpM7xSma8ytSmzJSq0SPly4cpk9+aCEI3oncKKiPo4Zor8
Y/kB+Xj9e1x3+naH+uzfsQ55lVe0vSbv1gHR6xYKu44LtcXFilWr06zqkUspzBmk
MiVOKvFlRNACzqrOSbTqn3yDsEB750Orp2yjj32JgfpMpf/VjsPOS+C12LOORc92
wO1AK/1TD7Cn1TsNsYqiA94xrcx36m97PtbfkSIS5r762DL8EGMUUXLeXdYWk70p
aDPvOmbsB4om3xPXV2V4J95eSRQAogB/mqghtqmxlbCluQ0WEdrHbEg8QOB+DVrN
VjzRlwW5y0vtOUucxD/SVRNuJLDWcfr0wbrM7Rv1/oFB2ACYPTrIrnqYNxgFlQID
AQABo0IwQDAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4E
FgQU5K8rJnEaK0gnhS9SZizv8IkTcT4wDQYJKoZIhvcNAQEMBQADggIBAJ+qQibb
C5u+/x6Wki4+omVKapi6Ist9wTrYggoGxval3sBOh2Z5ofmmWJyq+bXmYOfg6LEe
QkEzCzc9zolwFcq1JKjPa7XSQCGYzyI0zzvFIoTgxQ6KfF2I5DUkzps+GlQebtuy
h6f88/qBVRRiClmpIgUxPoLW7ttXNLwzldMXG+gnoot7TiYaelpkttGsN/H9oPM4
7HLwEXWdyzRSjeZ2axfG34arJ45JK3VmgRAhpuo+9K4l/3wV3s6MJT/KYnAK9y8J
ZgfIPxz88NtFMN9iiMG1D53Dn0reWVlHxYciNuaCp+0KueIHoI17eko8cdLiA6Ef
MgfdG+RCzgwARWGAtQsgWSl4vflVy2PFPEz0tv/bal8xa5meLMFrUKTX5hgUvYU/
Z6tGn6D/Qqc6f1zLXbBwHSs09dR2CQzreExZBfMzQsNhFRAbd03OIozUhfJFfbdT
6u9AWpQKXCBfTkBdYiJ23//OYb2MI3jSNwLgjt7RETeJ9r/tSQdirpLsQBqvFAnZ
0E6yove+7u7Y/9waLd64NnHi/Hm3lCXRSHNboTXns5lndcEZOitHTtNCjv0xyBZm
2tIMPNuzjsmhDYAPexZ3FL//2wmUspO8IFgV6dtxQ/PeEMMA3KgqlbbC1j+Qa3bb
bP6MvPJwNQzcmRk13NfIRmPVNnGuV/u3gm3c
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIICCTCCAY6gAwIBAgINAgPlwGjvYxqccpBQUjAKBggqhkjOPQQDAzBHMQswCQYD
VQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2VzIExMQzEUMBIG
A1UEAxMLR1RTIFJvb3QgUjQwHhcNMTYwNjIyMDAwMDAwWhcNMzYwNjIyMDAwMDAw
WjBHMQswCQYDVQQGEwJVUzEiMCAGA1UEChMZR29vZ2xlIFRydXN0IFNlcnZpY2Vz
IExMQzEUMBIGA1UEAxMLR1RTIFJvb3QgUjQwdjAQBgcqhkjOPQIBBgUrgQQAIgNi
AATzdHOnaItgrkO4NcWBMHtLSZ37wWHO5t5GvWvVYRg1rkDdc/eJkTBa6zzuhXyi
QHY7qca4R9gq55KRanPpsXI5nymfopjTX15YhmUPoYRlBtHci8nHc8iMai/lxKvR
HYqjQjBAMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQW
BBSATNbrdP9JNqPV2Py1PsVq8JQdjDAKBggqhkjOPQQDAwNpADBmAjEA6ED/g94D
9J+uHXqnLrmvT/aDHQ4thQEd0dlq7A/Cr8deVl5c1RxYIigL9zC2L7F8AjEA8GE8
p/SgguMh1YQdc4acLa/KNJvxn7kjNuK8YAOdgLOaVsjh4rsUecrNIdSUtUlD
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
)PEM";
unsigned long lastCloudAttempt = 0;
TaskHandle_t cloudTaskHandle = nullptr;           // HTTPS worker task
// Security state received from the app through Supabase system_state.
String armMode = "DISARMED";                       // DISARMED / ARM_HOME / ARM_AWAY
bool doorProtection = true;                        // door opening triggers intrusion when armed
bool windowProtection = true;                      // window opening triggers intrusion when armed
bool motionProtection = true;                      // Camera 1 motion may trigger intrusion when armed
bool securitySynced = false;                       // first sync after boot received
volatile bool syncResponseReady = false;
String syncResponse;                               // filled by the cloud worker, parsed in loop()
unsigned long systemRecordOk = 0, systemRecordFailed = 0;
// Cloud job types/slots (declared early so Arduino's generated prototypes see them).
enum CloudJob : int8_t { JOB_NONE = -1, JOB_EVENT, JOB_SENSOR, JOB_SYNC, JOB_HEARTBEAT, JOB_PTZ, JOB_CAMERA };
struct CloudSlot {
  String body;
  bool pending = false;
  unsigned long queuedAt = 0;
  unsigned long sampleAt = 0;
};
bool cloudKeyValid = false;
unsigned long cloudUploadSuccesses = 0;
unsigned long cloudUploadFailures = 0;

WebServer webServer(80);
unsigned long lastWifiAttempt = 0;
bool webStarted = false;
bool wifiConfigValid = false;

// ----- Wi-Fi on any network -----
// Up to 3 networks are saved on the board (newest first) plus WIFI_SSID above.
// No saved network reachable for 30 s -> the board opens its own setup hotspot
// "PyroGuard-<ID>-Setup" (password below). Connect a phone to it and open
// http://192.168.4.1 to choose the new Wi-Fi. Alarms keep working meanwhile.
#define WIFI_MAX_SAVED 3
#define WIFI_PORTAL_AFTER_MS 30000UL
#define WIFI_SETUP_PASSWORD "pyroguard123"
String wifiSsids[WIFI_MAX_SAVED + 1];
String wifiPasses[WIFI_MAX_SAVED + 1];
int wifiNetCount = 0;
int wifiNetIndex = 0;
bool wifiPortalActive = false;
unsigned long wifiLastOkMs = 0;
unsigned long wifiConnectedSince = 0;
bool mdnsStarted = false;
portMUX_TYPE camHostMux = portMUX_INITIALIZER_UNLOCKED;
char camera1HostBuf[40] = CAMERA1_DEFAULT_HOST;
volatile bool camHostDirty = false;

// ================== SENSOR SETTINGS ==================
#if DEMO_SENSITIVE_MODE
  #define TEMP_THRESHOLD 38.0    // °C demo: lighter held near the DHT22 for a few seconds
  #define MQ2_WARMUP_MS  60000   // demo: 1 minute heater warm-up
#else
  #define TEMP_THRESHOLD 45.0    // °C (lighter / nearby flame test)
  #define MQ2_WARMUP_MS  180000  // 3 minute heater warm-up
#endif
#define READ_INTERVAL    2000    // DHT22 needs at least 2 s between reads
#define CONTACT_DEBOUNCE 80      // ms - switch must be steady this long (stops flicker)

// ================== SERIAL MONITOR DISPLAY ==================
#define DASHBOARD_INTERVAL_MS 3000UL  // clean status table period ("d" = show now); also printed on any change
#define HEALTH_INTERVAL_MS    60000UL // [HEALTH] block period
#define VERBOSE_RAW_LOGS      false   // true = old raw GPIO / every-upload logs

// ================== MQ-2 ANALOG (AO) ==================
// AO is read through a 10k/20k divider. Smoke = this many mV above the
// clean-air baseline that is learned during the 3-minute warm-up.
#if DEMO_SENSITIVE_MODE
  #define MQ2_TRIGGER_MV 80      // demo: a small puff of lighter gas is enough
  #define MQ2_RELEASE_MV 50      // clears below this (hysteresis)
#else
  #define MQ2_TRIGGER_MV 150     // ~5 % of range: lighter gas / paper smoke
  #define MQ2_RELEASE_MV 100     // clears below this (hysteresis)
#endif
#define MQ2_TRACK_RATE   0.0005f
// The GPIO may carry the module's AO (analog) OR its DO (digital) pin; the
// firmware decides at the end of warm-up from the clean-air reading:
//   above MQ2_DO_DETECT_MV  -> DO wiring: gas = output pulled LOW
//   below MQ2_NO_SIGNAL_MV  -> AO reads ~0 V: NO SIGNAL (reported to the app)
#define MQ2_DO_DETECT_MV 2200    // DO idles HIGH (~3.1 V through the divider)
#define MQ2_DO_LOW_MV    1000    // DO below this = gas
#define MQ2_DO_HIGH_MV   1800    // DO above this = clear again
#define MQ2_NO_SIGNAL_MV 155     // ESP32 shows ~140 mV for 0 V; clean air on these modules is ~170 mV
float mq2Ema[2]  = {0, 0};      // smoothed mV (room 1, room 2)
float mq2Base[2] = {0, 0};      // clean-air baseline mV
bool  mq2Active[2] = {false, false};
bool  mq2ModeSet[2] = {false, false};
bool  mq2DigitalMode[2] = {false, false};  // true = DO wired to the GPIO
bool  mq2NoSignal[2] = {false, false};     // AO stuck at 0 V (wire / 5 V supply)
unsigned long mq2SignalSince[2] = {0, 0};  // when a "no signal" sensor got a real voltage


void printDashboard(bool force);

// ================== SERVO SETTINGS ==================
// Travel limits. The old 65..115 limits allowed only 2-3 button presses per
// side, so the camera seemed to "stop working" at the edge. If your bracket
// or cable hits something, narrow these again.
#define PAN_MIN    40
#define PAN_MAX    140
#define PAN_CENTER 90
#define RIGHT_DECREASES_ANGLE true   // change to false if "right" turns left
#define TILT_MIN 65
#define TILT_MAX 115
#define TILT_CENTER 90
#define UP_DECREASES_ANGLE true
#define SERVO_STEP_MS 15        // 1 degree per step -> smooth ~66 deg/s sweep
#define PTZ_JOG_DEG 10          // one button press
#define PTZ_MAX_JOG_DEG 30      // largest jog accepted from the LAN API
// Micro-servos can buzz/shake while holding a position (noisy supply, cheap
// gears). Set true to release the PWM signal once a move has finished; the
// camera then holds by gear friction and the servo stops jittering.
#define SERVO_RELEASE_WHEN_IDLE false
// At power-up both servos sweep once (pan left/right, tilt up/down, back to
// centre) so you can SEE that wiring and power are OK. Serial: "servotest".
// OFF by default: two servos sweeping while Wi-Fi starts can pull the supply
// down (brownout reset loop = sensors, Wi-Fi and servos all "dead").
// Use the Serial command "servotest" instead.
#define SERVO_BOOT_SELF_TEST false
#define SERVO_SELF_TEST_DEG 20
// Servos are attached a few seconds after boot (after the Wi-Fi radio has
// started) and one at a time, so their start-up current does not add to the
// Wi-Fi current spike.
#define SERVO_ATTACH_DELAY_MS 3000UL
#define SERVO_IDLE_RELEASE_MS 900UL

// ================== BUZZER PATTERNS ==================
// Durations in ms, alternating ON, OFF, ON, OFF...
const uint16_t P_FIRE[]      = {500, 500, 500, 500, 500, 1500};
const uint16_t P_INTRUSION[] = {100, 80};
const uint16_t P_FLAME[]     = {60, 60, 60, 60, 60, 60, 60, 60, 60, 1000};
const uint16_t P_SMOKE[]     = {200, 200, 200, 200, 200, 1500};
const uint16_t P_TEMP[]      = {800, 2200};
const uint16_t P_DOOR_OPEN[] = {100, 100, 100, 100};
const uint16_t P_WIN_OPEN[]  = {400, 100, 100, 100};
const uint16_t P_CLOSED[]    = {60, 60};
const uint16_t P_ARM[]       = {80, 80, 80, 80, 80, 80};
const uint16_t P_DISARM[]    = {400, 100};
const uint16_t P_STARTUP[]   = {80, 80, 80, 80, 250, 100};

#define PAT(p) p, (uint8_t)(sizeof(p) / sizeof(p[0]))

// ================== DOOR / WINDOW TYPE (must be above all functions) ==================
struct Contact {
  uint8_t pin;
  const char* name;
  bool enabled;
  bool open;
  bool lastReading;
  unsigned long lastChange;
};

Contact door   = { DOOR_PIN,   "DOOR",   true,       false, false, 0 };
Contact window = { WINDOW_PIN, "WINDOW", USE_WINDOW, false, false, 0 };

// ================== BUZZER TEST SOUND TYPE ==================
struct Sound {
  const char* name;
  const uint16_t* p;
  uint8_t len;
  bool loop;
};

const Sound SOUNDS[] = {
  { "fire",      PAT(P_FIRE),      true  },
  { "intrusion", PAT(P_INTRUSION), true  },
  { "flame",     PAT(P_FLAME),     true  },
  { "smoke",     PAT(P_SMOKE),     true  },
  { "temp",      PAT(P_TEMP),      true  },
  { "door",      PAT(P_DOOR_OPEN), false },
  { "window",    PAT(P_WIN_OPEN),  false },
  { "closed",    PAT(P_CLOSED),    false },
  { "startup",   PAT(P_STARTUP),   false },
};
const int SOUND_COUNT = sizeof(SOUNDS) / sizeof(SOUNDS[0]);

// ================== ALARM TYPE ==================
enum Alarm { A_NONE, A_TEMP, A_SMOKE, A_FLAME, A_INTRUSION, A_FIRE };
const char* ALARM_NAMES[] = {"none", "HIGH TEMP", "SMOKE", "FLAME", "INTRUSION", "FIRE"};

// ================== GLOBAL OBJECTS / STATE ==================
DHT dht(DHT_PIN, DHT_TYPE);
DHT dht2(DHT2_PIN, DHT_TYPE);
float lastTemp2 = NAN, lastHum2 = NAN;
bool dht2Valid = false;
bool mq2WarmedUp2 = false;
bool smokeNow2 = false, flameNow2 = false, tempNow2 = false, fireNow2 = false;
bool smoke2Candidate = false;
unsigned long smoke2CandidateSince = 0;
unsigned long lastSmoke2Sample = 0;
unsigned long lastSalaRawLog = 0;
// Sala flame comparator is also debounced; never treat one noisy sample as fire.
bool flame2Candidate = false;
unsigned long flame2CandidateSince = 0;
unsigned long lastFlame2Diagnostic = 0;
unsigned long lastSensorSample2 = 0;
// Separate room buzzer pattern using non-blocking timing.
const uint16_t* pat2 = nullptr;
uint8_t patLen2 = 0, patIdx2 = 0;
bool patLoop2 = false;
unsigned long patStepStart2 = 0;

Servo panServo;
Servo tiltServo;

unsigned long lastRead = 0;
int currentAngle = PAN_CENTER;
int targetPan = PAN_CENTER;
int currentTilt = TILT_CENTER;
int targetTilt = TILT_CENTER;
unsigned long lastServoStep = 0;
unsigned long lastServoMotionMs = 0;
bool servosAttached = false;
bool panServoOk = false;    // ESP32Servo confirmed the PWM output on GPIO13
bool servoPowerSafe = false; // last reset was a brownout: attach only on first move
bool tiltServoOk = false;   // ESP32Servo confirmed the PWM output on GPIO27
TaskHandle_t cameraLinkTaskHandle = nullptr;
// 2026-11-19: set by loop() when a fire/intrusion starts; the link task asks
// Camera 1 for an evidence photo (uploaded to Supabase, attached to the alert e-mail).
volatile uint8_t cameraSnapshotRequest = 0;   // 0 none, 1 fire, 2 intrusion
volatile unsigned long lastCamera1HttpOkMs = 0;
volatile unsigned long lastCamera1MotionMs = 0;
volatile bool camera1MotionDetected = false;
volatile bool camera1LinkAccepted = false;   // Camera 1 accepted our key + IP
volatile bool camera1MotionEvent = false;    // rising edge, handled in loop()
volatile int camera1LastHttpStatus = 0;
volatile bool camera1Settling = false;       // camera ignores motion while servos move
volatile int camera1Rssi = 0;                // Camera 1 Wi-Fi signal (from /link)
volatile uint32_t camera1UptimeMs = 0;
volatile uint32_t camera1ChangedSamples = 0; // size of the moving area (grid samples)
volatile bool autoFollowEnabled = AUTO_FOLLOW_DEFAULT;
volatile bool ptzStateDirty = false;          // send ptz_state soon (auto-follow toggled)
unsigned long manualOverrideUntil = 0;       // auto-follow paused until this time
bool autoMoveContext = false;                // true while auto-follow issues a move
bool autoMoveActive = false;                 // current servo move came from auto-follow
unsigned long lastAutoTrackMs = 0;
uint32_t autoMoveCount = 0;
portMUX_TYPE autoMux = portMUX_INITIALIZER_UNLOCKED;
bool autoRequestPending = false;             // written by link task, consumed in loop()
float autoRequestX = 0.5f, autoRequestY = 0.5f;
volatile float camera1MotionX = 0.5f;
volatile float camera1MotionY = 0.5f;
float lastTemp = NAN, lastHum = NAN;
bool dhtValid = false, mq2WarmedUp = false;
unsigned long lastSensorSample = 0;
bool quietMode    = false;
bool armed        = false;

Alarm activeAlarm = A_NONE;
bool  muted = false;
bool  fireNow = false, smokeNow = false, flameNow = false, tempNow = false;
bool flameCandidate = false;
bool smokeCandidate = false;
unsigned long smokeCandidateSince = 0;
unsigned long lastSmokeSample = 0;
unsigned long flameCandidateSince = 0;
unsigned long lastFlameRawLog = 0;

bool  intrusion = false;
// 2026-11-24: an intrusion now LATCHES like a real alarm panel. Closing the
// door/window again does not stop it; only DISARM (app / serial "a") clears
// it. "Silence" from the app stops the sound but keeps the alarm recorded.
// The siren stops by itself after INTRUSION_SIREN_MAX_MS (alarm stays on).
#define INTRUSION_SIREN_MAX_MS 180000UL   // 3 minutes of siren per intrusion
unsigned long intrusionSince = 0;

// ---------- false-fire guard state (index 0 = room 1, 1 = room 2) ----------
Preferences prefs;
bool doorReversed = DOOR_CONTACT_REVERSED;
bool windowReversed = WINDOW_CONTACT_REVERSED;
struct InputGuard {
  bool trusted;                 // has read CLEAR for INPUT_TRUST_CLEAR_MS since boot/warm-up
  unsigned long clearSince;     // physical input clear since
  bool fault;                   // ignored as a fire source
  const char* faultReason;
  unsigned long faultSince;
  bool lastRaw;                 // chatter counting
  uint16_t changes;
  unsigned long windowStart;
  unsigned long activeSince;    // confirmed ON since (stuck detection)
};
InputGuard flameGuard[2] = {};
InputGuard smokeGuard[2] = {};
unsigned long fireCandidateSince[2] = {0, 0};
unsigned long smokeWarmDoneAt = 0;

// Buzzer engine state
const uint16_t* pat = nullptr;
uint8_t  patLen = 0, patIdx = 0;
bool     patLoop = false;
unsigned long patStepStart = 0;

// What the app is told about the buzzer. A chirp is often shorter than the 5 s
// cloud upload, and alarm patterns alternate ON/OFF steps, so "is it sounding at
// this exact millisecond" almost always read OFF. Report ON while a pattern is
// playing and for BUZZER_REPORT_HOLD_MS after the last beep, so every sound is
// seen by at least one upload.
#define BUZZER_REPORT_HOLD_MS 2500UL   // OFF shows ~2.5 s after the last beep (was 6 s)
unsigned long buzzerLastOnMs = 0, buzzer2LastOnMs = 0;
bool buzzerReportActive() {
  return pat != nullptr || (buzzerLastOnMs && millis() - buzzerLastOnMs < BUZZER_REPORT_HOLD_MS);
}
bool buzzer2ReportActive() {
  return pat2 != nullptr || (buzzer2LastOnMs && millis() - buzzer2LastOnMs < BUZZER_REPORT_HOLD_MS);
}

// =====================================================
//                    MQ-2 ANALOG (AO) HELPERS
// =====================================================
// Forget the learned clean-air level and learn it again now (Serial "gascal",
// or automatically when a sensor is wired while the board is running).
void mq2Relearn(uint8_t idx, const char* why) {
  mq2Base[idx] = mq2Ema[idx];
  mq2Active[idx] = false;
  mq2ModeSet[idx] = false;
  mq2SignalSince[idx] = 0;
  Serial.printf("[SMOKE] MQ-2 #%u clean-air level re-learned at %.0f mV (%s)\n", idx + 1, mq2Ema[idx], why);
}

// Returns LOW while smoke is present, so it behaves like the old MQ-2 DO pin.
int mq2VirtualDO(uint8_t idx, uint8_t pin, bool warm) {
  uint32_t sum = 0;
  for (uint8_t i = 0; i < 4; i++) sum += analogReadMilliVolts(pin);
  const float mv = sum / 4.0f;
  mq2Ema[idx] = (mq2Ema[idx] == 0) ? mv : mq2Ema[idx] + 0.2f * (mv - mq2Ema[idx]);
  if (!warm) {                              // heater warming: follow the reading
    mq2Base[idx] = mq2Ema[idx];
    mq2Active[idx] = false;
    mq2ModeSet[idx] = false;
    return HIGH;
  }
  if (mq2Base[idx] <= 0) mq2Base[idx] = mq2Ema[idx];
  if (!mq2ModeSet[idx]) {
    mq2ModeSet[idx] = true;
    mq2DigitalMode[idx] = mq2Base[idx] >= MQ2_DO_DETECT_MV;
    Serial.printf("[SMOKE] MQ-2 #%u: clean air %.0f mV -> %s\n", idx + 1, mq2Base[idx],
                  mq2DigitalMode[idx] ? "DO (digital) wiring: gas = LOW"
                  : mq2Base[idx] < MQ2_NO_SIGNAL_MV ? "NO SIGNAL (0 V): check the AO wire, divider and MQ-2 5V/VIN supply"
                  : "AO (analog) wiring");
  }
  if (mq2DigitalMode[idx]) {                // DO: comparator on the module decides
    mq2NoSignal[idx] = false;
    if (!mq2Active[idx] && mq2Ema[idx] < MQ2_DO_LOW_MV) mq2Active[idx] = true;
    else if (mq2Active[idx] && mq2Ema[idx] > MQ2_DO_HIGH_MV) mq2Active[idx] = false;
    return mq2Active[idx] ? LOW : HIGH;
  }
  // Learned while nothing was connected (~0 V) and now a steady real voltage
  // appears for 10 s: the sensor was just wired -> learn clean air again.
  if (mq2Base[idx] < MQ2_NO_SIGNAL_MV && mq2Ema[idx] >= MQ2_NO_SIGNAL_MV) {
    if (mq2SignalSince[idx] == 0) mq2SignalSince[idx] = millis();
    else if (millis() - mq2SignalSince[idx] >= 10000UL) mq2Relearn(idx, "sensor connected after boot");
  } else {
    mq2SignalSince[idx] = 0;
  }
  const float rise = mq2Ema[idx] - mq2Base[idx];
  if (!mq2Active[idx] && rise >= MQ2_TRIGGER_MV)      mq2Active[idx] = true;
  else if (mq2Active[idx] && rise < MQ2_RELEASE_MV)   mq2Active[idx] = false;
  if (!mq2Active[idx] && rise < MQ2_RELEASE_MV / 2)   // slow clean-air drift only
    mq2Base[idx] += MQ2_TRACK_RATE * (mq2Ema[idx] - mq2Base[idx]);
  // Still ~0 V and no gas rise: the sensor signal is not reaching the ESP32.
  mq2NoSignal[idx] = !mq2Active[idx] && mq2Ema[idx] < MQ2_NO_SIGNAL_MV;
  return mq2Active[idx] ? LOW : HIGH;
}

int mq2Percent(uint8_t idx) {
  if (mq2DigitalMode[idx]) return mq2Active[idx] ? 100 : 0;
  const float span = 3100.0f - mq2Base[idx];
  if (span < 100 || mq2Base[idx] <= 0) return 0;
  return (int)constrain((mq2Ema[idx] - mq2Base[idx]) * 100.0f / span, -99.0f, 100.0f);
}

// =====================================================
//                    BUZZER ENGINE (non-blocking)
// =====================================================
// All four buzzers always play the same sound. Room 1 patterns (incl. door /
// window chimes and intrusion) have priority; otherwise the room-2 pattern plays.
const uint8_t BUZZ_PINS_ALL[] = {BUZZER_PIN, BUZZER_PIN_B, BUZZER2_PIN_B, BUZZER2_PIN};
bool buzzOn1 = false, buzzOn2 = false;
void writeAllBuzzers() {
  const bool on = (pat || !pat2) ? buzzOn1 : buzzOn2;
  for (uint8_t p : BUZZ_PINS_ALL) digitalWrite(p, (on ^ BUZZER_ACTIVE_LOW) ? HIGH : LOW);
}
void buzz(bool on) {
  buzzOn1 = on;
  if (on) buzzerLastOnMs = millis();   // app "buzzer active" report
  writeAllBuzzers();
}

void playPattern(const uint16_t* p, uint8_t len, bool loop) {
  pat = p; patLen = len; patIdx = 0; patLoop = loop;
  patStepStart = millis();
  buzz(true);
  lastCloudAttempt = millis() - CLOUD_INTERVAL_MS;  // tell the app now, not up to 5 s later
}

void stopPattern() {
  pat = nullptr;
  buzz(false);
}

void buzz2(bool on) {
  buzzOn2 = on;
  if (on) buzzer2LastOnMs = millis();
  writeAllBuzzers();
}
void playPattern2(const uint16_t* p, uint8_t len, bool loop) {
#if ENABLE_SECOND_BATCH
  pat2=p; patLen2=len; patIdx2=0; patLoop2=loop;
  patStepStart2=millis(); buzz2(true);
  lastCloudAttempt = millis() - CLOUD_INTERVAL_MS;  // tell the app now
#endif
}
void stopPattern2() { pat2=nullptr; buzz2(false); }
void updateBuzzer2() {
#if ENABLE_SECOND_BATCH
  if (!pat2) return;
  if (millis()-patStepStart2 < pat2[patIdx2]) return;
  ++patIdx2;
  if (patIdx2>=patLen2) {
    if (!patLoop2) { stopPattern2(); return; }
    patIdx2=0;
  }
  patStepStart2=millis();
  buzz2(patIdx2%2==0);
#endif
}
void updateBuzzer() {
  if (!pat) return;
  if (millis() - patStepStart < pat[patIdx]) return;
  patIdx++;
  if (patIdx >= patLen) {
    if (!patLoop) { stopPattern(); return; }
    patIdx = 0;
  }
  patStepStart = millis();
  buzz(patIdx % 2 == 0);     // even steps = ON, odd steps = OFF
}

// For the test command (blocking, plays a pattern a few times)
void playBlocking(const uint16_t* p, uint8_t len, int times) {
  for (int t = 0; t < times; t++) {
    for (uint8_t i = 0; i < len; i++) {
      buzz(i % 2 == 0);
      delay(p[i]);
    }
  }
  buzz(false);
  delay(800);
}

// =====================================================
//                    ALARM PRIORITY
// =====================================================
void startAlarmSound() {
  if (muted || activeAlarm == A_NONE) { stopPattern(); return; }
  switch (activeAlarm) {
    case A_FIRE:      playPattern(PAT(P_FIRE), true);      break;
    case A_INTRUSION: playPattern(PAT(P_INTRUSION), true); break;
    case A_FLAME:     playPattern(PAT(P_FLAME), true);     break;
    case A_SMOKE:     playPattern(PAT(P_SMOKE), true);     break;
    case A_TEMP:      playPattern(PAT(P_TEMP), true);      break;
    default:          stopPattern();                       break;
  }
}

void updateSecondRoomAlarm() {
#if ENABLE_SECOND_BATCH
  const bool hazardous = fireNow2 || smokeNow2 || flameNow2 || tempNow2;
  if (!hazardous || muted) { stopPattern2(); return; }
  // Keep active pattern if alarm remains; do not restart on every sample.
  if (pat2) return;
  if (fireNow2) playPattern2(PAT(P_FIRE), true);
  else if (flameNow2) playPattern2(PAT(P_FLAME), true);
  else if (smokeNow2) playPattern2(PAT(P_SMOKE), true);
  else playPattern2(PAT(P_TEMP), true);
#endif
}
void updateAlarm() {
  Alarm a = A_NONE;
  if      (fireNow)   a = A_FIRE;
  else if (intrusion) a = A_INTRUSION;
  else if (flameNow)  a = A_FLAME;
  else if (smokeNow)  a = A_SMOKE;
  else if (tempNow)   a = A_TEMP;

  if (a != activeAlarm) {
    activeAlarm = a;
    muted = false;              // a new situation always sounds again
    startAlarmSound();
  }
  updateSecondRoomAlarm();
}

// One-time sounds (door chime etc.) only play when no alarm is sounding
void chime(const uint16_t* p, uint8_t len) {
  if (activeAlarm != A_NONE && !muted) return;
  playPattern(p, len, false);
}

// =====================================================
//                    BUZZER TEST BY NAME
// =====================================================
bool playSoundByName(const String &name) {
  for (int i = 0; i < SOUND_COUNT; i++) {
    if (name == SOUNDS[i].name) {
      stopPattern();
      playPattern(SOUNDS[i].p, SOUNDS[i].len, SOUNDS[i].loop);
      Serial.printf("Playing %s sound%s\n", SOUNDS[i].name,
                    SOUNDS[i].loop ? " (type stop to end)" : "");
      return true;
    }
  }
  return false;
}

// =====================================================
//                    DOOR / WINDOW (REED SWITCHES)
// =====================================================
bool readContact(Contact &c) {
  // Raw rule: HIGH = open. "reversed" (the default for BOTH the door GPIO25 and
  // the window GPIO26) flips it, so LOW = OPEN and HIGH = CLOSED.
  bool open = digitalRead(c.pin) == HIGH;
  // A stuck HIGH on an INPUT_PULLUP pin often means an open circuit or
  // an NO reed contact. Polarity settings cannot repair incorrect wiring.
  const bool reverse = c.pin == DOOR_PIN ? doorReversed : windowReversed;
  return reverse ? !open : open;
}

void checkContact(Contact &c, const uint16_t* openP, uint8_t openLen) {
  if (!c.enabled) return;
  bool reading = readContact(c);

  if (reading != c.lastReading) {
    c.lastReading = reading;
    c.lastChange  = millis();
  }

  if (millis() - c.lastChange > CONTACT_DEBOUNCE && reading != c.open) {
    c.open = reading;
    Serial.println("***********************************");
    Serial.printf("%s %s\n", c.name, c.open ? "OPENED" : "CLOSED");

    if (c.open) {
      const bool protectedContact = (&c == &door) ? doorProtection : windowProtection;
      if (armed && protectedContact) {
        intrusion = true;
        intrusionSince = millis();
        Serial.printf(">>> INTRUSION ALERT: %s opened while ARMED <<<\n", c.name);
        if (activeAlarm == A_INTRUSION) {
          // Already latched (e.g. silenced earlier): a new opening sounds again.
          muted = false;
          startAlarmSound();
        } else {
          updateAlarm();
        }
      } else {
        chime(openP, openLen);
      }
    } else {
      // Intrusion stays latched until DISARM (see intrusionSince above).
      chime(PAT(P_CLOSED));
    }
    Serial.println("***********************************");
  }
}

// =====================================================
//            PAN + TILT (NON-BLOCKING TARGETS)
// =====================================================
void printPosition() {
  Serial.printf("PTZ ACK controller=%s pan=%d/%d tilt=%d/%d\n",
      DEVICE_ID, currentAngle, targetPan, currentTilt, targetTilt);
}

const char* resetReasonText(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON: return "power on";
    case ESP_RST_SW: return "software restart";
    case ESP_RST_PANIC: return "CRASH (panic)";
    case ESP_RST_INT_WDT: return "CRASH (interrupt watchdog)";
    case ESP_RST_TASK_WDT: return "CRASH (task watchdog)";
    case ESP_RST_WDT: return "CRASH (watchdog)";
    case ESP_RST_DEEPSLEEP: return "deep sleep";
    case ESP_RST_BROWNOUT: return "BROWNOUT - supply voltage dropped";
    case ESP_RST_EXT: return "reset button";
    default: return "other";
  }
}

// Called from loop(): attach the servos once the board has settled.
void updateServoPower() {
  if (!ENABLE_PTZ_SERVOS || servosAttached || servoPowerSafe) return;
  if (millis() < SERVO_ATTACH_DELAY_MS) return;
  attachServosIfNeeded();
  lastServoMotionMs = millis();
  if (SERVO_BOOT_SELF_TEST) servoSelfTest();
}

void attachServosIfNeeded() {
  if (!ENABLE_PTZ_SERVOS || servosAttached) return;
  // One servo at a time limits the start-up current spike.
  panServo.setPeriodHertz(50);
  panServo.attach(PAN_PIN, 500, 2400);   // SG90/SG92R range
  panServo.write(currentAngle);          // last known angle: never jumps
  delay(250);
  tiltServo.setPeriodHertz(50);
  tiltServo.attach(TILT_PIN, 500, 2400);
  tiltServo.write(currentTilt);
  panServoOk = panServo.attached();
  tiltServoOk = tiltServo.attached();
  servosAttached = true;
  static bool reported = false;
  if (!reported) {
    reported = true;
    Serial.printf("[PTZ] Pan servo GPIO%d: %s | Tilt servo GPIO%d: %s\n",
                  PAN_PIN, panServoOk ? "PWM OK" : "ATTACH FAILED",
                  TILT_PIN, tiltServoOk ? "PWM OK" : "ATTACH FAILED");
    if (!panServoOk || !tiltServoOk) {
      Serial.println("[PTZ] Update the ESP32Servo library (3.x) in Library Manager.");
    }
  }
}

// Blocking sweep used at boot and by the "servotest" command:
// pan left -> right -> centre, then tilt up -> down -> centre.
void sweepServo(Servo& servo, int from, int to) {
  const int step = to > from ? 1 : -1;
  for (int a = from; a != to; a += step) {
    servo.write(a);
    delay(12);
  }
  servo.write(to);
}

void servoSelfTest() {
  if (!ENABLE_PTZ_SERVOS) return;
  attachServosIfNeeded();
  const int panLeft = constrain(PAN_CENTER - SERVO_SELF_TEST_DEG, PAN_MIN, PAN_MAX);
  const int panRight = constrain(PAN_CENTER + SERVO_SELF_TEST_DEG, PAN_MIN, PAN_MAX);
  const int tiltA = constrain(TILT_CENTER - SERVO_SELF_TEST_DEG, TILT_MIN, TILT_MAX);
  const int tiltB = constrain(TILT_CENTER + SERVO_SELF_TEST_DEG, TILT_MIN, TILT_MAX);
  Serial.println("[PTZ] SELF-TEST: watch the camera - pan left/right, then tilt up/down...");
  sweepServo(panServo, currentAngle, panLeft);
  sweepServo(panServo, panLeft, panRight);
  sweepServo(panServo, panRight, PAN_CENTER);
  sweepServo(tiltServo, currentTilt, tiltA);
  sweepServo(tiltServo, tiltA, tiltB);
  sweepServo(tiltServo, tiltB, TILT_CENTER);
  currentAngle = targetPan = PAN_CENTER;
  currentTilt = targetTilt = TILT_CENTER;
  lastServoMotionMs = millis();
  Serial.println("[PTZ] SELF-TEST done. If nothing moved: power the servos from 5 V (not 3.3 V), "
                 "join the servo GND with the ESP32 GND, and check the signal wires on GPIO13/GPIO27.");
}

void printServoDiagnostics() {
  Serial.printf("[PTZ] enabled=%s attached=%s pan(GPIO%d)=%s tilt(GPIO%d)=%s\n",
                ENABLE_PTZ_SERVOS ? "yes" : "no", servosAttached ? "yes" : "no",
                PAN_PIN, panServoOk ? "OK" : "FAILED", TILT_PIN, tiltServoOk ? "OK" : "FAILED");
  Serial.printf("[PTZ] pan %d -> %d (limits %d..%d), tilt %d -> %d (limits %d..%d), moving=%s\n",
                currentAngle, targetPan, PAN_MIN, PAN_MAX, currentTilt, targetTilt,
                TILT_MIN, TILT_MAX, servosMoving() ? "yes" : "no");
  Serial.printf("[PTZ] auto-follow=%s%s, auto moves=%lu, Camera 1 link=%s\n",
                autoFollowEnabled ? "ON" : "OFF", autoFollowPaused() ? " (paused by manual)" : "",
                (unsigned long)autoMoveCount, camera1LinkFresh() ? "OK" : "DOWN");
}

bool autoFollowPaused() {
  return (long)(manualOverrideUntil - millis()) > 0;
}

// Any move not issued by auto-follow is manual and takes priority.
void noteManualControl() {
  if (autoMoveContext) return;
  autoMoveActive = false;
  manualOverrideUntil = millis() + AUTO_MANUAL_HOLD_MS;
}

void moveTo(int target) {
  noteManualControl();
  targetPan = constrain(target, PAN_MIN, PAN_MAX);
  attachServosIfNeeded();
  lastServoMotionMs = millis();
  Serial.printf("PTZ PAN TARGET %d\n", targetPan);
}

void moveTiltTo(int target) {
  noteManualControl();
  targetTilt = constrain(target, TILT_MIN, TILT_MAX);
  attachServosIfNeeded();
  lastServoMotionMs = millis();
  Serial.printf("PTZ TILT TARGET %d\n", targetTilt);
}

// Manual "stop": hold exactly where the servos are right now.
void haltServos() {
  noteManualControl();
  targetPan = currentAngle;
  targetTilt = currentTilt;
  lastServoMotionMs = millis();
  Serial.printf("PTZ HALT pan=%d tilt=%d\n", currentAngle, currentTilt);
}

bool servosMoving() {
  return currentAngle != targetPan || currentTilt != targetTilt;
}

// Non-blocking, rate-limited stepping: 1 degree per SERVO_STEP_MS for each
// axis. Small, even steps keep the image steady and avoid current spikes
// that make micro-servos shake.
void updateServos() {
  const unsigned long stepMs = autoMoveActive ? AUTO_SERVO_STEP_MS : SERVO_STEP_MS;
  if (millis() - lastServoStep < stepMs) return;
  lastServoStep = millis();
  if (servosMoving()) attachServosIfNeeded();
  bool stepped = false;
  if (currentAngle != targetPan) {
    currentAngle += currentAngle < targetPan ? 1 : -1;
    panServo.write(currentAngle);
    stepped = true;
  }
  if (currentTilt != targetTilt) {
    currentTilt += currentTilt < targetTilt ? 1 : -1;
    tiltServo.write(currentTilt);
    stepped = true;
  }
  if (stepped) lastServoMotionMs = millis();
  if (!servosMoving()) autoMoveActive = false;
  if (SERVO_RELEASE_WHEN_IDLE && servosAttached && !servosMoving() &&
      millis() - lastServoMotionMs >= SERVO_IDLE_RELEASE_MS) {
    panServo.detach();
    tiltServo.detach();
    servosAttached = false;
  }
}

// =====================================================
//     CAMERA 1 LINK (direct LAN, read-only for servos)
// =====================================================
// Camera 1 does the image analysis and owns the video. This controller owns
// the servos. The link worker runs on its own low-priority task so Wi-Fi
// requests never block sensor sampling, alarms, servos or the local API.
// It NEVER moves the servos - PTZ is manual only.
bool readMotionNumber(const String& json, const char* key, float& value,
                      float upperBound = 1.0f) {
  String label = String("\"") + key + "\":";
  int pos = json.indexOf(label);
  if (pos < 0) return false;
  pos += label.length();
  while (pos < (int)json.length() && isspace((unsigned char)json[pos])) pos++;
  if (pos >= (int)json.length()) return false;
  char* endPtr = nullptr;
  value = strtof(json.c_str() + pos, &endPtr);
  return endPtr != json.c_str() + pos && isfinite(value) &&
         value >= 0.0f && value <= upperBound;
}

// Parse an actual JSON boolean, allowing whitespace after ':'.
// A missing or malformed field must not be interpreted as true.
bool readJsonBool(const String& json, const char* key, bool& out) {
  String label = String("\"") + key + "\"";
  int pos = json.indexOf(label);
  if (pos < 0) return false;
  pos = json.indexOf(':', pos + label.length());
  if (pos < 0) return false;
  ++pos;
  while (pos < (int)json.length() && isspace((unsigned char)json[pos])) ++pos;
  if (json.startsWith("true", pos)) { out = true; return true; }
  if (json.startsWith("false", pos)) { out = false; return true; }
  return false;
}

bool readMotionDetected(const String& json, bool& detected) {
  return readJsonBool(json, "motion_detected", detected);
}

bool readJsonUInt(const String& json, const char* key, uint32_t& out) {
  String label = String("\"") + key + "\":";
  int pos = json.indexOf(label);
  if (pos < 0) return false;
  const char* start = json.c_str() + pos + label.length();
  char* end = nullptr;
  const unsigned long value = strtoul(start, &end, 10);
  if (end == start) return false;
  out = (uint32_t)value;
  return true;
}

void applyCameraMotion(const String& data) {
  bool detected = false;
  bool fresh = false;
  float analysisAge = 0;
  // A reachable camera can still return an old result; require a recent
  // completed frame analysis before reporting motion.
  const bool freshAnalysis =
    readMotionNumber(data, "analysis_age_ms", analysisAge, 2400.0f) &&
    readJsonBool(data, "motion_fresh", fresh) && fresh;
  if (!readMotionDetected(data, detected) || !freshAnalysis) detected = false;

  const bool wasDetected = camera1MotionDetected;
  camera1MotionDetected = detected;
  float x = 0.5f, y = 0.5f;
  if (detected && readMotionNumber(data, "motion_x", x) &&
      readMotionNumber(data, "motion_y", y)) {
    camera1MotionX = x;
    camera1MotionY = y;
    lastCamera1MotionMs = millis();
  }
  if (detected && !wasDetected) {
    camera1MotionEvent = true;
    Serial.printf("[CAMERA1] Motion detected x=%.2f y=%.2f\n",
                  camera1MotionX, camera1MotionY);
  }

  bool settling = false;
  readJsonBool(data, "ptz_settling", settling);
  camera1Settling = settling;

  float rssi = 0;
  if (readMotionNumber(data, "wifi_rssi_abs", rssi, 127.0f)) camera1Rssi = -(int)rssi;
  uint32_t value = 0;
  if (readJsonUInt(data, "uptime_ms", value)) camera1UptimeMs = value;
  if (readJsonUInt(data, "changed_samples", value)) camera1ChangedSamples = detected ? value : 0;

  // Hand each NEW confirmed analysis to loop() exactly once. Old results are
  // never reused, so one detection can never cause repeated moves.
  static uint32_t lastQueuedAnalysis = 0;
  uint32_t analysis = 0;
  if (detected && !settling && readJsonUInt(data, "analysis_count", analysis) &&
      analysis != lastQueuedAnalysis &&
      lastCamera1MotionMs && millis() - lastCamera1MotionMs < 1000UL) {
    lastQueuedAnalysis = analysis;
    portENTER_CRITICAL(&autoMux);
    autoRequestX = camera1MotionX;
    autoRequestY = camera1MotionY;
    autoRequestPending = true;
    portEXIT_CRITICAL(&autoMux);
  }
}

// Runs in loop(): the ONLY place auto-follow moves the servos.
void updateAutoFollow() {
  bool pending;
  float x, y;
  portENTER_CRITICAL(&autoMux);
  pending = autoRequestPending;
  x = autoRequestX;
  y = autoRequestY;
  autoRequestPending = false;
  portEXIT_CRITICAL(&autoMux);

  const unsigned long now = millis();
  if (!ENABLE_PTZ_SERVOS || !autoFollowEnabled || autoFollowPaused()) return;

  if (!pending) {
#if AUTO_HOME_AFTER_IDLE_MS > 0
    // Optional: drift back to centre after a quiet period.
    if (lastAutoTrackMs &&
        now - lastAutoTrackMs >= AUTO_HOME_AFTER_IDLE_MS && !servosMoving() &&
        (currentAngle != PAN_CENTER || currentTilt != TILT_CENTER)) {
      lastAutoTrackMs = 0;
      autoMoveContext = true;
      autoMoveActive = true;
      moveTo(PAN_CENTER);
      moveTiltTo(TILT_CENTER);
      autoMoveContext = false;
      Serial.println("[AUTO] Idle - returning to centre");
    }
#endif
    return;
  }

  // Never stack moves: wait until the last move finished and settled.
  if (servosMoving() || camera1Settling || now - lastServoMotionMs < AUTO_SETTLE_MS) return;

  const float errorX = x - 0.5f;   // + = motion right of centre
  const float errorY = y - 0.5f;   // + = motion below centre
  int panDeg = 0, tiltDeg = 0;
  if (fabsf(errorX) > AUTO_DEADBAND_X) {
    panDeg = constrain((int)lroundf(fabsf(errorX) * CAMERA_HFOV_DEG * AUTO_GAIN),
                       AUTO_MIN_STEP_DEG, AUTO_MAX_STEP_DEG);
  }
  if (fabsf(errorY) > AUTO_DEADBAND_Y) {
    tiltDeg = constrain((int)lroundf(fabsf(errorY) * CAMERA_VFOV_DEG * AUTO_GAIN),
                        AUTO_MIN_STEP_DEG, AUTO_MAX_STEP_DEG);
  }
  lastAutoTrackMs = now;
  if (!panDeg && !tiltDeg) return;   // target already near the centre

  const bool toRight = (errorX > 0) != AUTO_INVERT_PAN;
  const bool up = (errorY < 0) != AUTO_INVERT_TILT;
  autoMoveContext = true;
  autoMoveActive = true;
  if (panDeg) turn(panDeg, toRight);
  if (tiltDeg) tiltBy(tiltDeg, up);
  autoMoveContext = false;
  ++autoMoveCount;
  Serial.printf("[AUTO] motion x=%.2f y=%.2f -> pan %s %d, tilt %s %d (target pan=%d tilt=%d)\n",
                x, y, toRight ? "right" : "left", panDeg, up ? "up" : "down", tiltDeg,
                targetPan, targetTilt);
}

void cameraLinkWorker(void*) {
  bool legacyCamera = false;   // camera firmware without /link
  for (;;) {
    if (WiFi.status() != WL_CONNECTED) {
      camera1LinkAccepted = false;
      vTaskDelay(pdMS_TO_TICKS(1000));
      continue;
    }
    String url = String("http://") + cameraHost();
    if (!legacyCamera) {
      url += "/link?controller=" + String(DEVICE_ID);
      url += "&ip=" + WiFi.localIP().toString();
      url += "&pan=" + String(currentAngle) + "&tilt=" + String(currentTilt);
      url += "&target_pan=" + String(targetPan) + "&target_tilt=" + String(targetTilt);
      url += "&moving=" + String(servosMoving() ? 1 : 0);
      url += "&auto=" + String(autoFollowEnabled ? 1 : 0);
      url += "&paused=" + String(autoFollowPaused() ? 1 : 0);
    } else {
      url += "/motion";
    }
    HTTPClient http;
    http.setTimeout(CAMERA1_LINK_TIMEOUT_MS);
    http.setConnectTimeout(CAMERA1_LINK_TIMEOUT_MS);
    http.setReuse(false);
    if (http.begin(url)) {
      if (!legacyCamera) http.addHeader("X-Device-Key", DEVICE_HTTP_KEY);
      const int status = http.GET();
      camera1LastHttpStatus = status;
      static int linkFails = 0;
      if (status == 200) linkFails = 0;
      else if (++linkFails >= 12 && mdnsStarted) {
        // Camera not answering at the saved address: look it up by name.
        linkFails = 0;
        char camName[] = CAMERA1_MDNS_NAME;   // writable: older cores take char*
        const IPAddress found = MDNS.queryHost(camName, 1500);
        if (found != IPAddress((uint32_t)0) && found.toString() != cameraHost()) {
          setCameraHost(found.toString(), "found on this Wi-Fi by name");
        }
      }
      if (status == 200) {
        const String data = http.getString();
        lastCamera1HttpOkMs = millis();
        camera1LinkAccepted = !legacyCamera;
        applyCameraMotion(data);
        static unsigned long lastOkLog = 0;
        if (millis() - lastOkLog >= 30000UL) {
          lastOkLog = millis();
          Serial.printf("[CAMERA1] LINK OK (%s) motion=%d RSSI=%d dBm\n",
                        legacyCamera ? "legacy /motion" : "/link",
                        camera1MotionDetected ? 1 : 0, WiFi.RSSI());
        }
      } else {
        camera1LinkAccepted = false;
        if (status == 404 && !legacyCamera) {
          legacyCamera = true;  // older camera sketch: still read /motion
          Serial.println("[CAMERA1] /link not found - flash the new Camera 1 sketch for app PTZ relay; reading /motion only");
        }
        static unsigned long lastErrLog = 0;
        if (millis() - lastErrLog >= 10000UL) {
          lastErrLog = millis();
          if (status == 401) {
            Serial.println("[CAMERA1] LINK REJECTED (401): CONTROLLER_HTTP_KEY in the camera sketch must equal DEVICE_HTTP_KEY here");
          } else {
            Serial.printf("[CAMERA1] Link error HTTP=%d (camera at %s; searching for %s.local)\n", status, cameraHost().c_str(), CAMERA1_MDNS_NAME);
          }
        }
      }
      http.end();
    }
    // Evidence photo request (fire / intrusion). Camera 1 answers at once and
    // uploads in its own loop, so this never blocks the link for long.
    const uint8_t snap = cameraSnapshotRequest;
    if (snap) {
      cameraSnapshotRequest = 0;
      HTTPClient shot;
      shot.setTimeout(CAMERA1_LINK_TIMEOUT_MS * 2);
      shot.setConnectTimeout(CAMERA1_LINK_TIMEOUT_MS);
      shot.setReuse(false);
      const String shotUrl = String("http://") + cameraHost() + "/save?reason=" + (snap == 1 ? "fire" : "intrusion");
      if (shot.begin(shotUrl)) {
        shot.addHeader("X-Device-Key", DEVICE_HTTP_KEY);
        const int st = shot.POST(String());
        Serial.printf("[CAMERA1] Evidence photo request (%s) HTTP=%d\n", snap == 1 ? "fire" : "intrusion", st);
        shot.end();
      }
    }
    vTaskDelay(pdMS_TO_TICKS(CAMERA1_LINK_INTERVAL_MS));
  }
}

bool camera1LinkFresh() {
  return lastCamera1HttpOkMs && millis() - lastCamera1HttpOkMs < 5000UL;
}

void turn(int degrees, bool toRight) {
  int change = (toRight == RIGHT_DECREASES_ANGLE) ? -degrees : degrees;
  moveTo(targetPan + change);
}
void tiltBy(int degrees, bool up) {
  int change = (up == UP_DECREASES_ANGLE) ? -degrees : degrees;
  moveTiltTo(targetTilt + change);
}

int extractNumber(const String &s) {
  String digits = "";
  for (unsigned int i = 0; i < s.length(); ++i) {
    if (isDigit(s[i])) digits += s[i];
  }
  return digits.length() ? digits.toInt() : -1;
}

String jsonStatus() {
  String j = "{\"device_id\":\"" + String(DEVICE_ID) +
             "\",\"room_key\":\"" + String(ROOM_KEY) + "\"";
  j += ",\"coverage\":{\"" + String(ROOM_KEY) + "\":\"" + String(PRIMARY_COVERAGE_NAME) +
       "\",\"" + String(SECOND_ROOM_KEY) + "\":\"" + String(SECOND_COVERAGE_NAME) + "\"}";
  j += ",\"uptime_ms\":" + String(millis());
  j += ",\"ptz_mode\":\"" + String(!autoFollowEnabled ? "manual" : autoFollowPaused() ? "auto_paused" : "auto") + "\"";
  j += ",\"auto_follow\":" + String(autoFollowEnabled ? "true" : "false");
  j += ",\"arm_mode\":\"" + armMode + "\"";
  j += ",\"door_protection\":" + String(doorProtection ? "true" : "false");
  j += ",\"window_protection\":" + String(windowProtection ? "true" : "false");
  j += ",\"auto_paused\":" + String(autoFollowEnabled && autoFollowPaused() ? "true" : "false");
  j += ",\"auto_paused_ms\":" + String(autoFollowPaused() ? (unsigned long)(manualOverrideUntil - millis()) : 0UL);
  j += ",\"auto_moves\":" + String(autoMoveCount);
  j += ",\"camera1_host\":\"" + cameraHost() + "\"";
  j += ",\"camera1_link_accepted\":" + String(camera1LinkAccepted && camera1LinkFresh() ? "true" : "false");
  j += ",\"camera1_last_http_status\":" + String(camera1LastHttpStatus);
  const unsigned long cameraAge = lastCamera1HttpOkMs ? millis() - lastCamera1HttpOkMs : 0;
  j += ",\"camera1_http_fresh\":" + String(lastCamera1HttpOkMs && cameraAge < 10000UL ? "true" : "false");
  j += ",\"camera1_http_age_ms\":" + (lastCamera1HttpOkMs ? String(cameraAge) : String("null"));
  j += ",\"camera1_motion_detected\":" + (lastCamera1HttpOkMs && cameraAge < 10000UL ? String(camera1MotionDetected ? "true" : "false") : String("null"));
  j += ",\"camera1_motion_x\":" + (lastCamera1MotionMs && millis()-lastCamera1MotionMs < 10000UL ? String(camera1MotionX, 3) : String("null"));
  j += ",\"camera1_motion_y\":" + (lastCamera1MotionMs && millis()-lastCamera1MotionMs < 10000UL ? String(camera1MotionY, 3) : String("null"));
  j += ",\"sample_age_ms\":" + (lastSensorSample ? String(millis() - lastSensorSample) : String("null"));
  const bool sensorFresh = lastSensorSample && millis() - lastSensorSample <= MAX_SENSOR_AGE_MS;
  j += ",\"dht_valid\":" + String(dhtValid && sensorFresh ? "true" : "false");
  j += ",\"temperature\":" + (dhtValid && sensorFresh ? String(lastTemp, 2) : String("null"));
  j += ",\"humidity\":" + (dhtValid && sensorFresh ? String(lastHum, 2) : String("null"));
  j += ",\"mq2_warmed_up\":" + String(mq2WarmedUp ? "true" : "false");
  j += ",\"sensor_status\":\"" + String(!sensorFresh ? "STALE" : !dhtValid ? "DHT_UNAVAILABLE" : !mq2WarmedUp ? "MQ2_WARMUP" : "READINGS_AVAILABLE") + "\"";
  j += ",\"smoke_detected\":" + (mq2WarmedUp ? String(smokeNow ? "true" : "false") : String("null"));
  j += ",\"smoke_raw\":" + String((int)mq2Ema[0]);  // MQ-2 AO, mV
  j += ",\"flame_detected\":" + String(flameNow ? "true" : "false");
  j += ",\"flame_raw_gpio\":" + String(digitalRead(FLAME_PIN));
  j += ",\"smoke_raw_gpio\":" + String(mq2Active[0] ? 0 : 1);
  // Second room is explicitly reported as disabled until enabled and wired.
  j += ",\"second_room\":{";
  j += "\"room_key\":\"" + String(SECOND_ROOM_KEY) + "\"";
  j += ",\"enabled\":" + String(ENABLE_SECOND_BATCH ? "true" : "false");
  j += ",\"sample_age_ms\":" + (ENABLE_SECOND_BATCH && lastSensorSample2 ? String(millis()-lastSensorSample2) : String("null"));
  j += ",\"dht_valid\":" + String(ENABLE_SECOND_BATCH && dht2Valid ? "true" : "false");
  j += ",\"temperature\":" + String(ENABLE_SECOND_BATCH && dht2Valid ? String(lastTemp2,2) : String("null"));
  j += ",\"humidity\":" + String(ENABLE_SECOND_BATCH && dht2Valid ? String(lastHum2,2) : String("null"));
  j += ",\"mq2_warmed_up\":" + String(ENABLE_SECOND_BATCH && mq2WarmedUp2 ? "true" : "false");
  j += ",\"smoke_detected\":" + String(ENABLE_SECOND_BATCH && mq2WarmedUp2 ? (smokeNow2 ? "true":"false") : "null");
  j += ",\"smoke_raw\":null";
  j += ",\"flame_detected\":" + String(ENABLE_SECOND_BATCH ? (flameNow2 ? "true":"false") : "null");
  j += ",\"buzzer_active\":" + String(ENABLE_SECOND_BATCH ? (buzzer2ReportActive() ? "true":"false") : "null");
  j += "}";
  j += ",\"door_open\":" + String(door.open ? "true" : "false");
  j += ",\"armed\":" + String(armed ? "true" : "false");
  j += ",\"alarm\":\"" + String(ALARM_NAMES[activeAlarm]) + "\"";
  j += ",\"pan\":" + String(currentAngle) + ",\"target_pan\":" + String(targetPan);
  j += ",\"tilt\":" + String(currentTilt) + ",\"target_tilt\":" + String(targetTilt);
  j += ",\"ptz_moving\":" + String(servosMoving() ? "true" : "false");
  j += ",\"servo_pan_ok\":" + String(panServoOk ? "true" : "false");
  j += ",\"servo_tilt_ok\":" + String(tiltServoOk ? "true" : "false");
  j += ",\"pan_min\":" + String(PAN_MIN) + ",\"pan_max\":" + String(PAN_MAX);
  j += ",\"tilt_min\":" + String(TILT_MIN) + ",\"tilt_max\":" + String(TILT_MAX);
  j += ",\"buzzer_active\":" + String(buzzerReportActive() ? "true" : "false");
  j += ",\"window_open\":" + String(window.open ? "true" : "false");
  j += ",\"wifi_connected\":" + String(WiFi.status() == WL_CONNECTED ? "true" : "false");
  j += "}";
  return j;
}

bool authorized() {
  String supplied = webServer.header("X-Device-Key");
  return supplied.length() >= 16 && supplied == DEVICE_HTTP_KEY;
}
void addCorsHeaders() {
  // Lets a LAN browser/Flutter-web client call this API directly.
  // Authentication is still enforced by X-Device-Key on /status and /ptz.
  webServer.sendHeader("Access-Control-Allow-Origin", "*");
  webServer.sendHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  webServer.sendHeader("Access-Control-Allow-Headers", "Content-Type,X-Device-Key");
  webServer.sendHeader("Access-Control-Allow-Private-Network", "true");
}
void jsonReply(int code, const String &body) {
  webServer.sendHeader("Cache-Control", "no-store");
  addCorsHeaders();
  webServer.send(code, "application/json", body);
}
void routeOptions() {
  addCorsHeaders();
  webServer.send(204);
}
void routeStatus() {
  if (!authorized()) { jsonReply(401, "{\"error\":\"unauthorized\"}"); return; }
  jsonReply(200, jsonStatus());
}
void routeHealth() {
  // Safe unauthenticated reachability check: no device keys, sensor values,
  // occupancy, or servo commands are exposed.
  String body = "{\"device_id\":\"" + String(DEVICE_ID) +
    "\",\"wifi_connected\":true,\"auto_follow\":" + String(autoFollowEnabled ? "true" : "false") +
    ",\"camera1_http_fresh\":" +
    String(lastCamera1HttpOkMs && millis() - lastCamera1HttpOkMs < 10000UL ? "true" : "false") + "}";
  jsonReply(200, body);
}
// Auto-follow on/off from the app (LAN or cloud) or Serial. Saved in flash,
// so the choice survives a reboot or power cut.
void setAutoFollow(bool enabled, const char* source) {
  autoFollowEnabled = enabled;
  if (enabled) manualOverrideUntil = 0;   // resume following immediately
  else autoMoveActive = false;
  prefs.putBool("autoFol", enabled);
  ptzStateDirty = true;
  Serial.printf("[AUTO] Auto-follow %s (%s)\n",
                enabled ? "ON: servos follow Camera 1 motion" : "OFF: manual control only", source);
}

// One PTZ action, shared by the LAN route (POST /ptz relayed by Camera 1)
// and the cloud route (Supabase device_commands "PTZ").
bool applyPtzAction(String action, int n, const char* source) {
  action.trim();
  action.toLowerCase();
  n = constrain(n, 1, PTZ_MAX_JOG_DEG);
  if (!ENABLE_PTZ_SERVOS) return false;
  if (action == "left") turn(n, false);
  else if (action == "right") turn(n, true);
  else if (action == "up") tiltBy(n, true);
  else if (action == "down") tiltBy(n, false);
  else if (action == "center" || action == "home") { moveTo(PAN_CENTER); moveTiltTo(TILT_CENTER); }
  else if (action == "stop") haltServos();
  else if (action == "auto_on" || action == "auto") setAutoFollow(true, source);
  else if (action == "auto_off" || action == "manual") setAutoFollow(false, source);
  else return false;
  return true;
}

void routePtz() {
  if (!authorized()) { jsonReply(401, "{\"error\":\"unauthorized\"}"); return; }
  String action = webServer.arg("action");
  int n = PTZ_JOG_DEG;
  if (webServer.hasArg("step")) {
    const int requested = webServer.arg("step").toInt();
    if (requested < 1 || requested > PTZ_MAX_JOG_DEG) {
      jsonReply(400, "{\"error\":\"invalid_step\"}");
      return;
    }
    n = requested;
  }
  if (!applyPtzAction(action, n, "app via Camera 1")) {
    jsonReply(400, "{\"error\":\"invalid_action\"}");
    return;
  }
  jsonReply(200, jsonStatus());  // targets accepted; poll /status for the live angle
}
// ---------- Camera 1 address (shared with the camera link task) ----------
String cameraHost() {
  char buf[40];
  portENTER_CRITICAL(&camHostMux);
  memcpy(buf, camera1HostBuf, sizeof(buf));
  portEXIT_CRITICAL(&camHostMux);
  buf[sizeof(buf) - 1] = 0;
  return String(buf);
}
void setCameraHost(const String& host, const char* why) {
  portENTER_CRITICAL(&camHostMux);
  strlcpy(camera1HostBuf, host.c_str(), sizeof(camera1HostBuf));
  portEXIT_CRITICAL(&camHostMux);
  camHostDirty = true;   // saved to flash from the main loop
  Serial.printf("[CAMERA1] Camera address is now %s (%s)\n", host.c_str(), why);
}
bool validIpText(const String& t) {
  IPAddress ip;
  return t.length() >= 7 && ip.fromString(t);
}

// ---------- Saved Wi-Fi networks ----------
String wifiKey(int i, char kind) { return String("w") + i + kind; }
void loadWifiNetworks() {
  wifiNetCount = 0;
  for (int i = 0; i < WIFI_MAX_SAVED; ++i) {
    const String ssid = prefs.getString(wifiKey(i, 's').c_str(), "");
    if (!ssid.length()) continue;
    wifiSsids[wifiNetCount] = ssid;
    wifiPasses[wifiNetCount] = prefs.getString(wifiKey(i, 'p').c_str(), "");
    ++wifiNetCount;
  }
  bool haveDefault = false;
  for (int i = 0; i < wifiNetCount; ++i) if (wifiSsids[i] == WIFI_SSID) haveDefault = true;
  if (!haveDefault && strlen(WIFI_SSID) && !String(WIFI_SSID).startsWith("REPLACE_")) {
    wifiSsids[wifiNetCount] = WIFI_SSID;
    wifiPasses[wifiNetCount] = WIFI_PASSWORD;
    ++wifiNetCount;
  }
}
void saveWifiNetwork(const String& ssid, const String& pass) {
  String s[WIFI_MAX_SAVED], p[WIFI_MAX_SAVED];
  int n = 0;
  s[n] = ssid; p[n] = pass; ++n;
  for (int i = 0; i < WIFI_MAX_SAVED && n < WIFI_MAX_SAVED; ++i) {
    const String old = prefs.getString(wifiKey(i, 's').c_str(), "");
    if (old.length() && old != ssid) { s[n] = old; p[n] = prefs.getString(wifiKey(i, 'p').c_str(), ""); ++n; }
  }
  for (int i = 0; i < WIFI_MAX_SAVED; ++i) {
    prefs.putString(wifiKey(i, 's').c_str(), i < n ? s[i] : String());
    prefs.putString(wifiKey(i, 'p').c_str(), i < n ? p[i] : String());
  }
  loadWifiNetworks();
  wifiNetIndex = 0;
  Serial.printf("[WIFI] Saved network \"%s\" (%d networks known)\n", ssid.c_str(), wifiNetCount);
}
void forgetWifiNetworks() {
  for (int i = 0; i < WIFI_MAX_SAVED; ++i) {
    prefs.remove(wifiKey(i, 's').c_str());
    prefs.remove(wifiKey(i, 'p').c_str());
  }
  loadWifiNetworks();
  wifiNetIndex = 0;
  Serial.println("[WIFI] Saved networks erased (only the built-in WIFI_SSID remains)");
}
void listWifiNetworks() {
  Serial.printf("[WIFI] %s | known networks (tried in this order):\n",
                WiFi.status() == WL_CONNECTED ? ("connected to \"" + WiFi.SSID() + "\" " + WiFi.localIP().toString()).c_str() : "NOT connected");
  for (int i = 0; i < wifiNetCount; ++i) Serial.printf("  %d. %s\n", i + 1, wifiSsids[i].c_str());
  if (wifiPortalActive) Serial.printf("[WIFI] Setup hotspot ON: \"%s\" password %s -> http://192.168.4.1\n",
                                      (String("PyroGuard-") + DEVICE_ID + "-Setup").c_str(), WIFI_SETUP_PASSWORD);
}
void connectNextWifi() {
  lastWifiAttempt = millis();
  if (wifiNetCount == 0) return;
  const int i = wifiNetIndex % wifiNetCount;
  ++wifiNetIndex;
  Serial.printf("[WIFI] Trying \"%s\" (%d of %d)\n", wifiSsids[i].c_str(), i + 1, wifiNetCount);
  WiFi.begin(wifiSsids[i].c_str(), wifiPasses[i].c_str());
}

// ---------- Setup hotspot (captive page at http://192.168.4.1) ----------
void ensureWebServer() {
  if (!webStarted) { webServer.begin(); webStarted = true; }
}
void startWifiPortal() {
  if (wifiPortalActive) return;
  const String ap = String("PyroGuard-") + DEVICE_ID + "-Setup";
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(ap.c_str(), WIFI_SETUP_PASSWORD);
  wifiPortalActive = true;
  ensureWebServer();
  Serial.println("==============================================================");
  Serial.printf("[WIFI] No known Wi-Fi. Setup hotspot ON: \"%s\"  password: %s\n", ap.c_str(), WIFI_SETUP_PASSWORD);
  Serial.println("[WIFI] Connect a phone to it, open http://192.168.4.1 and pick the Wi-Fi.");
  Serial.println("[WIFI] (Or type in Serial:  wifi YourWiFiName|YourPassword )");
  Serial.println("==============================================================");
}
void stopWifiPortal() {
  if (!wifiPortalActive) return;
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  wifiPortalActive = false;
  Serial.println("[WIFI] Setup hotspot closed (connected to Wi-Fi)");
}
bool fromSetupHotspot() {
  const IPAddress r = webServer.client().remoteIP();
  return wifiPortalActive && r[0] == 192 && r[1] == 168 && r[2] == 4;
}
String htmlEscape(String t) {
  t.replace("&", "&amp;"); t.replace("<", "&lt;"); t.replace(">", "&gt;"); t.replace("\"", "&quot;");
  return t;
}
const char WIFI_PAGE_HEAD[] PROGMEM =
  "<!doctype html><html><head><meta name=viewport content='width=device-width,initial-scale=1'>"
  "<title>PyroGuard Wi-Fi setup</title><style>body{font-family:sans-serif;max-width:460px;margin:20px auto;padding:0 14px;color:#222}"
  "h2{color:#B91C1C}button,input{font-size:16px;padding:10px;width:100%;box-sizing:border-box;margin:5px 0;border-radius:8px;border:1px solid #ccc}"
  "button{background:#DC2626;color:#fff;border:0}.n{background:#fff;color:#222;border:1px solid #F97316;text-align:left}"
  "small{color:#666}</style></head><body>";
void routeWifiPage() {
  if (!fromSetupHotspot()) { jsonReply(403, "{\"error\":\"setup_hotspot_only\"}"); return; }
  int n = WiFi.scanNetworks();
  if (n < 0) { WiFi.disconnect(); delay(100); n = WiFi.scanNetworks(); }
  String h = FPSTR(WIFI_PAGE_HEAD);
  h += "<h2>PyroGuard " + String(DEVICE_ID) + "</h2><p>Choose the Wi-Fi this device should use:</p>";
  for (int i = 0; i < n && i < 15; ++i) {
    const String ssid = WiFi.SSID(i);
    if (!ssid.length()) continue;
    h += "<button class=n type=button onclick=\"document.getElementById('s').value=this.dataset.s\" data-s=\"" + htmlEscape(ssid) + "\">" +
         htmlEscape(ssid) + " <small>(" + String(WiFi.RSSI(i)) + " dBm)</small></button>";
  }
  WiFi.scanDelete();
  h += "<form method=post action=/wifisave><input id=s name=ssid placeholder='Wi-Fi name' required>"
       "<input name=pass type=password placeholder='Wi-Fi password (empty if open)'>";
  if (BATCH_HAS_CAMERA_PTZ)
    h += "<input name=cam placeholder='Camera 1 IP (optional, found automatically)'>";
  h += "<button type=submit>Save and connect</button></form>"
       "<p><small>The device remembers up to 3 networks. Fire and intrusion alarms keep working during setup.</small></p></body></html>";
  webServer.send(200, "text/html", h);
}
void routeWifiSave() {
  if (!fromSetupHotspot()) { jsonReply(403, "{\"error\":\"setup_hotspot_only\"}"); return; }
  String ssid = webServer.arg("ssid"); ssid.trim();
  const String pass = webServer.arg("pass");
  String cam = webServer.arg("cam"); cam.trim();
  if (!ssid.length()) { webServer.send(400, "text/plain", "Wi-Fi name is required"); return; }
  saveWifiNetwork(ssid, pass);
  if (cam.length() && validIpText(cam)) setCameraHost(cam, "entered on the setup page");
  String h = FPSTR(WIFI_PAGE_HEAD);
  h += "<h2>Saved</h2><p>Connecting to <b>" + htmlEscape(ssid) + "</b>...</p>"
       "<p>The setup hotspot closes about 1 minute after the device is online. "
       "Reconnect your phone to your normal Wi-Fi and check the PyroGuard app.</p>"
       "<p><small>If the password was wrong, the hotspot stays on: open http://192.168.4.1 again.</small></p></body></html>";
  webServer.send(200, "text/html", h);
  delay(300);
  wifiNetIndex = 0;
  connectNextWifi();
}

void startMdns() {
  if (mdnsStarted) return;
  String host = String("pyroguard-") + DEVICE_ID;
  host.toLowerCase();
  if (MDNS.begin(host.c_str())) {
    char svc[] = "http", proto[] = "tcp";   // writable: older cores take char*
    MDNS.addService(svc, proto, 80);
    mdnsStarted = true;
    Serial.printf("[WIFI] Network name: %s.local\n", host.c_str());
  }
}

void updateWifi() {
  if (!ENABLE_WIFI || !wifiConfigValid) return;
  if (camHostDirty) { camHostDirty = false; prefs.putString("camHost", cameraHost()); }
  const bool up = WiFi.status() == WL_CONNECTED;
  if (up) {
    if (wifiConnectedSince == 0) {
      wifiConnectedSince = millis();
      Serial.printf("[WIFI] Connected to \"%s\"  IP %s  (%d dBm)\n", WiFi.SSID().c_str(),
                    WiFi.localIP().toString().c_str(), (int)WiFi.RSSI());
      startMdns();
    }
    wifiLastOkMs = millis();
    if (wifiPortalActive && millis() - wifiConnectedSince > 60000UL) stopWifiPortal();
  } else {
    if (wifiConnectedSince) { wifiConnectedSince = 0; Serial.println("[WIFI] Disconnected - trying known networks"); }
    if (lastWifiAttempt == 0 || millis() - lastWifiAttempt >= 12000UL) connectNextWifi();
    if (!wifiPortalActive && millis() - wifiLastOkMs >= WIFI_PORTAL_AFTER_MS) startWifiPortal();
  }
  if (ENABLE_LOCAL_API && !String(DEVICE_HTTP_KEY).startsWith("REPLACE_") && strlen(DEVICE_HTTP_KEY) >= 16 &&
      (up || wifiPortalActive)) {
    if (!webStarted && up) { Serial.printf("%s IP: ", DEVICE_ID); Serial.println(WiFi.localIP()); }
    ensureWebServer();
    webServer.handleClient();
  }
}

// =====================================================
//                    COMMANDS
// =====================================================
void printHelp() {
  Serial.println("Display    : d = show the status table now (auto every 5 s), q = quiet on/off");
  Serial.println("Wi-Fi      : wifi NAME|PASSWORD = add/switch network, wifilist, wififorget, wifisetup (hotspot)");
  Serial.println("             camip 192.168.x.x = set Camera 1 address manually (normally found automatically)");
  Serial.println("Buzzer test: fire, intrusion, flame, smoke, temp, door, window, closed, startup, stop");
  Serial.println("Commands   : m = mute, t = test all, a = arm/disarm,");
  Serial.println("             50right, 50left, 10up, 10down, up, down, c = center, s = small sweep");
  Serial.println("             p = PTZ position, x = halt servos, status = JSON diagnostics, q = quiet");
  Serial.println("             link = Camera 1 link state, auto / manual = auto-follow on / off");
  Serial.println("             servo = servo diagnostics, servotest (st) = sweep both servos");
  Serial.println("             diag / contacts = sensor + reed-switch pin test; buzzcheck = buzzer test");
  Serial.println("             door invert / window invert = fix a backwards reed switch (saved)");
  Serial.println("             faults = false-fire guard state, faultreset = clear it");
}

void testSounds() {
  stopPattern();
  Serial.println("Testing all alert sounds...");
  Serial.println("1. FIRE");          playBlocking(PAT(P_FIRE), 2);
  Serial.println("2. INTRUSION");     playBlocking(PAT(P_INTRUSION), 15);
  Serial.println("3. FLAME");         playBlocking(PAT(P_FLAME), 2);
  Serial.println("4. SMOKE");         playBlocking(PAT(P_SMOKE), 2);
  Serial.println("5. HIGH TEMP");     playBlocking(PAT(P_TEMP), 2);
  Serial.println("6. DOOR OPENED");   playBlocking(PAT(P_DOOR_OPEN), 1);
  Serial.println("7. WINDOW OPENED"); playBlocking(PAT(P_WIN_OPEN), 1);
  Serial.println("8. CLOSED");        playBlocking(PAT(P_CLOSED), 1);
  Serial.println("9. ARMED");         playBlocking(PAT(P_ARM), 1);
  Serial.println("10. DISARMED");     playBlocking(PAT(P_DISARM), 1);
  Serial.println("Test done");
  startAlarmSound();                  // resume any active alarm
}

void printWiringDiagnostics() {
  Serial.printf("=== %s %s + %s INPUT DIAGNOSTICS ===\n", DEVICE_ID, PRIMARY_COVERAGE_NAME, SECOND_COVERAGE_NAME);
  Serial.printf("[CONTACT] %s GPIO%d raw=%s interpreted=%s reverse=%s\n", DOOR_LABEL, DOOR_PIN, digitalRead(DOOR_PIN)==LOW ? "LOW":"HIGH", door.open ? "OPEN":"CLOSED", doorReversed ? "yes":"no");
  Serial.printf("[CONTACT] %s GPIO%d raw=%s interpreted=%s reverse=%s\n", WINDOW_LABEL, WINDOW_PIN, digitalRead(WINDOW_PIN)==LOW ? "LOW":"HIGH", window.open ? "OPEN":"CLOSED", windowReversed ? "yes":"no");
  Serial.printf("[FLAME CHECK] Entrance GPIO%d raw=%s configured-active=%s filtered=%s (GPIO35 has NO internal pull-up)\n", FLAME_PIN, digitalRead(FLAME_PIN)==LOW ? "LOW":"HIGH", FLAME_ACTIVE_LOW ? "LOW":"HIGH", flameNow ? "DETECTED":"CLEAR");
  Serial.printf("[SMOKE] %s MQ-2 AO GPIO%d = %.0f mV (baseline %.0f mV, %+d%%)%s\n", PRIMARY_COVERAGE_NAME, MQ2_AO_PIN,
      mq2Ema[0], mq2Base[0], mq2Percent(0), mq2Ema[0] < 40 ? "  <- near 0 V: check AO wire / divider / MQ-2 5V" : "");
#if ENABLE_SECOND_BATCH
  Serial.printf("[SMOKE] %s MQ-2 AO GPIO%d = %.0f mV (baseline %.0f mV, %+d%%) filtered=%s warmup=%s\n",
      SECOND_COVERAGE_NAME, MQ2_2_AO_PIN, mq2Ema[1], mq2Base[1], mq2Percent(1),
      smokeNow2 ? "ALARM" : "CLEAR", mq2WarmedUp2 ? "DONE" : "WAIT");
  Serial.printf("SALA FLAME GPIO%d RAW=%d active=%s filtered=%s\n",
      FLAME2_PIN, digitalRead(FLAME2_PIN), FLAME2_ACTIVE_LOW ? "LOW" : "HIGH",
      flameNow2 ? "DETECTED" : "CLEAR");
#endif
  Serial.printf("DHT22 GPIO%d last read=%s\n", DHT_PIN, dhtValid ? "OK":"FAILED");
  Serial.printf("Buzzer GPIO%d configured %s; use buzzcheck to test\n", BUZZER_PIN, BUZZER_ACTIVE_LOW ? "ACTIVE LOW":"ACTIVE HIGH");
  Serial.println("[CONTACT TEST] Move each magnet near/away: pin must physically toggle LOW/HIGH. LOW = closed for reed switch connected to GND with closed contact.");
  Serial.println("[FLAME TEST] If Entrance GPIO35 stays LOW without flame, check sensor DO, 3.3V logic, module sensitivity, ambient IR, external pull-up if appropriate; DO NOT force CLEAR.");
  Serial.printf("[SECURITY CHECK] DB synced=%s arm_mode=%s door_protection=%s window_protection=%s; arm/disarm in Flutter, not by changing sensor wiring.\n", securitySynced ? "YES":"NO", armMode.c_str(), doorProtection ? "ON":"OFF", windowProtection ? "ON":"OFF");
}

void testBuzzerHardware() {
  // Temporarily suspend the current audible alarm, then resume it.
  stopPattern();
  Serial.printf("BUZZER HARDWARE TEST: two short pulses at GPIO%d\n", BUZZER_PIN);
  buzz(true); delay(250); buzz(false); delay(250);
  buzz(true); delay(250); buzz(false);
  startAlarmSound();
  Serial.println("If silent, check buzzer polarity, rated voltage/current, GND and transistor driver. A passive piezo may require PWM tone instead.");
}

void handleCommand() {
  String input = Serial.readStringUntil('\n');
  input.trim();
  // Wi-Fi commands keep the original letters (names/passwords are case-sensitive)
  if (input.startsWith("wifi ") && input.indexOf('|') > 5) {
    const int bar = input.indexOf('|');
    String ssid = input.substring(5, bar); ssid.trim();
    const String pass = input.substring(bar + 1);
    saveWifiNetwork(ssid, pass);
    wifiNetIndex = 0;
    connectNextWifi();
    return;
  }
  if (input.startsWith("camip ")) {
    String ip = input.substring(6); ip.trim();
    if (validIpText(ip)) setCameraHost(ip, "set from Serial");
    else Serial.println("[CAMERA1] Usage: camip 192.168.1.50");
    return;
  }
  input.toLowerCase();
  input.replace(" ", "");
  if (input.length() == 0) return;

  Serial.println("===================================");

  if (input == "diag" || input == "contacts") { printWiringDiagnostics(); return; }
  if (input == "wifilist") { listWifiNetworks(); return; }
  if (input == "wififorget") { forgetWifiNetworks(); return; }
  if (input == "wifisetup") { startWifiPortal(); return; }
  if (input == "d" || input == "dash" || input == "display") { printDashboard(true); return; }
  if (input == "faults" || input == "guard") { printGuardState(); return; }
  if (input == "faultreset") {
    for (int i = 0; i < 2; ++i) { flameGuard[i] = InputGuard(); smokeGuard[i] = InputGuard(); fireCandidateSince[i] = 0; }
    smokeWarmDoneAt = 0;
    Serial.println("[GUARD] Reset: inputs must read CLEAR again before they are trusted");
    return;
  }
  if (input == "doorinvert" || input == "windowinvert" || input == "contactsreset") {
    if (input == "doorinvert") doorReversed = !doorReversed;
    else if (input == "windowinvert") windowReversed = !windowReversed;
    else { doorReversed = DOOR_CONTACT_REVERSED; windowReversed = WINDOW_CONTACT_REVERSED; }
    prefs.putBool("doorRev", doorReversed);
    prefs.putBool("winRev", windowReversed);
    door.open = door.lastReading = readContact(door);
    if (window.enabled) window.open = window.lastReading = readContact(window);
    Serial.printf("[CONTACT] Saved: door reversed=%s -> now %s | window reversed=%s -> now %s\n",
                  doorReversed ? "yes" : "no", door.open ? "OPEN" : "CLOSED",
                  windowReversed ? "yes" : "no", window.open ? "OPEN" : "CLOSED");
    return;
  }
  if (input == "buzzcheck") { testBuzzerHardware(); return; }
  if (input == "gascal") {
    // Keep lighters/smoke away, then type gascal: both sensors learn clean air now.
    mq2Relearn(0, "Serial gascal");
    mq2Relearn(1, "Serial gascal");
    return;
  }
  if (input == "gas" || input == "mq2") {
    // 15 s live view: hold the (unlit) lighter at each MQ-2 and watch the mV.
    Serial.println("[GAS] Live MQ-2 readings for 15 s (mV at the ESP32 pin; ~140 mV = 0 V)...");
    const unsigned long until = millis() + 15000UL;
    while ((long)(until - millis()) > 0) {
      const float a = analogReadMilliVolts(MQ2_AO_PIN), b = analogReadMilliVolts(MQ2_2_AO_PIN);
      Serial.printf("[GAS] %s GPIO%d = %4.0f mV (%s)   %s GPIO%d = %4.0f mV (%s)\n",
                    PRIMARY_COVERAGE_NAME, MQ2_AO_PIN, a, mq2DigitalMode[0] ? "DO" : "AO",
                    SECOND_COVERAGE_NAME, MQ2_2_AO_PIN, b, mq2DigitalMode[1] ? "DO" : "AO");
      delay(500);
    }
    Serial.println("[GAS] done. Stuck near 140 mV = no signal: check the AO wire / divider / MQ-2 VCC on 5V (VIN).");
    return;
  }
  if (input == "auto") { setAutoFollow(true, "Serial"); return; }
  if (input == "manual") { setAutoFollow(false, "Serial"); return; }
  if (input == "x" || input == "halt") { haltServos(); return; }
  if (input == "link") {
    Serial.printf("[CAMERA1] host=%s link=%s accepted=%s last_http=%d motion=%s auto=%s%s moves=%lu\n",
                  cameraHost().c_str(), camera1LinkFresh() ? "OK" : "DOWN",
                  camera1LinkAccepted ? "yes" : "no", camera1LastHttpStatus,
                  camera1MotionDetected ? "DETECTED" : "clear",
                  autoFollowEnabled ? "ON" : "OFF", autoFollowPaused() ? " (paused by manual)" : "",
                  (unsigned long)autoMoveCount);
    return;
  }

  // ---- Buzzer test by sensor name (checked first) ----
  if (input == "stop") {
    stopPattern();
    Serial.println("Sound stopped");
    startAlarmSound();                // a real alarm keeps sounding if one is active
  }
  else if (playSoundByName(input)) {
    // sound started inside playSoundByName()
  }

  // ---- Other commands ----
  else if (input == "m" || input == "mute") {
    if (activeAlarm == A_NONE && !fireNow2 && !smokeNow2 && !flameNow2 && !tempNow2) {
      Serial.println("No active sensor alarm to mute");
    } else {
      muted = true;
      stopPattern();
      stopPattern2();
      Serial.println("[MUTE] Both room buzzers silenced temporarily. Sensor measurements and cloud warnings REMAIN ACTIVE. A changed Entrance alarm may re-enable sound.");
    }
  }
  else if (input == "t" || input == "test") {
    testSounds();
  }
  else if (input == "servotest" || input == "st") {
    servoSelfTest();
  }
  else if (input == "servo") {
    printServoDiagnostics();
  }
  else if (input == "a" || input == "arm") {
    if (ENABLE_SECURITY_SYNC && securitySynced) {
      Serial.println("[SECURITY] Note: the app controls ARM/DISARM; the next sync will apply the app's mode.");
    }
    armed = !armed;
    if (armed) {
      Serial.println("System ARMED - opening a door/window triggers INTRUSION");
      if (door.open)   Serial.println("Note: the DOOR is currently OPEN");
      if (window.enabled && window.open) Serial.println("Note: the WINDOW is currently OPEN");
      chime(PAT(P_ARM));
    } else {
      intrusion = false;
      updateAlarm();
      Serial.println("System DISARMED");
      chime(PAT(P_DISARM));
    }
  }
  else if (input == "c" || input == "center") {
    Serial.println("Centering...");
    moveTo(PAN_CENTER);
    moveTiltTo(TILT_CENTER);
  }
  else if (input == "s" || input == "sweep") {
    Serial.println("Small pan/tilt test target queued (use center to return)...");
    moveTo(PAN_CENTER - 15);
    moveTiltTo(TILT_CENTER - 10);
    Serial.println("Test target queued; use center to return");
  }
  else if (input == "status" || input == "json") {
    Serial.println(jsonStatus());
  }
  else if (input == "up" || input == "down" || input.endsWith("up") || input.endsWith("down")) {
    bool up = input.endsWith("up");
    int deg = extractNumber(input);
    tiltBy(deg > 0 ? deg : PTZ_JOG_DEG, up);
  }
  else if (input == "p" || input == "pos") {
    printPosition();
  }
  else if (input == "q" || input == "quiet") {
    quietMode = !quietMode;
    Serial.println(quietMode ? "Sensor printing PAUSED (type q to resume)"
                             : "Sensor printing RESUMED");
  }
  else if (input.indexOf("right") >= 0 || input.startsWith("r")) {
    int deg = extractNumber(input);
    if (deg > 0) turn(deg, true);
    else Serial.println("Add a number, e.g. 50right");
  }
  else if (input.indexOf("left") >= 0 || input.startsWith("l")) {
    int deg = extractNumber(input);
    if (deg > 0) turn(deg, false);
    else Serial.println("Add a number, e.g. 50left");
  }
  else {
    Serial.println("Unknown command.");
    printHelp();
  }
  Serial.println("===================================");
}

// =====================================================
//                    FALSE-FIRE GUARD
// =====================================================
void setGuardFault(InputGuard& g, const char* reason, const char* what, int room) {
  if (!g.fault) {
    Serial.printf("[GUARD] %s %s input FAULT: %s -> ignored as a fire source\n",
                  room == 0 ? PRIMARY_COVERAGE_NAME : SECOND_COVERAGE_NAME, what, reason);
  }
  g.fault = true;
  g.faultReason = reason;
  g.faultSince = millis();
}

// Filters one physical flame reading. Returns the value the debouncer may use.
bool guardFlame(int room, bool physicalActive, bool smokeInRoom, bool confirmedOn) {
  InputGuard& g = flameGuard[room];
  const unsigned long now = millis();
  // Chatter: count raw changes per window.
  if (g.windowStart == 0) { g.windowStart = now; g.lastRaw = physicalActive; }
  if (physicalActive != g.lastRaw) { g.lastRaw = physicalActive; g.changes++; }
  if (now - g.windowStart >= FLAME_CHATTER_WINDOW_MS) {
    if (g.changes > FLAME_CHATTER_MAX) setGuardFault(g, "flickering (noise / loose wire / no pull-up)", "FLAME", room);
    g.changes = 0;
    g.windowStart = now;
  }
  // Trust only after the input has been seen CLEAR for a while.
  if (!physicalActive) {
    if (g.clearSince == 0) g.clearSince = now;
    if (!g.trusted && now - g.clearSince >= INPUT_TRUST_CLEAR_MS) {
      g.trusted = true;
      Serial.printf("[GUARD] %s FLAME input trusted (read CLEAR)\n", room == 0 ? PRIMARY_COVERAGE_NAME : SECOND_COVERAGE_NAME);
    }
  } else {
    g.clearSince = 0;
  }
  // Stuck ON for minutes with no smoke in that room.
  if (confirmedOn) {
    if (g.activeSince == 0) g.activeSince = now;
    if (!smokeInRoom && now - g.activeSince >= FLAME_STUCK_MS) setGuardFault(g, "ON for 2+ minutes without smoke", "FLAME", room);
  } else {
    g.activeSince = 0;
  }
  // Fault clears after the hold time once the input is quiet and clear.
  if (g.fault && now - g.faultSince >= FLAME_FAULT_HOLD_MS && !physicalActive && g.changes <= 2 &&
      g.clearSince && now - g.clearSince >= INPUT_TRUST_CLEAR_MS) {
    g.fault = false;
    g.activeSince = 0;
    Serial.printf("[GUARD] %s FLAME fault cleared\n", room == 0 ? PRIMARY_COVERAGE_NAME : SECOND_COVERAGE_NAME);
  }
  return physicalActive && g.trusted && !g.fault;
}

bool guardSmoke(int room, bool physicalActive, bool warmedUp) {
  InputGuard& g = smokeGuard[room];
  const unsigned long now = millis();
  if (!warmedUp) { g.trusted = false; g.clearSince = 0; return false; }
  if (smokeWarmDoneAt == 0) smokeWarmDoneAt = now;
  if (!physicalActive) {
    if (g.clearSince == 0) g.clearSince = now;
    if (!g.trusted && now - g.clearSince >= INPUT_TRUST_CLEAR_MS) {
      g.trusted = true;
      if (g.fault) Serial.printf("[GUARD] %s SMOKE fault cleared\n", room == 0 ? PRIMARY_COVERAGE_NAME : SECOND_COVERAGE_NAME);
      g.fault = false;
    }
  } else {
    g.clearSince = 0;
  }
  if (!g.trusted && !g.fault && now - smokeWarmDoneAt >= SMOKE_NEVER_CLEAR_MS) {
    setGuardFault(g, "never cleared after warm-up (adjust the MQ-2 sensitivity knob / check DO polarity)", "SMOKE", room);
  }
  return physicalActive && g.trusted && !g.fault;
}

// FIRE = smoke AND flame confirmed in the SAME room, together for FIRE_CONFIRM_MS.
bool evaluateFire(int room, bool smoke, bool flame) {
  const bool candidate = DEMO_FLAME_ALONE_IS_FIRE
      ? (flame && !flameGuard[room].fault)                       // demo: lighter flame alone
      : (smoke && flame && !flameGuard[room].fault && !smokeGuard[room].fault);
  if (!candidate) { fireCandidateSince[room] = 0; return false; }
  if (fireCandidateSince[room] == 0) fireCandidateSince[room] = millis();
  return millis() - fireCandidateSince[room] >= FIRE_CONFIRM_MS;
}

void updateFireState() {
  const bool next = evaluateFire(0, smokeNow, flameNow);
  if (next != fireNow) {
    fireNow = next;
    Serial.printf("[FIRE] %s %s\n", PRIMARY_COVERAGE_NAME, fireNow ? "CONFIRMED (smoke + flame sustained)" : "cleared");
    updateAlarm();
  }
}

void updateFireState2() {
#if ENABLE_SECOND_BATCH
  const bool next = evaluateFire(1, smokeNow2, flameNow2);
  if (next != fireNow2) {
    fireNow2 = next;
    Serial.printf("[FIRE] %s %s\n", SECOND_COVERAGE_NAME, fireNow2 ? "CONFIRMED (smoke + flame sustained)" : "cleared");
    updateSecondRoomAlarm();
  }
#endif
}

void printGuardState() {
  for (int i = 0; i < 2; ++i) {
    Serial.printf("[GUARD] %s: flame %s%s%s | smoke %s%s%s | fire=%s\n",
      i == 0 ? PRIMARY_COVERAGE_NAME : SECOND_COVERAGE_NAME,
      flameGuard[i].trusted ? "trusted" : "NOT YET TRUSTED",
      flameGuard[i].fault ? " FAULT: " : "", flameGuard[i].fault ? flameGuard[i].faultReason : "",
      smokeGuard[i].trusted ? "trusted" : "NOT YET TRUSTED",
      smokeGuard[i].fault ? " FAULT: " : "", smokeGuard[i].fault ? smokeGuard[i].faultReason : "",
      (i == 0 ? fireNow : fireNow2) ? "YES" : "no");
  }
}

// =====================================================
//                    SENSORS
// =====================================================
// GPIO35 is input-only and has no internal pull-up. The flame DO module MUST
// drive a reliable 0..3.3V logic signal (never 5V directly). If RAW never
// changes, no software polarity setting can fix wiring/sensitivity problems.
void updateFlameInput() {
  const unsigned long now = millis();

  const int raw = digitalRead(FLAME_PIN);

  // Most LM393 flame sensor modules output LOW
  // when the comparator detects flame/infrared.
  static unsigned long lastBlinkOn = 0;
  const bool blinkOn = FLAME_ACTIVE_LOW ? (raw == LOW) : (raw == HIGH);
  if (blinkOn) lastBlinkOn = now;
  const bool physicalDetected =
      blinkOn || (lastBlinkOn && now - lastBlinkOn < FLAME_FLICKER_BRIDGE_MS);
  // False-fire guard: untrusted / faulty inputs never count as flame.
  const bool rawDetected = guardFlame(0, physicalDetected, smokeNow, flameNow);

  // Restart confirmation when the input changes.
  if (rawDetected != flameCandidate) {
    flameCandidate = rawDetected;
    flameCandidateSince = now;
  }

  const unsigned long confirmTime =
      rawDetected
      ? FLAME_CONFIRM_MS
      : FLAME_CLEAR_MS;

  if (rawDetected != flameNow &&
      now - flameCandidateSince >= confirmTime) {

    flameNow = rawDetected;

    // Fire requires both smoke and flame, sustained (see updateFireState).
    updateFireState();

    Serial.printf("[FLAME] %s %s (GPIO%d %s)\n", PRIMARY_COVERAGE_NAME,
      flameNow ? "FLAME DETECTED" : "flame cleared", FLAME_PIN, raw == LOW ? "LOW" : "HIGH");

    updateAlarm();
  }

  if (VERBOSE_RAW_LOGS && now - lastFlameRawLog >= FLAME_RAW_LOG_MS) {
    lastFlameRawLog = now;

    Serial.printf(
      "[FLAME RAW] GPIO%d=%d "
      "candidate=%s confirmed=%s\n",
      FLAME_PIN,
      raw,
      rawDetected ? "ACTIVE" : "CLEAR",
      flameNow ? "DETECTED" : "CLEAR"
    );
  }
}

// Sample the MQ-2 digital comparator frequently rather than once per DHT cycle.
// IMPORTANT: the MQ-2 DO is only a threshold signal, not calibrated gas ppm.
void updateSmokeInput() {
  const unsigned long now = millis();
  if (now - lastSmokeSample < 20) return;
  lastSmokeSample = now;
  mq2WarmedUp = now >= MQ2_WARMUP_MS;
  const int smokeRawEntrance = mq2VirtualDO(0, MQ2_AO_PIN, mq2WarmedUp);   // analog AO
  if (!mq2WarmedUp) {
    guardSmoke(0, false, false);
    smokeNow = false;
    smokeCandidate = false;
    smokeCandidateSince = now;
    return;
  }
  const bool detected = guardSmoke(0, smokeRawEntrance == LOW, mq2WarmedUp);
  static unsigned long lastEntranceRawLog = 0;
  if (VERBOSE_RAW_LOGS && now - lastEntranceRawLog >= 2000UL) {
    lastEntranceRawLog = now;
    Serial.printf("[ENTRANCE RAW] MQ2 GPIO%d=%d active=LOW warm=%s filtered=%s | FLAME GPIO%d=%d active=%s filtered=%s | DHT=%s\n",
      MQ2_DO_PIN, smokeRawEntrance, mq2WarmedUp ? "YES" : "NO",
      mq2WarmedUp ? (smokeNow ? "ALARM" : "CLEAR") : "WARMUP",
      FLAME_PIN, digitalRead(FLAME_PIN), FLAME_ACTIVE_LOW ? "LOW" : "HIGH",
      flameNow ? "DETECTED" : "CLEAR", dhtValid ? "OK" : "INVALID");
  }
  if (detected != smokeCandidate) {
    smokeCandidate = detected;
    smokeCandidateSince = now;
  }
  if (detected != smokeNow && now - smokeCandidateSince >=
      (detected ? SMOKE_CONFIRM_MS : SMOKE_CLEAR_MS)) {
    smokeNow = detected;
    updateFireState();
    Serial.printf("[SMOKE] %s %s (%.0f mV, %+d%%)\n", PRIMARY_COVERAGE_NAME,
                  smokeNow ? "SMOKE / GAS DETECTED" : "smoke cleared", mq2Ema[0], mq2Percent(0));
    updateAlarm();
  }
}

// Continuous Sala flame monitoring; prevents noisy DO transitions from
// generating false positives on the slower two-second DHT sampling loop.
void updateFlameInputSecondRoom() {
#if ENABLE_SECOND_BATCH
  const int raw = digitalRead(FLAME2_PIN);
  static unsigned long lastBlinkOn2 = 0;
  const bool blinkOn2 = raw == (FLAME2_ACTIVE_LOW ? LOW : HIGH);
  if (blinkOn2) lastBlinkOn2 = millis();
  const bool detected = guardFlame(1, blinkOn2 || (lastBlinkOn2 && millis() - lastBlinkOn2 < FLAME_FLICKER_BRIDGE_MS),
                                   smokeNow2, flameNow2);
  const unsigned long now = millis();
  if (detected != flame2Candidate) {
    flame2Candidate = detected;
    flame2CandidateSince = now;
  }
  const unsigned long settle = detected ? FLAME2_CONFIRM_MS : FLAME2_CLEAR_MS;
  if (detected != flameNow2 && now - flame2CandidateSince >= settle) {
    flameNow2 = detected;
    updateFireState2();
    Serial.printf("[FLAME] %s %s (GPIO%d %s)\n", SECOND_COVERAGE_NAME,
      flameNow2 ? "FLAME DETECTED" : "flame cleared", FLAME2_PIN, raw == LOW ? "LOW" : "HIGH");
    updateSecondRoomAlarm();
  }
#endif
}

// Filter Sala's MQ-2 digital comparator on the fast loop, just like Entrance.
// This removes single-sample glitches but DOES NOT reclassify a persistent LOW
// as clear: a stuck-low input or truly asserted comparator must be investigated.
void updateSmokeInputSecondRoom() {
#if ENABLE_SECOND_BATCH
  const unsigned long now = millis();
  if (now - lastSmoke2Sample < 25UL) return;
  lastSmoke2Sample = now;
  mq2WarmedUp2 = now >= MQ2_WARMUP_MS;
  const int raw = mq2VirtualDO(1, MQ2_2_AO_PIN, now >= MQ2_WARMUP_MS);   // analog AO
  const bool detected = guardSmoke(1, raw == (SMOKE2_ACTIVE_LOW ? LOW : HIGH), mq2WarmedUp2);
  if (!mq2WarmedUp2) {
    smokeNow2 = false;
    smoke2Candidate = false;
    smoke2CandidateSince = now;
  } else {
    if (detected != smoke2Candidate) {
      smoke2Candidate = detected;
      smoke2CandidateSince = now;
    }
    if (detected != smokeNow2 &&
        now - smoke2CandidateSince >= (detected ? SMOKE2_CONFIRM_MS : SMOKE2_CLEAR_MS)) {
      smokeNow2 = detected;
      updateFireState2();
      Serial.printf("[SMOKE] %s %s (%.0f mV, %+d%%)\n", SECOND_COVERAGE_NAME,
                    smokeNow2 ? "SMOKE / GAS DETECTED" : "smoke cleared", mq2Ema[1], mq2Percent(1));
      updateSecondRoomAlarm();
    }
  }
  if (VERBOSE_RAW_LOGS && now - lastSalaRawLog >= SALA_RAW_LOG_MS) {
    lastSalaRawLog = now;
    Serial.printf("[SALA RAW] MQ2 GPIO%d=%d active=%s warm=%s filtered=%s | FLAME GPIO%d=%d active=%s filtered=%s\n",
      MQ2_2_DO_PIN, raw, SMOKE2_ACTIVE_LOW ? "LOW" : "HIGH",
      mq2WarmedUp2 ? "YES" : "NO", mq2WarmedUp2 ? (smokeNow2 ? "ALARM" : "CLEAR") : "WARMUP",
      FLAME2_PIN, digitalRead(FLAME2_PIN), FLAME2_ACTIVE_LOW ? "LOW" : "HIGH",
      flameNow2 ? "DETECTED" : "CLEAR");
    if (mq2WarmedUp2 && smokeNow2 && flameNow2) {
      Serial.println("[SALA WARNING] Both digital alarm inputs asserted. Check the physical room and module wiring/polarity; do NOT assume a fire or suppress these readings.");
    }
  }
#endif
}

void readSensorsSecondRoom() {
#if ENABLE_SECOND_BATCH
  const float t=dht2.readTemperature();
  const float h=dht2.readHumidity();
  dht2Valid = isfinite(t) && isfinite(h) && t >= -40 && t <= 80 && h >= 0 && h <= 100;
  lastTemp2=t; lastHum2=h;
  lastSensorSample2=millis();
  // Flame AND smoke on this room are continuously sampled and independently
  // debounced in loop(). Never overwrite filtered sensor state with a single DO read.
  // flameNow2 is updated by updateFlameInputSecondRoom().
  tempNow2=dht2Valid && t>TEMP_THRESHOLD;
  updateFireState2();
  updateSecondRoomAlarm();
#endif
}
void readSensors() {
  float temp = dht.readTemperature();
  float hum  = dht.readHumidity();

  dhtValid = isfinite(temp) && isfinite(hum) && temp >= -40 && temp <= 80 && hum >= 0 && hum <= 100;
  lastTemp = temp;
  lastHum = hum;
  lastSensorSample = millis();
  bool warmedUp = millis() > MQ2_WARMUP_MS;
  mq2WarmedUp = warmedUp;
  // Smoke state is sampled and debounced independently in updateSmokeInput().
  // Flame input is sampled continuously by updateFlameInput(); use filtered state.
  tempNow  = dhtValid && temp > TEMP_THRESHOLD;
  updateFireState();

  updateAlarm();

  printDashboard(false);
}

// ---------------------------------------------------------------
//  SERIAL MONITOR STATUS TABLE (every DASHBOARD_INTERVAL_MS, "d")
// ---------------------------------------------------------------
extern volatile int lastSyncHttp;
extern volatile unsigned long lastSyncOkMs;

void printRoomRow(const char* name, int idx, bool dhtOk, float t, float h, bool warm,
                  bool smoke, bool flame, bool fire, bool hot) {
  char th[20], sm[32];
  if (dhtOk) snprintf(th, sizeof(th), "%5.1f C %3.0f %%", t, h);
  else       snprintf(th, sizeof(th), " DHT22 FAILED ");
  const bool guardFault = flameGuard[idx].fault || smokeGuard[idx].fault;
  if (!warm)
    snprintf(sm, sizeof(sm), "warming %3lus", (unsigned long)((MQ2_WARMUP_MS - millis()) / 1000UL));
  else if (smokeGuard[idx].fault)
    snprintf(sm, sizeof(sm), "SENSOR FAULT");
  else if (mq2NoSignal[idx] && !smoke)
    snprintf(sm, sizeof(sm), "NO SIGNAL 0V %4.0fmV", mq2Ema[idx]);
  else if (mq2DigitalMode[idx])
    snprintf(sm, sizeof(sm), "%-6s DO %4.0fmV", smoke ? "SMOKE!" : "clear", mq2Ema[idx]);
  else
    snprintf(sm, sizeof(sm), "%-6s %4.0fmV %+3d%%", smoke ? "SMOKE!" : "clear", mq2Ema[idx], mq2Percent(idx));
  const char* status = fire ? "*** FIRE ***" : (flame || smoke || hot) ? "ALERT"
                     : guardFault ? "CHECK SENSOR" : !dhtOk ? "DHT FAIL" : !warm ? "WARMING UP" : "OK";
  Serial.printf(" %-15s| %-15s| %-22s| %-9s| %s\n", name, th, sm,
                flameGuard[idx].fault ? "FAULT" : (flame ? "FLAME!" : "none"), status);
}

// Flame / smoke as reported to the app: ON now, or ON within the last
// HAZARD_REPORT_HOLD_MS (short lighter tests still reach the dashboard).
bool heldReport(bool active, unsigned long& lastOn) {
  if (active) lastOn = millis();
  return active || (lastOn && millis() - lastOn < HAZARD_REPORT_HOLD_MS);
}
bool reportFlame(int idx) {
  static unsigned long lastOn[2] = {0, 0};
  return heldReport(idx == 0 ? flameNow : flameNow2, lastOn[idx]);
}
bool reportSmoke(int idx) {
  static unsigned long lastOn[2] = {0, 0};
  return heldReport(idx == 0 ? smokeNow : smokeNow2, lastOn[idx]);
}

// Every state the app/dashboard shows, packed into bits. Any change = send now.
uint32_t stateSignature() {
  uint32_t s = 0;
  s |= (uint32_t)door.open << 0;
  s |= (uint32_t)(window.enabled && window.open) << 1;
  s |= (uint32_t)smokeNow << 2;   s |= (uint32_t)flameNow << 3;   s |= (uint32_t)fireNow << 4;
  s |= (uint32_t)tempNow << 5;    s |= (uint32_t)smokeNow2 << 6;  s |= (uint32_t)flameNow2 << 7;
  s |= (uint32_t)fireNow2 << 8;   s |= (uint32_t)tempNow2 << 9;   s |= (uint32_t)intrusion << 10;
  s |= (uint32_t)armed << 11;     s |= (uint32_t)mq2WarmedUp << 12; s |= (uint32_t)muted << 13;
  s |= (uint32_t)dhtValid << 14;  s |= (uint32_t)dht2Valid << 15;
  s |= (uint32_t)activeAlarm << 16;
  // Buzzer ON/OFF (as reported to the app) is also an urgent change, so the
  // dashboard shows ON as soon as it sounds and OFF ~6 s after it stops.
  s |= (uint32_t)buzzerReportActive() << 20;
  s |= (uint32_t)buzzer2ReportActive() << 21;
  s |= (uint32_t)reportFlame(0) << 22;  s |= (uint32_t)reportSmoke(0) << 23;
  s |= (uint32_t)reportFlame(1) << 24;  s |= (uint32_t)reportSmoke(1) << 25;
  return s;
}

void printDashboard(bool force) {
  static unsigned long lastShown = 0;
  static uint32_t lastSig = 0xFFFFFFFF;
  const unsigned long now = millis();
  const bool hazard = fireNow || fireNow2 || intrusion;
  const uint32_t sig = stateSignature();
  const bool changed = sig != lastSig;
  lastSig = sig;
  if (!force && !changed) {
    if (now - lastShown < DASHBOARD_INTERVAL_MS) return;
    if (quietMode && !hazard) return;
  }
  lastShown = now;
  const unsigned long up = now / 1000UL;

  Serial.println();
  Serial.println("==============================================================================");
  Serial.printf(" PyroGuard %s  %s (%s + %s)   uptime %02lu:%02lu:%02lu\n", BATCH_NAME, DEVICE_ID,
                PRIMARY_COVERAGE_NAME, SECOND_COVERAGE_NAME, up / 3600UL, (up / 60UL) % 60UL, up % 60UL);
  Serial.println("------------------------------------------------------------------------------");
  Serial.println(" ROOM           | TEMP / HUMIDITY| SMOKE (MQ-2 AO)       | FLAME    | STATUS");
  Serial.println("------------------------------------------------------------------------------");
  printRoomRow(PRIMARY_COVERAGE_NAME, 0, dhtValid, lastTemp, lastHum, mq2WarmedUp,
               smokeNow, flameNow, fireNow, tempNow);
#if ENABLE_SECOND_BATCH
  printRoomRow(SECOND_COVERAGE_NAME, 1, dht2Valid, lastTemp2, lastHum2, mq2WarmedUp2,
               smokeNow2, flameNow2, fireNow2, tempNow2);
#endif
  Serial.println("------------------------------------------------------------------------------");
  Serial.printf(" %-16s: %-8s (GPIO%d %s)\n", DOOR_LABEL, door.open ? "OPEN" : "closed",
                DOOR_PIN, digitalRead(DOOR_PIN) == LOW ? "LOW" : "HIGH");
  if (window.enabled)
    Serial.printf(" %-16s: %-8s (GPIO%d %s)\n", WINDOW_LABEL, window.open ? "OPEN" : "closed",
                  WINDOW_PIN, digitalRead(WINDOW_PIN) == LOW ? "LOW" : "HIGH");

  char syncText[48];
  if (lastSyncOkMs) snprintf(syncText, sizeof(syncText), "app sync OK %lus ago", (now - lastSyncOkMs) / 1000UL);
  else if (lastSyncHttp) snprintf(syncText, sizeof(syncText), "app sync FAILED (HTTP %d)", (int)lastSyncHttp);
  else snprintf(syncText, sizeof(syncText), "app sync: waiting");
  Serial.printf(" %-16s: %s%s%s | door %s, window %s | %s\n", "Security",
                armed ? "ARMED" : "DISARMED", armed ? " " : "", armed ? armMode.c_str() : "",
                doorProtection ? "ON" : "OFF", windowProtection ? "ON" : "OFF", syncText);
  Serial.printf(" %-16s: %s%s\n", "Alarm",
                activeAlarm == A_NONE ? "none" : ALARM_NAMES[activeAlarm],
                (muted && activeAlarm != A_NONE) ? " (muted)" : "");
  if (WiFi.status() == WL_CONNECTED)
    Serial.printf(" %-16s: WiFi OK %s (%d dBm) | cloud uploads %lu ok / %lu failed\n", "Network",
                  WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(),
                  cloudUploadSuccesses, cloudUploadFailures);
  else
    Serial.printf(" %-16s: WiFi NOT connected (%s) - alarms still work\n", "Network", WIFI_SSID);
  if (fireNow || fireNow2) Serial.println(" >>> FIRE CONFIRMED (smoke + flame) - VERIFY IN PERSON <<<");
  else if (intrusion)      Serial.println(" >>> INTRUSION: door/window opened while ARMED <<<");
  Serial.println("==============================================================================");
}


// Supabase sensor-ingest expects


// Supabase sensor-ingest expects real device measurements; unavailable sensor
// readings are represented by null, never invented as zero or NORMAL.
String jsonEscape(const String& text);  // defined below
String roomJson(const char* key, bool dhtOk, float t, float h, unsigned long sampleAt, bool warm,
                bool smoke, bool flame, bool fire, bool buzzing, int idx) {
  String j = "{\"room_key\":\"" + String(key) + "\"";
  j += ",\"sample_age_ms\":" + String(sampleAt ? millis() - sampleAt : 0UL);
  j += ",\"temperature\":" + (dhtOk ? String(t, 2) : String("null"));
  j += ",\"humidity\":" + (dhtOk ? String(h, 2) : String("null"));
  // MQ-2 AO reading in mV (smoothed), so the app shows the gas level rising.
  j += ",\"smoke_raw\":" + (warm && !smokeGuard[idx].fault ? String((int)mq2Ema[idx]) : String("null"));
  j += ",\"smoke_rise_mv\":" + (warm ? String((int)(mq2Ema[idx] - mq2Base[idx])) : String("null"));
  j += ",\"smoke_detected\":" + String(!warm || smokeGuard[idx].fault ? "null" : (smoke ? "true" : "false"));
  const bool noSignal = warm && !smoke && mq2NoSignal[idx];
  j += ",\"smoke_status\":\"" + String(!warm ? "WARMUP" : (smokeGuard[idx].fault || noSignal) ? "FAULT" : (smoke ? "ALARM" : "CLEAR")) + "\"";
  j += ",\"smoke_wiring\":\"" + String(mq2DigitalMode[idx] ? "DO" : noSignal ? "NO_SIGNAL" : "AO") + "\"";
  j += ",\"flame_detected\":" + String(flame ? "true" : "false");
  j += ",\"fire_confirmed\":" + String(fire ? "true" : "false");
  j += ",\"flame_fault\":" + String(flameGuard[idx].fault ? "true" : "false");
  j += ",\"smoke_fault\":" + String(smokeGuard[idx].fault ? "true" : "false");  // "no signal" is shown via status only
  j += ",\"buzzer_active\":" + String(buzzing ? "true" : "false") + "}";
  return j;
}

String cloudJson() {
  String j;
  j.reserve(1400);
  j = "{\"device_id\":\"" + String(DEVICE_ID) + "\",\"room_key\":\"" + String(ROOM_KEY) + "\"";
  j += ",\"temperature\":" + (dhtValid ? String(lastTemp, 2) : String("null"));
  j += ",\"humidity\":" + (dhtValid ? String(lastHum, 2) : String("null"));
  j += ",\"sample_age_ms\":" + String(millis()-lastSensorSample);
  j += ",\"smoke_raw\":" + (mq2WarmedUp ? String((int)mq2Ema[0]) : String("null")); // MQ-2 AO, mV
  j += ",\"smoke_detected\":";
  j += mq2WarmedUp ? (reportSmoke(0) ? "true" : "false") : "null";
  j += ",\"smoke_status\":\"";
  j += mq2WarmedUp ? (reportSmoke(0) ? "ALARM" : "CLEAR") : "WARMUP";
  j += "\"";
  j += ",\"flame_detected\":" + String(reportFlame(0) ? "true" : "false");
  j += ",\"buzzer_active\":" + String(buzzerReportActive() ? "true" : "false");
  j += ",\"door_open\":" + String(door.open ? "true" : "false");
  j += ",\"window_open\":" + String(window.open ? "true" : "false");
  // Real applied security state and contacts.
  j += ",\"system_armed\":" + String(armed ? "true" : "false");
  j += ",\"system_mode\":\"" + jsonEscape(armMode) + "\"";
  j += ",\"intrusion\":" + String(intrusion ? "true" : "false");
  j += ",\"motion_detected\":" + String((camera1LinkFresh() && camera1MotionDetected) ? "true" : "false");
  j += ",\"door_raw\":" + String(digitalRead(DOOR_PIN));
  j += ",\"window_raw\":" + String(USE_WINDOW ? digitalRead(WINDOW_PIN) : -1);
  j += ",\"firmware\":\"" FIRMWARE_VERSION "\"";
  j += ",\"rooms\":[" + roomJson(ROOM_KEY, dhtValid, lastTemp, lastHum, lastSensorSample, mq2WarmedUp,
                               reportSmoke(0), reportFlame(0), fireNow, buzzerReportActive(), 0);
#if ENABLE_SECOND_BATCH
  j += "," + roomJson(SECOND_ROOM_KEY, dht2Valid, lastTemp2, lastHum2, lastSensorSample2, mq2WarmedUp2,
                      reportSmoke(1), reportFlame(1), fireNow2, buzzer2ReportActive(), 1);
#endif
  j += "]";
  j += "}";
  return j;
}
// Keep the TLS client in static storage rather than allocating it on loop stack.
static WiFiClientSecure cloudTls;
static bool cloudTimeReady = false;
static unsigned long lastCloudDiagnostic = 0;

void printCloudDiagnostics() {
  if (!ENABLE_CLOUD_DIAGNOSTICS || millis() - lastCloudDiagnostic < HEALTH_INTERVAL_MS) return;
  lastCloudDiagnostic = millis();
  Serial.printf("[HEALTH] uptime=%lus heap=%u min_heap=%u wifi=%s ip=%s cloud_key=%d sensor_age=%lums\n",
    millis() / 1000UL, (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMinFreeHeap(),
    WiFi.status() == WL_CONNECTED ? "OK" : "DOWN", WiFi.localIP().toString().c_str(),
    (int)cloudKeyValid, lastSensorSample ? millis()-lastSensorSample : 0UL);
  Serial.printf("[HEALTH] security: %s (%s) synced=%s door_protect=%s window_protect=%s intrusion=%s\n",
    armed ? "ARMED" : "DISARMED", armMode.c_str(), securitySynced ? "yes" : "no",
    doorProtection ? "on" : "off", windowProtection ? "on" : "off", intrusion ? "YES" : "no");
  Serial.printf("[HEALTH] sensors: dht=%s temp=%.1f hum=%.1f mq2=%s smoke=%s flame=%s door=%s window=%s\n",
    dhtValid ? "OK" : "FAIL", lastTemp, lastHum, mq2WarmedUp ? "READY" : "WARMUP",
    smokeNow ? "YES" : "no", flameNow ? "YES" : "no", door.open ? "OPEN" : "closed",
    window.enabled ? (window.open ? "OPEN" : "closed") : "n/a");
#if ENABLE_SECOND_BATCH
  Serial.printf("[HEALTH] SALA set2: dht=%s temp=%.1f hum=%.1f mq2=%s smoke=%s flame=%s raw_flame_gpio%d=%s age=%lums\n",
    dht2Valid ? "OK" : "FAIL", lastTemp2, lastHum2,
    mq2WarmedUp2 ? "READY" : "WARMUP", smokeNow2 ? "YES" : "no",
    flameNow2 ? "YES" : "no", FLAME2_PIN,
    digitalRead(FLAME2_PIN) == LOW ? "LOW" : "HIGH",
    lastSensorSample2 ? millis() - lastSensorSample2 : 0UL);
#endif
  Serial.printf("[HEALTH] servo: attached=%s pan=%d/%d tilt=%d/%d | cam1 link=%s motion=%s auto=%s%s moves=%lu\n",
    servosAttached ? (panServoOk && tiltServoOk ? "OK" : "FAILED") : (servoPowerSafe ? "WAITING (power-safe)" : "pending"),
    currentAngle, targetPan, currentTilt, targetTilt,
    camera1LinkFresh() ? "OK" : "DOWN", camera1MotionDetected ? "YES" : "no",
    autoFollowEnabled ? "ON" : "OFF", autoFollowPaused() ? "(paused)" : "", (unsigned long)autoMoveCount);
  Serial.printf("[HEALTH] cloud: sensor ok=%lu fail=%lu | records ok=%lu fail=%lu | stack free link=%u cloud=%u\n",
    cloudUploadSuccesses, cloudUploadFailures, systemRecordOk, systemRecordFailed,
    cameraLinkTaskHandle ? (unsigned)uxTaskGetStackHighWaterMark(cameraLinkTaskHandle) : 0U,
    cloudTaskHandle ? (unsigned)uxTaskGetStackHighWaterMark(cloudTaskHandle) : 0U);
}

// =====================================================================
// CLOUD WORKER - every HTTPS call runs on its own task, never in loop(),
// so sensors, alarms, servos and the local API never pause.
//   sensor readings  -> sensor-ingest  (every 5 s)
//   system records   -> device-command:
//       device_heartbeats          every 20 s  (app "HARDWARE CONNECTED")
//       pyroguard_camera_telemetry every 15 s  + when motion starts/stops
//       ptz_state                  every 15 s  + right after a move ends
//       event_history  MOTION      when Camera 1 motion starts (>= 30 s apart)
// Supabase is the source of truth; the local MySQL sync worker (tables.json)
// mirrors all of these tables into MySQL.
// =====================================================================
static SemaphoreHandle_t cloudMutex = nullptr;
static CloudSlot sensorSlot, heartbeatSlot, cameraSlot, ptzSlot, syncSlot;
static const int EVENT_QUEUE_SIZE = 8;   // events + command acknowledgements
static String eventQueue[EVENT_QUEUE_SIZE];
static int eventQueueCount = 0;
static volatile bool cloudInFlight = false;     // a sensor upload is queued/in flight
static volatile unsigned long lastCloudSuccessMs = 0;

// POST with a kept-alive TLS session; one retry on a dropped connection.
int cloudPost(const char* url, const char* keyHeader, const char* key,
              const String& body, String& result) {
  for (int attempt = 0; attempt < 2; ++attempt) {
    cloudTls.setCACert(SUPABASE_CA_ROOTS); // verify TLS certificate; never use setInsecure()
    cloudTls.setTimeout(CLOUD_TIMEOUT_MS / 1000);
    HTTPClient http;
    http.setTimeout(CLOUD_TIMEOUT_MS);
    http.setReuse(true);
    if (!http.begin(cloudTls, url)) {
      cloudTls.stop();
      continue;
    }
    http.addHeader("Content-Type", "application/json");
    http.addHeader("x-device-id", DEVICE_ID);
    http.addHeader(keyHeader, key);
    const int status = http.POST(body);
    result = status > 0 ? http.getString() : String();
    http.end();
    if (status > 0) return status;
    cloudTls.stop();  // stale keep-alive socket: reconnect once
  }
  return -1;
}

bool performCloudUpload(const String& body, unsigned long startedAt, unsigned long sampleAt) {
  const uint32_t freeHeap = ESP.getFreeHeap();
  if (freeHeap < CLOUD_MIN_FREE_HEAP) {
    Serial.printf("[CLOUD] Low memory (%u bytes), skipping HTTPS upload\n", (unsigned)freeHeap);
    return false;
  }
  String result;
  const int status = cloudPost(SUPABASE_INGEST_URL, "x-device-key", DEVICE_INGEST_KEY, body, result);
  if (status == 200 || status == 201) {
    // Server must report stored:true, otherwise a successful HTTP response
    // could represent validation-only behavior from an older function.
    if (result.indexOf("\"stored\":true") >= 0 || result.indexOf("\"stored\": true") >= 0) {
#if ENABLE_SECOND_BATCH
      // A successful HTTP status is not proof that BOTH rooms were persisted.
      const bool hasCount = result.indexOf("\"count\":2") >= 0 ||
                            result.indexOf("\"count\": 2") >= 0;
      // The two-room Edge Function returns rooms_saved, not always count.
      // Require BOTH exact room keys in its acknowledgement.
      const int savedAt = result.indexOf("\"rooms_saved\"");
      const int savedEnd = savedAt >= 0 ? result.indexOf(']', savedAt) : -1;
      const String savedRooms = (savedAt >= 0 && savedEnd > savedAt)
          ? result.substring(savedAt, savedEnd + 1) : String();
      // Room keys of THIS board (entrance/sala on ESP32-001, kitchen/bedroom on ESP32-002).
      const bool hasEntrance = savedRooms.indexOf(String("\"") + ROOM_KEY + "\"") >= 0;
      const bool hasSala = savedRooms.indexOf(String("\"") + SECOND_ROOM_KEY + "\"") >= 0;
      const bool twoRoomsSaved = hasCount || (hasEntrance && hasSala);
      if (!twoRoomsSaved) {
        ++cloudUploadFailures;
        Serial.printf("[CLOUD] WARNING: server did not confirm BOTH %s and %s: %.220s\n",
                      ROOM_KEY, SECOND_ROOM_KEY, result.c_str());
        return false;
      }
#endif
      ++cloudUploadSuccesses;
      lastCloudSuccessMs = millis();
      if (VERBOSE_RAW_LOGS || cloudUploadSuccesses == 1)
        Serial.printf("[CLOUD] STORED %s + %s reading #%lu, HTTP %d; sample_age=%lu ms; upload_duration=%lu ms\n",
                      ROOM_KEY, SECOND_ROOM_KEY, cloudUploadSuccesses, status, millis()-sampleAt, millis()-startedAt);
      return true;
    }
    ++cloudUploadFailures;
    Serial.printf("[CLOUD] HTTP %d but NOT stored: %.180s\n", status, result.c_str());
    return false;
  }
  ++cloudUploadFailures;
  Serial.printf("[CLOUD] Upload FAILED HTTP %d: %.180s\n", status, result.c_str());
  return false;
}

const char* jobName(int job) {
  switch (job) {
    case JOB_EVENT: return "motion event";
    case JOB_HEARTBEAT: return "heartbeat";
    case JOB_PTZ: return "ptz_state";
    case JOB_CAMERA: return "camera telemetry";
    default: return "record";
  }
}

bool performSystemRecord(const String& body, int job) {
  if (ESP.getFreeHeap() < CLOUD_MIN_FREE_HEAP) return false;
  String result;
  const int status = cloudPost(DEVICE_COMMAND_URL, "x-device-key", DEVICE_COMMAND_KEY, body, result);
  if (status == 200 && result.indexOf("\"ok\":true") >= 0) {
    ++systemRecordOk;
    lastCloudSuccessMs = millis();
    if (job == JOB_EVENT) {
      if (body.indexOf("\"action\":\"ack\"") >= 0) {
        Serial.println("[DB] Command acknowledged in Supabase device_commands");
      } else {
        const int at = body.indexOf("\"event_type\":\"");
        const String type = at >= 0 ? body.substring(at + 14, body.indexOf('"', at + 14)) : String("event");
        Serial.printf("[DB] STORED %s event in Supabase event_history (MySQL sync mirrors it)\n", type.c_str());
      }
    }
    static unsigned long lastOkLog = 0;
    if (millis() - lastOkLog >= 60000UL) {
      lastOkLog = millis();
      Serial.printf("[DB] System records stored: %lu ok, %lu failed (heartbeat, camera, PTZ, events)\n",
                    systemRecordOk, systemRecordFailed);
    }
    return true;
  }
  ++systemRecordFailed;
  static unsigned long lastErrLog = 0;
  if (millis() - lastErrLog >= 15000UL || job == JOB_EVENT) {
    lastErrLog = millis();
    if (status == 401) {
      Serial.println("[DB] device-command rejected the key (401): DEVICE_COMMAND_KEY must equal the Supabase secret PYROGUARD_DEVICE_KEY");
    } else if (status == 404) {
      Serial.printf("[DB] device-command 404: register device_id %s (with its owner) in the Supabase devices table\n", DEVICE_ID);
    } else {
      Serial.printf("[DB] %s NOT stored, HTTP %d: %.200s\n", jobName(job), status, result.c_str());
    }
  }
  return false;
}

// Asks Supabase for the owner's ARM/DISARM state and pending app commands.
// The reply is handed to loop() (applySecuritySync) - never applied here.
volatile int lastSyncHttp = 0;              // shown in the Serial status table
volatile unsigned long lastSyncOkMs = 0;
void performSecuritySync(const String& body) {
  if (ESP.getFreeHeap() < CLOUD_MIN_FREE_HEAP) return;
  String result;
  const int status = cloudPost(DEVICE_COMMAND_URL, "x-device-key", DEVICE_COMMAND_KEY, body, result);
  lastSyncHttp = status;
  if (status == 200 && result.indexOf("\"ok\":true") >= 0) {
    lastSyncOkMs = millis();
    lastCloudSuccessMs = millis();
    if (xSemaphoreTake(cloudMutex, pdMS_TO_TICKS(200)) == pdTRUE) {
      syncResponse = result;
      syncResponseReady = true;
      xSemaphoreGive(cloudMutex);
    }
    return;
  }
  static unsigned long lastErr = 0;
  if (millis() - lastErr >= 10000UL) {
    lastErr = millis();
    Serial.printf("[SECURITY] Arm/disarm sync failed HTTP %d: %.160s\n", status, result.c_str());
    if (status == 200) Serial.println("[SECURITY] Reply has no \"ok\":true - check device-command 'sync' and the system_state row for this device");
  }
}

// Picks the next job: events first, then sensor readings, then status rows.
int takeCloudJob(String& body, unsigned long& queuedAt, unsigned long& sampleAt) {
  if (eventQueueCount > 0) {
    body = eventQueue[0];
    for (int i = 1; i < eventQueueCount; ++i) eventQueue[i - 1] = eventQueue[i];
    eventQueue[--eventQueueCount] = String();
    return JOB_EVENT;
  }
  // Round-robin: each pending job gets a turn. With a fixed priority, the arm
  // sync (queued every few seconds, ~2 s per HTTPS call) was ALWAYS waiting
  // again, so the heartbeat and sensor readings never ran ("cloud uploads
  // 0 ok / 0 failed", board shown OFFLINE while door events still arrived).
  CloudSlot* slots[] = { &syncSlot, &heartbeatSlot, &sensorSlot, &ptzSlot, &cameraSlot };
  const int jobs[] = { JOB_SYNC, JOB_HEARTBEAT, JOB_SENSOR, JOB_PTZ, JOB_CAMERA };
  static int nextSlot = 0;
  for (int k = 0; k < 5; ++k) {
    const int i = (nextSlot + k) % 5;
    if (!slots[i]->pending) continue;
    nextSlot = (i + 1) % 5;   // next call starts after the job just taken
    body = slots[i]->body;
    queuedAt = slots[i]->queuedAt;
    sampleAt = slots[i]->sampleAt;
    slots[i]->body = String();
    slots[i]->pending = false;
    return jobs[i];
  }
  return JOB_NONE;
}

void cloudWorker(void*) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(1000));
    for (;;) {
      String body;
      unsigned long queuedAt = 0, sampleAt = 0;
      int job = JOB_NONE;
      if (xSemaphoreTake(cloudMutex, pdMS_TO_TICKS(500)) == pdTRUE) {
        job = takeCloudJob(body, queuedAt, sampleAt);
        xSemaphoreGive(cloudMutex);
      }
      if (job == JOB_NONE) break;
      if (WiFi.status() == WL_CONNECTED && body.length()) {
        if (job == JOB_SENSOR) performCloudUpload(body, queuedAt, sampleAt);
        else if (job == JOB_SYNC) performSecuritySync(body);
        else performSystemRecord(body, job);
      }
      if (job == JOB_SENSOR) cloudInFlight = false;
      vTaskDelay(pdMS_TO_TICKS(20));
    }
  }
}

bool queueCloudSlot(CloudSlot& slot, const String& body, unsigned long sampleAt) {
  if (!cloudTaskHandle || !cloudMutex) return false;
  if (xSemaphoreTake(cloudMutex, pdMS_TO_TICKS(20)) != pdTRUE) return false;
  slot.body = body;
  slot.pending = true;
  slot.queuedAt = millis();
  slot.sampleAt = sampleAt;
  xSemaphoreGive(cloudMutex);
  xTaskNotifyGive(cloudTaskHandle);
  return true;
}

bool queueCloudEvent(const String& body) {
  if (!cloudTaskHandle || !cloudMutex) return false;
  if (xSemaphoreTake(cloudMutex, pdMS_TO_TICKS(20)) != pdTRUE) return false;
  if (eventQueueCount == EVENT_QUEUE_SIZE) {      // keep the newest events
    for (int i = 1; i < EVENT_QUEUE_SIZE; ++i) eventQueue[i - 1] = eventQueue[i];
    --eventQueueCount;
  }
  eventQueue[eventQueueCount++] = body;
  xSemaphoreGive(cloudMutex);
  xTaskNotifyGive(cloudTaskHandle);
  return true;
}

void startCloudWorker() {
  if (!ENABLE_SUPABASE_UPLOAD) return;
  cloudMutex = xSemaphoreCreateMutex();
  if (!cloudMutex) {
    Serial.println("[CLOUD] Mutex failed; uploads will run inline");
    return;
  }
  // TLS needs a larger stack than a plain HTTP request.
  if (xTaskCreatePinnedToCore(cloudWorker, "CloudUpload", 16384, nullptr, 1,
                              &cloudTaskHandle, 0) != pdPASS) {
    cloudTaskHandle = nullptr;
    Serial.println("[CLOUD] Upload task failed; uploads will run inline");
  }
}

bool cloudClockReady() {
  // Certificate validation needs real UTC time after cold boot.
  if (time(nullptr) >= 1700000000) return true;
  if (!cloudTimeReady) {
    configTime(0, 0, "pool.ntp.org", "time.google.com");
    cloudTimeReady = true;
    Serial.println("[CLOUD] Waiting for NTP time before verified HTTPS");
  }
  return false;
}

void uploadCloud() {
  if (!ENABLE_SUPABASE_UPLOAD || !cloudKeyValid || !wifiConfigValid || WiFi.status() != WL_CONNECTED) return;
  const unsigned long now = millis();
  static uint32_t lastSentSig = 0xFFFFFFFF;
  const uint32_t sig = stateSignature();
  const bool urgent = sig != lastSentSig;                      // something the app shows changed
  if (now - lastCloudAttempt < (urgent ? CLOUD_URGENT_GAP_MS : CLOUD_INTERVAL_MS)) return;
  if (cloudInFlight) return;  // previous upload still running; the change is sent right after it
  lastCloudAttempt = now;
  lastSentSig = sig;
  const bool room1Fresh = lastSensorSample && now - lastSensorSample <= MAX_SENSOR_AGE_MS;
#if ENABLE_SECOND_BATCH
  const bool room2Fresh = lastSensorSample2 && now - lastSensorSample2 <= MAX_SENSOR_AGE_MS;
#else
  const bool room2Fresh = false;
#endif
  if (!room1Fresh && !room2Fresh) {
    Serial.println("[CLOUD] SKIPPED: sensor sample is missing or stale");
    return;
  }
  // Unavailable readings are sent as null / WARMUP / FAULT (never invented), so
  // the app shows the board as connected right after boot.
  if ((!dhtValid && !dht2Valid) || !mq2WarmedUp) {
    static unsigned long lastNotReadyLog = 0;
    if (now - lastNotReadyLog >= 15000UL) {
      lastNotReadyLog = now;
      Serial.printf("[CLOUD] Sending partial data: dht1=%s dht2=%s mq2=%s\n",
                    dhtValid ? "OK" : "INVALID", dht2Valid ? "OK" : "INVALID", mq2WarmedUp ? "READY" : "WARMUP");
    }
  }
  if (!cloudClockReady()) return;
  // Snapshot the real readings now (in loop context), upload in background.
  const String body = cloudJson();
  if (queueCloudSlot(sensorSlot, body, lastSensorSample)) {
    cloudInFlight = true;
    return;
  }
  performCloudUpload(body, now, lastSensorSample);  // fallback: inline
}

// ---------------- system records (built in loop, sent by the worker) ----------------

String boolText(bool value) { return value ? "true" : "false"; }

String heartbeatJson() {
  const bool sensorFresh = lastSensorSample && millis() - lastSensorSample <= MAX_SENSOR_AGE_MS;
  // *_ok = the part is configured on this controller and reporting now.
  // Parts that are not on ESP32-001 (PIR, ultrasonic, GPS, GSM) stay false.
  String j = "{\"action\":\"telemetry\",\"device_id\":\"" + String(DEVICE_ID) +
             "\",\"table\":\"device_heartbeats\",\"record\":{";
  j += "\"wifi_ok\":" + boolText(WiFi.status() == WL_CONNECTED);
  j += ",\"supabase_ok\":" + boolText(lastCloudSuccessMs && millis() - lastCloudSuccessMs < 60000UL);
  j += ",\"camera_ok\":" + boolText(camera1LinkFresh());
  j += ",\"mic_ok\":" + boolText(camera1LinkFresh());      // on Camera 1
  j += ",\"speaker_ok\":" + boolText(camera1LinkFresh());  // on Camera 1
  j += ",\"ptz_ok\":" + boolText(ENABLE_PTZ_SERVOS && panServoOk && tiltServoOk);
  j += ",\"door_ok\":true";
  j += ",\"window_ok\":" + boolText(USE_WINDOW);
  j += ",\"mq2_ok\":" + boolText(mq2WarmedUp && sensorFresh && !smokeGuard[0].fault && !smokeGuard[1].fault);
  j += ",\"flame_ok\":" + boolText(sensorFresh && !flameGuard[0].fault && !flameGuard[1].fault);
  j += ",\"dht22_ok\":" + boolText(dhtValid && sensorFresh);
  j += ",\"siren_ok\":true";
  j += ",\"uptime_secs\":" + String(millis() / 1000UL);
  j += ",\"local_ip\":\"" + WiFi.localIP().toString() + "\"}}";
  return j;
}

String cameraTelemetryJson() {
  const bool online = camera1LinkFresh();
  String j = "{\"action\":\"telemetry\",\"device_id\":\"" + String(DEVICE_ID) +
             "\",\"table\":\"pyroguard_camera_telemetry\",\"record\":{";
  j += "\"camera_device_id\":\"" CAMERA1_DEVICE_ID "\"";
  j += ",\"camera_ip\":\"" + cameraHost() + "\"";
  j += ",\"status\":\"" + String(online ? "online" : "offline") + "\"";
  j += ",\"motion_detected\":" + boolText(online && camera1MotionDetected);
  j += ",\"motion_pixels\":" + String(online ? (unsigned long)camera1ChangedSamples : 0UL);
  j += ",\"pan_angle\":" + String(currentAngle);
  j += ",\"tilt_angle\":" + String(currentTilt);
  if (online && camera1Rssi < 0) j += ",\"wifi_rssi\":" + String((int)camera1Rssi);
  if (online && camera1UptimeMs) j += ",\"uptime_ms\":" + String((unsigned long)camera1UptimeMs);
  j += "}}";
  return j;
}

String ptzStateJson() {
  return "{\"action\":\"ptz_state\",\"device_id\":\"" + String(DEVICE_ID) +
         "\",\"pan_position\":" + String(currentAngle) +
         ",\"tilt_position\":" + String(currentTilt) +
         ",\"moving\":" + boolText(servosMoving()) +
         ",\"auto_tracking\":" + boolText(autoFollowEnabled) + "}";
}

String jsonEscape(const String& text) {
  String out;
  for (size_t i = 0; i < text.length(); ++i) {
    const char c = text[i];
    if (c == '"' || c == '\\') { out += '\\'; out += c; }
    else if ((uint8_t)c >= 0x20) out += c;
  }
  return out;
}

void queueMotionEvent() {
  static uint32_t eventSequence = 0;
  const time_t epoch = time(nullptr);
  const String key = String(DEVICE_ID) + ":cam1-motion:" + String((unsigned long)epoch) +
                     "-" + String(++eventSequence);
  String message = "Camera 1 (" + String(PRIMARY_COVERAGE_NAME) + " & " +
                   String(SECOND_COVERAGE_NAME) + ") detected motion";
  if (autoFollowEnabled && !autoFollowPaused()) message += "; auto-follow is turning the camera toward it";
  if (armed) message += " while the system is ARMED";
  String j = "{\"action\":\"record_event\",\"device_id\":\"" + String(DEVICE_ID) + "\",\"record\":{";
  j += "\"event_type\":\"MOTION\"";
  j += ",\"record_key\":\"" + jsonEscape(key) + "\"";
  j += ",\"message\":\"" + jsonEscape(message) + "\"";
  j += ",\"severity\":" + String(armed ? 2 : 1);
  j += ",\"payload_json\":{\"camera_device_id\":\"" CAMERA1_DEVICE_ID "\"";
  j += ",\"coverage\":\"" + String(PRIMARY_COVERAGE_NAME) + " & " + String(SECOND_COVERAGE_NAME) + "\"";
  j += ",\"motion_x\":" + String(camera1MotionX, 3) + ",\"motion_y\":" + String(camera1MotionY, 3);
  j += ",\"motion_samples\":" + String((unsigned long)camera1ChangedSamples);
  j += ",\"pan\":" + String(currentAngle) + ",\"tilt\":" + String(currentTilt);
  j += ",\"auto_follow\":" + boolText(autoFollowEnabled);
  j += ",\"auto_paused\":" + boolText(autoFollowPaused());
  j += ",\"armed\":" + boolText(armed);
  j += ",\"source\":\"camera1_frame_analysis\"}}}";
  if (queueCloudEvent(j)) {
    Serial.println("[DB] Motion event queued for Supabase event_history");
  }
}

// ---------------- arm/disarm + door/window records ----------------

String extractJsonString(const String& json, const char* key) {
  const String label = String("\"") + key + "\":\"";
  const int at = json.indexOf(label);
  if (at < 0) return String();
  const int start = at + label.length();
  const int end = json.indexOf('"', start);
  return end > start ? json.substring(start, end) : String();
}

void queueSecurityEvent(const char* type, const String& message, int severity, const char* subject) {
  static uint32_t sequence = 0;
  const String key = String(DEVICE_ID) + ":" + subject + ":" +
                     String((unsigned long)time(nullptr)) + "-" + String(++sequence);
  String j = "{\"action\":\"record_event\",\"device_id\":\"" + String(DEVICE_ID) + "\",\"record\":{";
  j += "\"event_type\":\"" + String(type) + "\"";
  j += ",\"record_key\":\"" + jsonEscape(key) + "\"";
  j += ",\"message\":\"" + jsonEscape(message) + "\"";
  j += ",\"severity\":" + String(constrain(severity, 0, 2));
  j += ",\"payload_json\":{\"door_open\":" + boolText(door.open);
  j += ",\"window_open\":" + boolText(window.enabled && window.open);
  j += ",\"armed\":" + boolText(armed);
  j += ",\"arm_mode\":\"" + jsonEscape(armMode) + "\"";
  j += ",\"door_protection\":" + boolText(doorProtection);
  j += ",\"window_protection\":" + boolText(windowProtection);
  j += ",\"intrusion\":" + boolText(intrusion);
  j += ",\"contact\":\"" + String(subject) + "\"";
  j += ",\"contact_label\":\"" + String(strcmp(subject, "window") == 0 ? WINDOW_LABEL :
                                      strcmp(subject, "door") == 0 ? DOOR_LABEL : "System") + "\"";
  j += ",\"batch\":\"" + String(BATCH_NAME) + "\"";
  j += ",\"coverage\":\"" + String(PRIMARY_COVERAGE_NAME) + " & " + String(SECOND_COVERAGE_NAME) + "\"";
  j += ",\"source\":\"" + String(DEVICE_ID) + "_reed_switch\"}}}";
  queueCloudEvent(j);
}

// Door/window OPEN and CLOSE are stored for the owner (event_history),
// together with whether the system was ARMED or DISARMED at that moment.
void updateContactEvents() {
  if (!ENABLE_DOOR_WINDOW_EVENTS || !ENABLE_SYSTEM_RECORDS || !cloudTaskHandle ||
      time(nullptr) < 1700000000) return;
  static bool initialised = false;
  static bool lastDoor = false, lastWindow = false;
  static unsigned long lastDoorEvent = 0, lastWindowEvent = 0;
  if (!initialised) {            // boot state is not an "event"
    initialised = true;
    lastDoor = door.open;
    lastWindow = window.enabled && window.open;
    return;
  }
  const unsigned long now = millis();
  const String state = armed ? String("system ARMED (") + armMode + ")" : String("system DISARMED");
  if (door.open != lastDoor && now - lastDoorEvent >= CONTACT_EVENT_MIN_GAP_MS) {
    lastDoor = door.open;
    lastDoorEvent = now;
    const bool alarm = door.open && armed && doorProtection;
    queueSecurityEvent(door.open ? "DOOR_OPEN" : "DOOR_CLOSED",
                       String(DOOR_LABEL) + (door.open ? " OPENED" : " CLOSED") + " - " + state +
                       (alarm ? " - INTRUSION ALARM" : ""),
                       alarm ? 2 : (door.open ? 1 : 0), "door");
  }
  const bool windowOpen = window.enabled && window.open;
  if (window.enabled && windowOpen != lastWindow && now - lastWindowEvent >= CONTACT_EVENT_MIN_GAP_MS) {
    lastWindow = windowOpen;
    lastWindowEvent = now;
    const bool alarm = windowOpen && armed && windowProtection;
    queueSecurityEvent(windowOpen ? "WINDOW_OPEN" : "WINDOW_CLOSED",
                       String(WINDOW_LABEL) + (windowOpen ? " OPENED" : " CLOSED") + " - " + state +
                       (alarm ? " - INTRUSION ALARM" : ""),
                       alarm ? 2 : (windowOpen ? 1 : 0), "window");
  }
}

void queueCommandAck(long id, bool applied, const String& message) {
  String j = "{\"action\":\"ack\",\"device_id\":\"" + String(DEVICE_ID) +
             "\",\"command_id\":" + String(id) +
             ",\"status\":\"" + String(applied ? "applied" : "failed") +
             "\",\"message\":\"" + jsonEscape(message) + "\"}";
  queueCloudEvent(j);
}

void silenceAlarm() {
  if (activeAlarm == A_NONE) return;
  muted = true;
  stopPattern();
  stopPattern2();
  Serial.printf("[SECURITY] %s alarm silenced from the app\n", ALARM_NAMES[activeAlarm]);
}

// Runs in loop(): applies the owner's ARM/DISARM state and pending commands.
void applySecuritySync() {
  if (!syncResponseReady || !cloudMutex) return;
  String data;
  if (xSemaphoreTake(cloudMutex, pdMS_TO_TICKS(20)) != pdTRUE) return;
  data = syncResponse;
  syncResponse = String();
  syncResponseReady = false;
  xSemaphoreGive(cloudMutex);

  // ---- system_state ----
  const String mode = extractJsonString(data, "arm_mode");
  if (mode.length()) {
    String upper = mode;
    upper.toUpperCase();
    const bool wantArmed = upper == "ARM_HOME" || upper == "ARM_AWAY" || upper == "ARMED";
    bool flag;
    if (readJsonBool(data, "door_enabled", flag)) doorProtection = flag;
    if (readJsonBool(data, "window_enabled", flag)) windowProtection = flag;
    if (readJsonBool(data, "motion_enabled", flag)) motionProtection = flag;
    const bool changed = wantArmed != armed || upper != armMode;
    armMode = upper;
    if (!securitySynced) {
      securitySynced = true;
      armed = wantArmed;
      Serial.printf("[SECURITY] Synced from app: %s (door %s, window %s)\n", armMode.c_str(),
                    doorProtection ? "protected" : "ignored", windowProtection ? "protected" : "ignored");
    } else if (changed) {
      armed = wantArmed;
      if (!armed) {
        intrusion = false;
        updateAlarm();
        chime(PAT(P_DISARM));
      } else {
        chime(PAT(P_ARM));
      }
      String message = armed ? String("System ARMED (") + armMode + ") from the app - confirmed by " + String(DEVICE_ID)
                             : String("System DISARMED from the app - confirmed by ") + DEVICE_ID;
      if (armed && door.open) message += String("; note: ") + DOOR_LABEL + " is OPEN";
      if (armed && window.enabled && window.open) message += String("; note: ") + WINDOW_LABEL + " is OPEN";
      Serial.printf("[SECURITY] %s\n", message.c_str());
      queueSecurityEvent(armed ? "ARMED" : "DISARMED", message, 0, "arm");
    }
  }

  // ---- pending device_commands ----
  static long handled[16] = {0};
  static int handledNext = 0;
  int pos = data.indexOf("\"commands\":[");
  while (pos >= 0) {
    const int idAt = data.indexOf("\"id\":", pos);
    if (idAt < 0) break;
    const long id = strtol(data.c_str() + idAt + 5, nullptr, 10);
    const int cmdAt = data.indexOf("\"command\":\"", idAt);
    if (cmdAt < 0) break;
    const int cmdStart = cmdAt + 11;
    const String command = data.substring(cmdStart, data.indexOf('"', cmdStart));
    pos = cmdStart;
    if (id <= 0) continue;
    bool seen = false;
    for (long h : handled) if (h == id) seen = true;
    if (seen) continue;               // ack already queued
    handled[handledNext] = id;
    handledNext = (handledNext + 1) % 16;

    if (command == "SILENCE_SIREN") {
      silenceAlarm();
      queueCommandAck(id, true, String("Buzzer silenced by ") + DEVICE_ID);
    } else if (command == "PTZ") {
      // Camera 1 pan/tilt from the app over the internet (e.g. Vercel).
      const int payloadAt = data.indexOf("\"payload\":{", cmdAt);
      const int nextCommandAt = data.indexOf("\"id\":", cmdStart);
      const int payloadEnd = payloadAt >= 0 ? data.indexOf('}', payloadAt) : -1;
      if (payloadAt < 0 || payloadEnd < 0 ||
          (nextCommandAt >= 0 && payloadAt > nextCommandAt)) {
        queueCommandAck(id, false, "PTZ payload missing");
        continue;
      }
      const String payload = data.substring(payloadAt, payloadEnd + 1);
      const String action = extractJsonString(payload, "action");
      int step = PTZ_JOG_DEG;
      const int stepAt = payload.indexOf("\"step\":");
      if (stepAt >= 0) step = payload.substring(stepAt + 7).toInt();
      if (step < 1) step = PTZ_JOG_DEG;
      if (applyPtzAction(action, step, "app via cloud")) {
        Serial.printf("[PTZ] Cloud command %ld: %s %d\n", id, action.c_str(), step);
        queueCommandAck(id, true, String("PTZ ") + action + " applied by " + DEVICE_ID);
      } else {
        queueCommandAck(id, false, String("PTZ action not supported on ") + DEVICE_ID + ": " + action);
      }
    } else if (command == "TEST_CHIRP") {
      chime(PAT(P_CLOSED));
      queueCommandAck(id, true, String("Test chirp played by ") + DEVICE_ID);
    } else if (command == "SET_SECURITY_MODE" || command == "ARM_DOOR" || command == "DISARM_DOOR" ||
               command == "ARM_WINDOW" || command == "DISARM_WINDOW" ||
               command == "ENABLE_MOTION" || command == "DISABLE_MOTION") {
      // IMPORTANT: Previously this ACKed "applied" without using the pending
      // command payload. Now apply the values before sending a success ACK.
      const int payloadAt = data.indexOf("\"payload\":{", cmdAt);
      const int nextCommandAt = data.indexOf("\"id\":", cmdStart);
      const int payloadEnd = payloadAt >= 0 ? data.indexOf('}', payloadAt) : -1;
      if (payloadAt < 0 || payloadEnd < 0 ||
          (nextCommandAt >= 0 && payloadAt > nextCommandAt)) {
        queueCommandAck(id, false, "Command payload missing");
        continue;
      }
      const String payload = data.substring(payloadAt, payloadEnd + 1);
      String requestedMode = extractJsonString(payload, "arm_mode");
      requestedMode.toUpperCase();
      if (requestedMode != "DISARMED" && requestedMode != "ARM_HOME" &&
          requestedMode != "ARM_AWAY") {
        queueCommandAck(id, false, "Invalid requested arm mode");
        continue;
      }
      const bool wasArmed = armed;
      const String priorMode = armMode;
      bool nextBool;
      if (readJsonBool(payload, "door_enabled", nextBool)) doorProtection = nextBool;
      if (readJsonBool(payload, "window_enabled", nextBool)) windowProtection = nextBool;
      if (readJsonBool(payload, "motion_enabled", nextBool)) motionProtection = nextBool;
      armMode = requestedMode;
      armed = armMode != "DISARMED";
      securitySynced = true;
      if (!armed) intrusion = false;
      updateAlarm();
      if (wasArmed != armed || priorMode != armMode) {
        if (armed) chime(PAT(P_ARM));
        else chime(PAT(P_DISARM));
        queueSecurityEvent(armed ? "ARMED" : "DISARMED",
                           String(DEVICE_ID) + " applied app command: " + armMode,
                           0, "arm");
      }
      Serial.printf("[SECURITY] Applied command %ld: %s\n", id, armMode.c_str());
      queueCommandAck(id, true, String("Applied by ") + DEVICE_ID + ": " + armMode);
    } else {
      queueCommandAck(id, false, String("Unsupported on ") + DEVICE_ID + ": " + command);
    }
  }
}

// Called from loop(): decides when each record is due and queues it.
void scheduleSystemRecords() {
  if (!ENABLE_SYSTEM_RECORDS || !ENABLE_SUPABASE_UPLOAD || !cloudKeyValid ||
      !wifiConfigValid || WiFi.status() != WL_CONNECTED || !cloudTaskHandle) return;
  if (time(nullptr) < 1700000000) return;   // TLS needs NTP time (uploadCloud starts it)
  const unsigned long now = millis();

  static unsigned long lastHeartbeat = 0, lastCamera = 0, lastPtz = 0, lastSync = 0;
  if (ENABLE_SECURITY_SYNC && (!lastSync || now - lastSync >= SECURITY_SYNC_INTERVAL_MS)) {
    if (queueCloudSlot(syncSlot, "{\"action\":\"sync\",\"device_id\":\"" + String(DEVICE_ID) + "\"}", 0)) {
      lastSync = now;
    }
  }
  static bool lastCameraOnline = false, lastCameraMotion = false, wasMoving = false;
  static int lastPanSent = -1, lastTiltSent = -1;
  static unsigned long moveEndedAt = 0;

  if (!lastHeartbeat || now - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
    if (queueCloudSlot(heartbeatSlot, heartbeatJson(), 0)) lastHeartbeat = now;
  }

  if (!ENABLE_CAMERA1_LINK) return;   // Batch 2: no camera / PTZ records
  const bool cameraOnline = camera1LinkFresh();
  const bool cameraMotion = cameraOnline && camera1MotionDetected;
  const bool cameraChanged = cameraOnline != lastCameraOnline || cameraMotion != lastCameraMotion;
  if (!lastCamera || now - lastCamera >= CAMERA_TELEMETRY_INTERVAL_MS ||
      (cameraChanged && now - lastCamera >= 3000UL)) {
    if (queueCloudSlot(cameraSlot, cameraTelemetryJson(), 0)) {
      lastCamera = now;
      lastCameraOnline = cameraOnline;
      lastCameraMotion = cameraMotion;
    }
  }

  const bool moving = servosMoving();
  if (wasMoving && !moving) moveEndedAt = now;
  wasMoving = moving;
  const bool positionChanged = currentAngle != lastPanSent || currentTilt != lastTiltSent;
  if (!lastPtz || now - lastPtz >= PTZ_STATE_INTERVAL_MS ||
      (ptzStateDirty && now - lastPtz >= 1000UL) ||
      (positionChanged && !moving && moveEndedAt && now - moveEndedAt >= 1000UL &&
       now - lastPtz >= 2000UL)) {
    if (queueCloudSlot(ptzSlot, ptzStateJson(), 0)) {
      ptzStateDirty = false;
      lastPtz = now;
      lastPanSent = currentAngle;
      lastTiltSent = currentTilt;
    }
  }
}

// =====================================================
//                    SETUP / LOOP
// =====================================================
void setup() {
  Serial.begin(115200);
  delay(500);
  const esp_reset_reason_t resetReason = esp_reset_reason();
  Serial.printf("[BOOT] reset_reason=%d (%s) free_heap=%u\n", (int)resetReason,
                resetReasonText(resetReason), (unsigned)ESP.getFreeHeap());
  if (resetReason == ESP_RST_BROWNOUT) {
    servoPowerSafe = true;
    Serial.println("##########################################################################");
    Serial.println("[POWER] LAST RESET WAS A BROWNOUT: the supply voltage dropped.");
    Serial.println("[POWER] Almost always the servos: power them from a separate 5 V / 2 A");
    Serial.println("[POWER] supply, join its GND to the ESP32 GND. Servos stay OFF until the");
    Serial.println("[POWER] first PTZ command so the sensors and Wi-Fi keep working.");
    Serial.println("##########################################################################");
  } else if (resetReason == ESP_RST_PANIC || resetReason == ESP_RST_TASK_WDT ||
             resetReason == ESP_RST_INT_WDT || resetReason == ESP_RST_WDT) {
    Serial.println("[BOOT] The previous run CRASHED (see reason above). Please send the Serial log.");
  }
  Serial.printf("[BOOT] PyroGuard %s %s - %s + %s\n", BATCH_NAME, DEVICE_ID, PRIMARY_COVERAGE_NAME, SECOND_COVERAGE_NAME);
  Serial.printf("[BOOT] Magnet test: %s GPIO%d, %s GPIO%d (type: contacts)\n", DOOR_LABEL, DOOR_PIN, WINDOW_LABEL, WINDOW_PIN);
  Serial.println("[BOOT] stage=hardware_init");

  for (uint8_t p : BUZZ_PINS_ALL) pinMode(p, OUTPUT);   // all four buzzers
  buzz(false);
  analogReadResolution(12);
  analogSetPinAttenuation(MQ2_AO_PIN, ADC_11db);       // 0 - 3.1 V input range
#if ENABLE_SECOND_BATCH
  buzz2(false);
  analogSetPinAttenuation(MQ2_2_AO_PIN, ADC_11db);     // analog: NO pull-up on this pin
  pinMode(FLAME2_PIN, INPUT_PULLUP);
  flame2Candidate = (digitalRead(FLAME2_PIN) == (FLAME2_ACTIVE_LOW ? LOW : HIGH));
  flame2CandidateSince = millis();
  smoke2CandidateSince = millis();
  dht2.begin();
#endif

  pinMode(FLAME_PIN, INPUT);   // GPIO35 has NO internal pull-up/pull-down; module must drive 3.3V-safe digital DO
  flameCandidate = (digitalRead(FLAME_PIN) == (FLAME_ACTIVE_LOW ? LOW : HIGH));
  flameCandidateSince = millis();
  prefs.begin("pyroguard", false);
  // The door/window setting is saved in flash and normally survives re-uploads.
  // Version 3 = door GPIO25 now LOW=OPEN / HIGH=CLOSED like the window: replace
  // the old saved value ONCE with the new defaults. "door invert" still works after.
  if (prefs.getUChar("pinmap", 0) != 5) {
    prefs.putBool("doorRev", DOOR_CONTACT_REVERSED);
    prefs.putBool("winRev", WINDOW_CONTACT_REVERSED);
    prefs.putUChar("pinmap", 5);
    Serial.println("[CONTACT] Reed settings reset: door GPIO25 and window GPIO26 = LOW OPEN / HIGH CLOSED");
  }
  doorReversed = prefs.getBool("doorRev", DOOR_CONTACT_REVERSED);
  windowReversed = prefs.getBool("winRev", WINDOW_CONTACT_REVERSED);
  autoFollowEnabled = prefs.getBool("autoFol", AUTO_FOLLOW_DEFAULT);
  pinMode(DOOR_PIN, INPUT_PULLUP);
  if (USE_WINDOW) pinMode(WINDOW_PIN, INPUT_PULLUP);
  Serial.printf("[BOOT] %s %s (%s + %s) firmware %s\n", BATCH_NAME, DEVICE_ID,
                PRIMARY_COVERAGE_NAME, SECOND_COVERAGE_NAME, FIRMWARE_VERSION);
  if (DEMO_SENSITIVE_MODE) {
    Serial.printf("[DEMO] Sensitive demo mode ON: lighter flame = FIRE after %lu s, gas trigger %d mV, heat %.0f C, MQ-2 warm-up %lu s\n",
                  (unsigned long)(FIRE_CONFIRM_MS / 1000UL), MQ2_TRIGGER_MV, (double)TEMP_THRESHOLD,
                  (unsigned long)(MQ2_WARMUP_MS / 1000UL));
  }
  Serial.printf("[CONTACT] door reversed=%s, window reversed=%s (Serial: door invert / window invert)\n",
                doorReversed ? "yes" : "no", windowReversed ? "yes" : "no");
  dht.begin();

  door.open = door.lastReading = readContact(door);
  if (window.enabled) window.open = window.lastReading = readContact(window);

  if (ENABLE_PTZ_SERVOS) {
    currentAngle = targetPan = PAN_CENTER;
    currentTilt = targetTilt = TILT_CENTER;
    lastServoMotionMs = millis();
    // Servos attach in loop() after SERVO_ATTACH_DELAY_MS (or on the first
    // move after a brownout) - see updateServoPower().
    Serial.println(servoPowerSafe
      ? "[PTZ] Power-safe start: servos attach on the first PTZ command"
      : "[PTZ] Servos attach 3 s after boot (after Wi-Fi start)");
  } else { Serial.println("[DIAG] PTZ servo output disabled for isolation"); }

  Serial.println("[BOOT] stage=wifi_init");
  if (ENABLE_WIFI) {
    {   // Wi-Fi comes from saved networks / setup hotspot; WIFI_SSID is only the first default
      wifiConfigValid = true;
      WiFi.mode(WIFI_STA);
      WiFi.setSleep(false);          // no modem-sleep latency on PTZ/API requests
      WiFi.setAutoReconnect(true);
      if (ENABLE_LOCAL_API && !String(DEVICE_HTTP_KEY).startsWith("REPLACE_") && strlen(DEVICE_HTTP_KEY) >= 16) {
        const char* headerKeys[] = {"X-Device-Key"};
        webServer.collectHeaders(headerKeys, 1);
        webServer.on("/status", HTTP_GET, routeStatus);
        webServer.on("/health", HTTP_GET, routeHealth);
        webServer.on("/ptz", HTTP_POST, routePtz);
        webServer.on("/ptz", HTTP_OPTIONS, routeOptions);
        webServer.on("/status", HTTP_OPTIONS, routeOptions);
        webServer.on("/health", HTTP_OPTIONS, routeOptions);
        webServer.on("/", HTTP_GET, []() {
          if (fromSetupHotspot()) routeWifiPage();
          else jsonReply(200, "{\"device\":\"" + String(DEVICE_ID) + "\",\"ok\":true}");
        });
        webServer.on("/wifi", HTTP_GET, routeWifiPage);
        webServer.on("/wifisave", HTTP_POST, routeWifiSave);
        webServer.onNotFound([]() {
          if (fromSetupHotspot()) { webServer.sendHeader("Location", "http://192.168.4.1/"); webServer.send(302, "text/plain", ""); }
          else jsonReply(404, "{\"error\":\"not_found\"}");
        });
      }
      loadWifiNetworks();
      {
        const String savedCam = prefs.getString("camHost", "");
        if (validIpText(savedCam)) setCameraHost(savedCam, "saved");
        camHostDirty = false;
      }
      listWifiNetworks();
      connectNextWifi();
    }
  }

  cloudKeyValid = strlen(DEVICE_INGEST_KEY) == 64;
  if (cloudKeyValid) {
    for (size_t i = 0; i < 64; ++i) {
      const char c = DEVICE_INGEST_KEY[i];
      if (!isxdigit((unsigned char)c)) { cloudKeyValid = false; break; }
    }
  }
  if (ENABLE_SUPABASE_UPLOAD && !cloudKeyValid) {
    Serial.println("[CLOUD] Disabled until a valid 64-character DEVICE_INGEST_KEY is configured");
  }
  if (cloudKeyValid) startCloudWorker();
  if (ENABLE_CAMERA1_LINK && ENABLE_WIFI && wifiConfigValid) {
    BaseType_t created = xTaskCreatePinnedToCore(
        cameraLinkWorker, "Camera1Link", 8192, nullptr, 1,
        &cameraLinkTaskHandle, 0);
    Serial.println(created == pdPASS
      ? "[CAMERA1] Direct LAN link started (finds " CAMERA1_MDNS_NAME ".local on any Wi-Fi) - auto-follow + manual PTZ"
      : "[CAMERA1] FAILED to start camera link task");
  } else {
    Serial.println("[CAMERA1] Link disabled; check WiFi configuration");
  }
  Serial.println("[BOOT] stage=init_complete");
  Serial.println("\n=== PyroGuard: Sensors + Pan/Tilt + Door/Window + Buzzer ===");
  Serial.println("MQ-2 warming up for 3 minutes... smoke state UNKNOWN until warmup finishes");
  Serial.println("[NOTE] DIGITAL DO smoke/flame inputs can show a comparator state, not prove actual fire or a sensor is physically connected.");
  Serial.printf("COVERAGE: %s (room_key %s) + %s (room_key %s)\n",
                PRIMARY_COVERAGE_NAME, ROOM_KEY, SECOND_COVERAGE_NAME, SECOND_ROOM_KEY);
  Serial.printf("SECOND SET (%s): %s\n", SECOND_COVERAGE_NAME, ENABLE_SECOND_BATCH ? "ENABLED" : "DISABLED until installed");
  Serial.printf("PTZ: GPIO13 PAN, GPIO27 TILT; auto-follow %s (manual overrides); pan %d..%d, tilt %d..%d\n",
                autoFollowEnabled ? "ON" : "OFF", PAN_MIN, PAN_MAX, TILT_MIN, TILT_MAX);
  Serial.println("WiFi local API: " + String(ENABLE_WIFI ? "enabled" : "disabled (USB test mode)"));
  Serial.printf("Door is currently: %s\n", door.open ? "OPEN" : "closed");
  if (window.enabled) Serial.printf("Window is currently: %s\n", window.open ? "OPEN" : "closed");
  printHelp();
  printPosition();

  printWiringDiagnostics();
  playPattern(PAT(P_STARTUP), false);    // original startup beeps
}

void loop() {
  checkContact(door, PAT(P_DOOR_OPEN));      // door/window checked every loop
  checkContact(window, PAT(P_WIN_OPEN));
  updateFlameInput();                  // Entrance flame input, filtered
  updateFlameInputSecondRoom();        // Sala flame input, filtered
  updateSmokeInput();                  // Entrance fast MQ-2 digital detection, filtered
  updateSmokeInputSecondRoom();        // room 2 fast MQ-2 digital detection, filtered
  updateFireState();                   // fire = smoke + flame sustained FIRE_CONFIRM_MS
  updateFireState2();
  updateBuzzer();                            // keeps buzzer patterns running
  updateBuzzer2();                           // second-set ("Sala") alarm if enabled
  updateServoPower();                         // deferred, staggered servo attach
  updateAutoFollow();                         // system decides auto moves (manual overrides)
  if (ENABLE_PTZ_SERVOS) updateServos();      // nonblocking pan and tilt
  updateWifi();                              // optional authenticated LAN API

  // Camera 1 motion is reported by the link task; the alarm state is only
  // ever changed here in loop() so the buzzer engine is never touched
  // from two tasks at once.
  if (camera1MotionEvent) {
    camera1MotionEvent = false;
    static unsigned long lastMotionEventMs = 0;
    if (ENABLE_SYSTEM_RECORDS && cloudKeyValid && time(nullptr) >= 1700000000 &&
        (!lastMotionEventMs || millis() - lastMotionEventMs >= MOTION_EVENT_MIN_GAP_MS)) {
      lastMotionEventMs = millis();
      queueMotionEvent();
    }
    if (CAMERA1_MOTION_TRIGGERS_INTRUSION && motionProtection && armed && !intrusion) {
      intrusion = true;
      intrusionSince = millis();
      Serial.println(">>> INTRUSION ALERT: Camera 1 motion while ARMED <<<");
      updateAlarm();
    }
  }

  // Intrusion siren limit: stop the sound after INTRUSION_SIREN_MAX_MS; the
  // alarm itself stays ON (app + records) until the owner disarms.
  if (intrusion && activeAlarm == A_INTRUSION && !muted && intrusionSince &&
      millis() - intrusionSince > INTRUSION_SIREN_MAX_MS) {
    muted = true;
    stopPattern();
    stopPattern2();
    Serial.println("[SECURITY] Intrusion siren stopped after 3 min; alarm stays active until DISARM");
  }

  // Ask Camera 1 for an evidence photo when a confirmed fire or an intrusion starts.
  {
    static bool lastHazard = false, lastIntrusion = false;
    const bool hazard = fireNow || fireNow2;
    if (hazard && !lastHazard) cameraSnapshotRequest = 1;
    else if (intrusion && !lastIntrusion && !hazard) cameraSnapshotRequest = 2;
    lastHazard = hazard;
    lastIntrusion = intrusion;
  }

  if (Serial.available()) handleCommand();

  if (millis() - lastRead >= READ_INTERVAL) {
    lastRead = millis();
    readSensors();
    readSensorsSecondRoom();
  }
  printCloudDiagnostics();
  uploadCloud(); // queues HTTPS upload of fresh readings; never blocks loop()
  scheduleSystemRecords(); // heartbeat, camera status, servo position, arm sync -> Supabase
  applySecuritySync();     // owner's ARM/DISARM + app commands (silence, test chirp)
  updateContactEvents();   // door/window OPEN/CLOSE -> event_history
  printDashboard(false);   // Serial table: instantly on any change, else every 3 s
}