/*
  ================================================================
  PyroGuard — ESP32-S3 Firmware — main sketch (core + Phase 1)
  ================================================================
  This is the CORE file: Wi-Fi, the always-on sensors (MQ-2, flame,
  DHT22, LED, buzzer), the offline queue, and the shared HTTP POST
  helper. Each optional hardware phase lives in its own file in this
  same folder — Arduino compiles every .h/.ino in a sketch folder
  together automatically, so just keep them all here:

    gsm_module.h      SIM800L — autonomous SMS + call
    gps_module.h      NEO-6M — real device location
    ptz_module.h      Pan/tilt servos + joystick + named presets
    camera_module.h   Live MJPEG video stream + snapshot-on-event
    audio_module.h    Live one-way audio stream + evidence clip
    pir_module.h      3-sensor coarse left/center/right tracking

  Turn each phase on/off below — OFF by default except Phase 1
  (always on). Only enable a phase once that hardware is actually
  wired up; each module file has its own wiring diagram in its
  header comment.

  ⚠️ Same standing caveat as every version of this firmware: no
  physical ESP32-S3, no Arduino toolchain, no way to compile or run
  this in this conversation. Written as correctly as possible from
  documented APIs, not verified end-to-end. Expect to adjust pins,
  install libraries, and debug from Serial Monitor output.

  ⚠️ PIN PRESSURE IS REAL once you enable several phases together —
  see PYROGUARD_GUIDE.md's pin-conflict table before enabling camera together
  with GPS, PTZ, or PIR.

  LIBRARIES REQUIRED (Arduino Library Manager):
    Always:            "DHT sensor library" (Adafruit) + "Adafruit Unified Sensor"
    ENABLE_GPS:         "TinyGPS++" (Mikal Hart)
    Always also:       "ArduinoJson" (v6.x) for security command polling
    ENABLE_PTZ:         "ESP32Servo"
    ENABLE_CAMERA:      none extra — needs PSRAM enabled + "Huge APP" partition scheme
    ENABLE_AUDIO/GSM/BATTERY: none extra
*/

// ── Turn each phase on only once that hardware is actually wired ──
#define ENABLE_GSM      0   // SIM800L — autonomous SMS + call
#define ENABLE_GPS      0   // NEO-6M — real device location
#define ENABLE_PTZ      0   // Pan/tilt servos + joystick control + presets
#define ENABLE_CAMERA   0   // Snapshot capture + upload (not live streaming)
#define ENABLE_AUDIO    0   // Recorded evidence clips (not real-time two-way)
#define ENABLE_PIR      0   // Motion-triggered snapshot (NOT visual tracking — see below)
#define ENABLE_BATTERY  0   // Battery voltage sensing via a resistor divider
#define ENABLE_MYSQL_HISTORY 1 // Dual-record important snapshots to Supabase + MySQL

#include <WiFi.h>
#include <HTTPClient.h>
#include <DHT.h>

// ── 1. Fill these in for your deployment ──────────────────────────
const char* WIFI_SSID     = "YOUR_WIFI_NAME";
const char* WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";

const char* SUPABASE_URL      = "https://torzyarstitxsreoqcig.supabase.co";
const char* SUPABASE_ANON_KEY =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvcnp5YXJzdGl0eHNyZW9xY2lnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgyNjQzODgsImV4cCI6MjA5Mzg0MDM4OH0"
    ".pCVe-vnX0Ey4_0uV1m6WIeooW6rNOIqMqCEMDgVFC_s";

const char* DEVICE_ID = "ESP32-001"; // must match exactly — see Supabase setup SQL

// Dual-record path. Supabase and MySQL both retain important sensor snapshots.
// The Edge Function securely owns the MySQL credentials; the ESP32 only keeps
// a revocable device key. Replace HISTORY_DEVICE_KEY before deployment.
const char* HISTORY_FUNCTION_URL =
    "https://torzyarstitxsreoqcig.supabase.co/functions/v1/mysql-history";
const char* HISTORY_DEVICE_KEY = "CHANGE_ME";

// ── 2. Pin wiring — verify every one against your actual board ────
#define PIN_MQ2_ANALOG    14
#define PIN_FLAME_DIGITAL 21
#define PIN_DHT22         2
#define PIN_LED_RED       47
#define PIN_LED_GREEN     48
#define PIN_LED_YELLOW    45
#define PIN_BUZZER        38
#define PIN_PIR_LEFT      35  // ⚠️ GPIO35-37 are reserved for PSRAM on
#define PIN_PIR_CENTER    36  //    "octal PSRAM" ESP32-S3 boards (many
#define PIN_PIR_RIGHT     37  //    common N8R8/N16R8 dev boards use
                              //    this). If your board is one of
                              //    those, these three WILL conflict —
                              //    move them to GPIOs your specific
                              //    board actually leaves free.
#define PIN_BATTERY_ADC   1    // ENABLE_BATTERY (voltage divider — see README)

// Phase 2 pins — collide with the camera's 14 GPIOs (4-13, 15-18) if
// camera is ALSO enabled. Move these if you need both at once.
#define GSM_RX_PIN   44
#define GSM_TX_PIN   43
#define GPS_RX_PIN   18
#define GPS_TX_PIN   17
#define PIN_SERVO_PAN  8
#define PIN_SERVO_TILT 9
#define I2S_MIC_SD   40
#define I2S_MIC_WS   41
#define I2S_MIC_SCK  42

#define DHTTYPE DHT22
DHT dht(PIN_DHT22, DHTTYPE);

// Forward declaration — camera_module.h and audio_module.h call this
// (it's defined near the end of this file), and since they're plain
// #includes rather than independent compilation units, relying on
// Arduino's auto-prototype generation across an #include boundary
// isn't guaranteed. This forward declaration makes it unambiguous.
bool postToSupabase(const char* path, const String& jsonBody);
bool postToHistory(const String& jsonBody);
bool postMirrorToMysql(const String& recordType, const String& recordKey, const String& jsonBody);

#if ENABLE_GSM
  #include <HardwareSerial.h>
  HardwareSerial gsmSerial(2);
#endif
#if ENABLE_GPS
  #include <HardwareSerial.h>
  #include <TinyGPS++.h>
  HardwareSerial gpsSerial(1);
  TinyGPSPlus gps;
#endif
#if ENABLE_PTZ
  #include <ESP32Servo.h>
  #include <ArduinoJson.h>
  Servo panServo, tiltServo;
#endif
#if ENABLE_CAMERA
  #include "esp_camera.h"
  #include <esp_http_server.h>
#endif
#if ENABLE_AUDIO
  #include <driver/i2s.h>
  #include <esp_http_server.h>
#endif


// ── 3. Calibrate against YOUR MQ-2 unit ───────────────────────────
const int MQ2_RAW_MIN = 200;
const int MQ2_RAW_MAX = 3200;
const float SMOKE_WARNING_PCT = 30.0;
const float SMOKE_FIRE_PCT    = 70.0;

// ── Optional homeowner GSM fallback ───────────────────────────────
// IMPORTANT: PyroGuard never auto-calls or auto-messages the BFP. The app
// shows the saved BFP contact and the user deliberately taps CALL BFP.
// If you want an offline GSM fallback, put the HOMEOWNER/STAKEHOLDER number
// here during deployment. Leave blank to disable SMS fallback.
const char* GSM_HOMEOWNER_SMS_NUMBER = "";

// ── Timing ─────────────────────────────────────────────────────────
const unsigned long SENSOR_INTERVAL_MS       = 5000;
const unsigned long HISTORY_INTERVAL_MS      = 60000; // dual Supabase + MySQL snapshot cadence
const unsigned long HEARTBEAT_INTERVAL_MS    = 30000;
const unsigned long PTZ_POLL_INTERVAL_MS  = 2000;

unsigned long lastSensorPost  = 0;
unsigned long lastHistoryPost = 0;
unsigned long lastHeartbeat   = 0;
int lastHistorySeverity = -1;
unsigned long lastPtzPoll    = 0;
bool lastSupabaseOk = false;
bool wasFireConfirmed = false;
// These flags mean the firmware has successfully sampled the sensor path in
// the current boot. Fresh device_heartbeats are still required by the app; a
// stale heartbeat is shown OFFLINE even if the last reading was SAFE.
bool lastMq2SampleOk = false;
bool lastFlameSampleOk = false;
bool lastDht22Ok = false;
float lastTemperature = 25.0;
float lastHumidity = 0.0;

#if ENABLE_GSM
  bool gsmReady = false;
#endif
#if ENABLE_PTZ
  float ptzPanDeg = 90, ptzTiltDeg = 90;
  unsigned long lastManualPtzMs = 0; // for auto-behavior override, below
#endif
#if ENABLE_CAMERA
  bool cameraReady = false;
#endif
#if ENABLE_AUDIO
  bool audioReady = false;
  const int AUDIO_SAMPLE_RATE = 16000;
  const int AUDIO_CLIP_SECONDS = 5;
  const int AUDIO_BUFFER_SAMPLES = AUDIO_SAMPLE_RATE * AUDIO_CLIP_SECONDS;
  #define I2S_PORT I2S_NUM_0
#endif
#if ENABLE_PIR
  bool pirLastState = false; // true while ANY of the three sensors sees motion
#endif

// ── Each optional phase's actual code lives in its own file — see
// the header comment at the top of this file for the full list.
// Included here, AFTER every shared flag/pin/global-state variable
// above that a module might reference (gsmReady, ptzPanDeg, etc.) —
// order matters here, since these are plain #includes (textually
// pasted), not independent compilation units.
#if ENABLE_GSM
  #include "gsm_module.h"
#endif
#if ENABLE_GPS
  #include "gps_module.h"
#endif
#if ENABLE_PTZ
  #include "ptz_module.h"
#endif
#if ENABLE_CAMERA
  #include "camera_module.h"
#endif
#if ENABLE_AUDIO
  #include "audio_module.h"
#endif
#include "security_command_module.h"
#if ENABLE_PIR
  #include "pir_module.h"
#endif

// ── Offline event queue ────────────────────────────────────────────
// If a device_current_state UPSERT fails (Wi-Fi/Supabase down), the latest reading is
// held here instead of silently vanishing, and retried automatically
// once connectivity comes back — oldest first. Small and RAM-based
// (survives a temporary outage, not a power loss); a fixed size means
// very long outages will drop the oldest queued reading to make room
// for new ones rather than crash, which is logged when it happens.
#define OFFLINE_QUEUE_SIZE 20
String offlineQueue[OFFLINE_QUEUE_SIZE];
int offlineQueueCount = 0;

void queueOffline(const String& body) {
  if (offlineQueueCount >= OFFLINE_QUEUE_SIZE) {
    // Drop the oldest to make room — logged, not silent.
    for (int i = 1; i < OFFLINE_QUEUE_SIZE; i++) offlineQueue[i - 1] = offlineQueue[i];
    offlineQueueCount--;
    Serial.println("Offline queue full — dropped oldest reading.");
  }
  offlineQueue[offlineQueueCount++] = body;
  Serial.printf("Queued offline (%d in queue).\n", offlineQueueCount);
}

// Generic current/configuration mirror. This is intentionally separate from
// write_sensor/write_camera history so MySQL receives the same live state,
// heartbeat and command/configuration records that Supabase receives.
bool postMirrorToMysql(const String& recordType, const String& recordKey, const String& jsonBody) {
#if ENABLE_MYSQL_HISTORY
  if (WiFi.status() != WL_CONNECTED) return false;
  if (String(HISTORY_DEVICE_KEY) == "CHANGE_ME") return false;

  String payload = "{\"action\":\"write_mirror\",\"device_id\":\"" +
                   String(DEVICE_ID) + "\",\"record\":{" +
                   "\"record_type\":\"" + recordType + "\"," +
                   "\"record_key\":\"" + recordKey + "\"," +
                   "\"device_id\":\"" + String(DEVICE_ID) + "\"," +
                   "\"payload\":" + jsonBody + "}}";

  HTTPClient http;
  http.begin(HISTORY_FUNCTION_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Accept", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("x-device-key", HISTORY_DEVICE_KEY);
  int code = http.POST(payload);
  bool ok = (code >= 200 && code < 300);
  if (!ok) {
    Serial.printf("MySQL mirror %s failed, HTTP %d: %s\n",
                  recordType.c_str(), code, http.getString().c_str());
  }
  http.end();
  return ok;
#else
  (void)recordType;
  (void)recordKey;
  (void)jsonBody;
  return false;
#endif
}

void flushOfflineQueue() {
  while (offlineQueueCount > 0 && WiFi.status() == WL_CONNECTED) {
    bool ok = postToSupabase("/rest/v1/device_current_state?on_conflict=device_id", offlineQueue[0]);
    if (!ok) break; // still can't reach Supabase — stop and retry next loop
#if ENABLE_MYSQL_HISTORY
    postMirrorToMysql("device_current_state", String(DEVICE_ID), offlineQueue[0]);
#endif
    for (int i = 1; i < offlineQueueCount; i++) offlineQueue[i - 1] = offlineQueue[i];
    offlineQueueCount--;
    Serial.printf("Flushed one queued reading (%d remaining).\n", offlineQueueCount);
  }
}

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(PIN_FLAME_DIGITAL, INPUT);
  pinMode(PIN_LED_RED, OUTPUT);
  pinMode(PIN_LED_GREEN, OUTPUT);
  pinMode(PIN_LED_YELLOW, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  setLed(0, 1, 0);
  digitalWrite(PIN_BUZZER, LOW);

#if ENABLE_PIR
  pinMode(PIN_PIR_LEFT, INPUT);
  pinMode(PIN_PIR_CENTER, INPUT);
  pinMode(PIN_PIR_RIGHT, INPUT);
#endif
#if ENABLE_BATTERY
  // ADC pin, no pinMode needed beyond analogRead default
#endif

  dht.begin();
  connectWifi();

#if ENABLE_GSM
  gsmInit();
#endif
#if ENABLE_GPS
  gpsInit();
#endif
#if ENABLE_PTZ
  ptzInit();
#endif
#if ENABLE_CAMERA
  cameraInit();
  startCameraStreamServer();
#endif
#if ENABLE_AUDIO
  audioInit();
  startAudioStreamServer();
#endif
}

void loop() {
  securityPoll();
  if (WiFi.status() != WL_CONNECTED) {
    connectWifi();
  } else {
    flushOfflineQueue();
  }

#if ENABLE_GPS
  gpsUpdate();
#endif
#if ENABLE_PTZ
  ptzPoll();
#endif
#if ENABLE_PIR
  pirCheck();
#endif

  unsigned long now = millis();

  if (now - lastSensorPost >= SENSOR_INTERVAL_MS) {
    lastSensorPost = now;
    readAndPostSensors();
  }

  if (now - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeat = now;
    postHeartbeat();
  }
}

void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  Serial.print("Connecting to Wi-Fi: ");
  Serial.println(WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) {
    delay(300);
    Serial.print(".");
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("\nWi-Fi connected. IP: " + WiFi.localIP().toString());
  } else {
    Serial.println("\nWi-Fi FAILED to connect within 15s — readings will queue offline and retry.");
  }
}

// ── Sensor reading + dual-sensor confirmation ─────────────────────
void readAndPostSensors() {
  int rawMq2 = analogRead(PIN_MQ2_ANALOG);
  lastMq2SampleOk = true; // ADC sample completed; freshness is checked separately.
  float smokePct = (float)(rawMq2 - MQ2_RAW_MIN) / (MQ2_RAW_MAX - MQ2_RAW_MIN) * 100.0;
  if (smokePct < 0) smokePct = 0;
  if (smokePct > 100) smokePct = 100;

  bool flameDetected = (digitalRead(PIN_FLAME_DIGITAL) == LOW);
  lastFlameSampleOk = true; // GPIO sample completed; freshness is checked separately.

  float temperature = dht.readTemperature();
  float humidity = dht.readHumidity();
  lastDht22Ok = !isnan(temperature) && !isnan(humidity);
  if (lastDht22Ok) {
    lastTemperature = temperature;
    lastHumidity = humidity;
  } else {
    Serial.println("DHT22 read failed — keeping the last value; heartbeat will report DHT22 offline.");
    temperature = lastTemperature;
    humidity = lastHumidity;
  }

  int severity;
  const char* incidentType;
  if (smokePct >= SMOKE_FIRE_PCT && flameDetected) {
    severity = 2; incidentType = "Fire Detected";
  } else if (smokePct >= SMOKE_WARNING_PCT) {
    severity = 1; incidentType = "Dust/Smoke";
  } else {
    severity = 0; incidentType = "Normal";
  }

  updateLedAndBuzzer(severity);

  Serial.printf("Smoke: %.1f%% (raw %d)  Flame: %s  Temp: %.1fC  Hum: %.1f%%  Severity: %d\n",
                smokePct, rawMq2, flameDetected ? "YES" : "no", temperature, humidity, severity);

  const char* smokeStatus = severity == 0 ? "SAFE" : (severity == 1 ? "WARNING" : "DANGER");
  const char* alertStatus = severity == 0 ? "SAFE" : (severity == 1 ? "CAUTION" : "CRITICAL");

  String body = "{";
  body += "\"device_id\":\"" + String(DEVICE_ID) + "\",";
  body += "\"temperature\":" + String(temperature, 1) + ",";
  body += "\"humidity\":" + String(humidity, 1) + ",";
  body += "\"smoke_raw\":" + String(rawMq2) + ",";
  body += "\"smoke_level\":" + String(smokePct, 1) + ",";
  body += "\"smoke_status\":\"" + String(smokeStatus) + "\",";
  body += "\"flame_detected\":" + String(flameDetected ? "true" : "false") + ",";
  body += "\"alert_status\":\"" + String(alertStatus) + "\",";
  body += "\"incident_type\":\"" + String(incidentType) + "\",";
  body += "\"severity_level\":" + String(severity);
#if ENABLE_GPS
  if (gpsHasFix()) {
    body += ",\"device_lat\":" + String(gps.location.lat(), 6) + ",\"device_lng\":" + String(gps.location.lng(), 6);
  }
#endif
  body += "}";

  bool ok = postToSupabase("/rest/v1/device_current_state?on_conflict=device_id", body);
  lastSupabaseOk = ok;
  if (!ok) queueOffline(body); // hold it instead of losing the realtime reading
#if ENABLE_MYSQL_HISTORY
  // Current/live state is also retained in MySQL using an UPSERT-style mirror
  // record. The two databases therefore receive the same current state rather
  // than splitting realtime and historical responsibilities.
  postMirrorToMysql("device_current_state", String(DEVICE_ID), body);
#endif
#if ENABLE_MYSQL_HISTORY
  // Important sensor snapshots are retained in BOTH backends.
  // 1) write MySQL through the secure Edge Function
  // 2) write the same snapshot to Supabase sensor_history
  // If MySQL is temporarily unavailable, the Supabase copy is marked
  // mysql_synced=false so the Flutter retry service can mirror it later.
  unsigned long historyNow = millis();
  if ((historyNow - lastHistoryPost >= HISTORY_INTERVAL_MS) ||
      severity != lastHistorySeverity) {
    bool mysqlOk = postToHistory(body);
    String historyBody = body;
    if (historyBody.endsWith("}")) historyBody.remove(historyBody.length() - 1);
    historyBody += ",\"mysql_synced\":" + String(mysqlOk ? "true" : "false") + "}";
    bool supabaseHistoryOk = postToSupabase("/rest/v1/sensor_history", historyBody);
    if (mysqlOk && supabaseHistoryOk) {
      lastHistoryPost = historyNow;
      lastHistorySeverity = severity;
    } else if (supabaseHistoryOk) {
      // Supabase safely retained the record; retrying MySQL can happen later.
      lastHistoryPost = historyNow;
      lastHistorySeverity = severity;
    }
  }
#endif

  bool fireNow = (severity == 2);
  if (fireNow && !wasFireConfirmed) onFireConfirmed();
  wasFireConfirmed = fireNow;
}

void onFireConfirmed() {
  Serial.println(">>> FIRE CONFIRMED — running one-time hardware response <<<");
#if ENABLE_CAMERA
  cameraCaptureAndUpload("fire_evidence");
#endif
#if ENABLE_AUDIO
  audioRecordAndUpload();
#endif
#if ENABLE_GSM
  // Optional offline fallback to the homeowner/stakeholder only.
  // Emergency-services contact remains a deliberate CALL BFP action in Flutter.
  if (strlen(GSM_HOMEOWNER_SMS_NUMBER) > 0) {
    String msg = "PyroGuard: FIRE CONFIRMED at device " + String(DEVICE_ID) +
                 ". Evacuate and open the PyroGuard app for evidence, location, and the saved BFP contact.";
    gsmSendSms(GSM_HOMEOWNER_SMS_NUMBER, msg);
  }
#endif
}

void updateLedAndBuzzer(int severity) {
  if (severity == 2) {
    setLed(1, 0, 0);
    tone(PIN_BUZZER, 2000);
  } else if (severity == 1) {
    setLed(1, 1, 0);
    tone(PIN_BUZZER, 1500, 200);
  } else {
    setLed(0, 1, 0);
    noTone(PIN_BUZZER);
    digitalWrite(PIN_BUZZER, LOW);
  }
}

void setLed(int r, int g, int y) {
  digitalWrite(PIN_LED_RED, r ? HIGH : LOW);
  digitalWrite(PIN_LED_GREEN, g ? HIGH : LOW);
  digitalWrite(PIN_LED_YELLOW, y ? HIGH : LOW);
}

#if ENABLE_BATTERY
// Voltage divider: battery+ -> R1 -> ADC pin -> R2 -> GND. Pick R1/R2
// so the divided voltage never exceeds 3.3V at full charge — e.g. for
// a single-cell LiPo (max ~4.2V), R1=10k/R2=15k divides by ~0.6.
// Adjust DIVIDER_RATIO and the two voltage constants to your actual
// resistors and battery chemistry — the numbers below are a
// placeholder, not a measured calibration.
const float DIVIDER_RATIO = 0.6;
const float BATTERY_EMPTY_V = 3.3;
const float BATTERY_FULL_V  = 4.2;

float readBatteryPct() {
  int raw = analogRead(PIN_BATTERY_ADC);
  float measuredV = (raw / 4095.0) * 3.3;
  float batteryV = measuredV / DIVIDER_RATIO;
  float pct = (batteryV - BATTERY_EMPTY_V) / (BATTERY_FULL_V - BATTERY_EMPTY_V) * 100.0;
  return constrain(pct, 0.0, 100.0);
}
#endif

// ── Heartbeat ──────────────────────────────────────────────────────
void postHeartbeat() {
  bool wifiOk = (WiFi.status() == WL_CONNECTED);

  String body = "{";
  body += "\"device_id\":\"" + String(DEVICE_ID) + "\",";
  body += "\"wifi_ok\":" + String(wifiOk ? "true" : "false") + ",";
  body += "\"supabase_ok\":" + String(lastSupabaseOk ? "true" : "false") + ",";
  body += "\"mq2_ok\":" + String(lastMq2SampleOk ? "true" : "false") + ",";
  body += "\"flame_ok\":" + String(lastFlameSampleOk ? "true" : "false") + ",";
  body += "\"dht22_ok\":" + String(lastDht22Ok ? "true" : "false") + ",";
#if ENABLE_CAMERA
  body += "\"camera_ok\":" + String(cameraReady ? "true" : "false") + ",";
#else
  body += "\"camera_ok\":false,";
#endif
#if ENABLE_PTZ
  body += "\"ptz_ok\":true,";
#else
  body += "\"ptz_ok\":false,";
#endif
#if ENABLE_AUDIO
  body += "\"mic_ok\":" + String(audioReady ? "true" : "false") + ",";
#else
  body += "\"mic_ok\":false,";
#endif
  body += "\"speaker_ok\":false,";
#if ENABLE_PIR
  body += "\"pir_ok\":true,";
#else
  body += "\"pir_ok\":false,";
#endif
#if ENABLE_GPS
  body += "\"gps_ok\":" + String(gpsHasFix() ? "true" : "false") + ",";
#else
  body += "\"gps_ok\":false,";
#endif
#if ENABLE_GSM
  body += "\"gsm_ok\":" + String(gsmReady ? "true" : "false") + ",";
#else
  body += "\"gsm_ok\":false,";
#endif
  body += "\"siren_ok\":true,";
#if ENABLE_BATTERY
  body += "\"battery_pct\":" + String(readBatteryPct(), 0) + ",";
#endif
  body += "\"local_ip\":\"" + (wifiOk ? WiFi.localIP().toString() : String("")) + "\",";
  body += "\"uptime_secs\":" + String((long)(millis() / 1000));
  body += "}";

  postToSupabase("/rest/v1/device_heartbeats?on_conflict=device_id", body);
#if ENABLE_MYSQL_HISTORY
  postMirrorToMysql("device_heartbeats", String(DEVICE_ID), body);
#endif
}

// ── Shared HTTP POST helper ────────────────────────────────────────
bool postToSupabase(const char* path, const String& jsonBody) {
  if (WiFi.status() != WL_CONNECTED) return false;

  HTTPClient http;
  String url = String(SUPABASE_URL) + path;
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  String p = String(path);
  if (p.indexOf("on_conflict=device_id") >= 0) {
    http.addHeader("Prefer", "resolution=merge-duplicates,return=minimal");
  } else {
    http.addHeader("Prefer", "return=minimal");
  }

  int code = http.POST(jsonBody);
  bool ok = (code >= 200 && code < 300);
  if (!ok) {
    Serial.printf("POST %s failed, HTTP %d: %s\n", path, code, http.getString().c_str());
  }
  http.end();
  return ok;
}

// Supabase Edge Function -> MySQL mirrored history. Supabase also keeps the
// same historical snapshot. Never place MySQL credentials on ESP32.
bool postToHistory(const String& jsonBody) {
#if ENABLE_MYSQL_HISTORY
  if (WiFi.status() != WL_CONNECTED) return false;
  if (String(HISTORY_DEVICE_KEY) == "CHANGE_ME") {
    Serial.println("MySQL history disabled: configure HISTORY_DEVICE_KEY.");
    return false;
  }

  String payload = "{\"action\":\"write_sensor\",\"device_id\":\"" +
                   String(DEVICE_ID) + "\",\"record\":" + jsonBody + "}";

  HTTPClient http;
  http.begin(HISTORY_FUNCTION_URL);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Accept", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("x-device-key", HISTORY_DEVICE_KEY);
  int code = http.POST(payload);
  bool ok = (code >= 200 && code < 300);
  if (!ok) {
    Serial.printf("History Edge Function failed, HTTP %d: %s\n", code, http.getString().c_str());
  }
  http.end();
  return ok;
#else
  (void)jsonBody;
  return false;
#endif
}
