/*
 * =============================================================================
 *  PyroGuard — Main Sensor & Alert Controller
 *  "Real-Time Multi-Sensor Detection Using ESP32 for Home Security
 *   and Monitoring System"
 * -----------------------------------------------------------------------------
 *  Board      : ESP32 WROOM-32  (Arduino IDE board: "ESP32 Dev Module")
 *  Core       : Arduino-ESP32 3.x
 *  Libraries  : "DHT sensor library" + "Adafruit Unified Sensor" (Adafruit),
 *               (no servo library needed)
 *  Serial     : 115200 baud, line ending "Newline" or "Both NL & CR"
 *  Version    : 3.1
 * =============================================================================
 *
 *  CHANGES IN 3.1-sync (2026-11-19)
 *  ---------------------------------------------------------------------------
 *  - PYROGUARD_BATCH selects the controller: 2 = ESP32-002 (Kitchen + Bedroom,
 *    default), 1 = ESP32-001 (Entrance + Sala). It was hard-coded "ESP32-001",
 *    so a second board overwrote ESP32-001's rooms in Supabase.
 *  - Zone 1 / Zone 2 are stored as the batch's two rooms by sensor-ingest
 *    (this sketch's flat payload is accepted as-is; fire1/fire2 = fire_confirmed).
 *  - HTTPS now verifies Supabase's certificate (was setInsecure) - needs NTP time,
 *    so uploads start a few seconds after Wi-Fi connects.
 *
 *  CHANGES IN 3.1
 *  ---------------------------------------------------------------------------
 *  - Pan-tilt servos removed (pins 13 and 27 are now free). The ESP32Servo
 *    library is no longer needed. All sensor, buzzer, WiFi and Supabase
 *    features are unchanged.
 *
 *  CHANGES IN 3.0
 *  ---------------------------------------------------------------------------
 *  - Two sensor zones. Each zone has its own MQ-2 (analog), IR flame sensor
 *    and DHT22, with independent calibration, filtering and fault detection.
 *  - Fire is confirmed per zone: smoke AND flame in the SAME zone.
 *  - Four active buzzers (GPIO 18, 19, 21, 22). All four always play the
 *    same sound at the same time for maximum loudness.
 *  - Door reed switch moved to GPIO 25, window reed switch to GPIO 26.
 *  - /smoke JSON and the Supabase upload now include zone-2 readings.
 *  (Earlier versions: MQ-2 AO + fault detection, measurement isolation,
 *   Supabase upload task, separate door/window beeps.)
 *
 *  PIN ASSIGNMENT
 *  ---------------------------------------------------------------------------
 *  GPIO 34   MQ-2 #1 AO ....... AO -> 10k -> GPIO 34 -> 20k -> GND   (Zone 1)
 *  GPIO 32   MQ-2 #2 AO ....... AO -> 10k -> GPIO 32 -> 20k -> GND   (Zone 2)
 *  GPIO 35   Flame #1 DO ...... flame VCC 3.3 V, 10k pull-up to 3.3 V (Zone 1)
 *  GPIO 33   Flame #2 DO ...... flame VCC 3.3 V (internal pull-up)    (Zone 2)
 *  GPIO 4    DHT22 #1 DATA .... 10k pull-up to 3.3 V if bare sensor   (Zone 1)
 *  GPIO 16   DHT22 #2 DATA .... 10k pull-up to 3.3 V if bare sensor   (Zone 2)
 *  GPIO 25   Door reed ........ other wire to GND (internal pull-up)
 *  GPIO 26   Window reed ...... NC to GPIO 26, COM to GND (internal pull-up)
 *  GPIO 18   Buzzer 1 I/O ..... active buzzer module, VCC 5 V
 *  GPIO 19   Buzzer 2 I/O ..... active buzzer module, VCC 5 V
 *  GPIO 21   Buzzer 3 I/O ..... active buzzer module, VCC 5 V
 *  GPIO 22   Buzzer 4 I/O ..... active buzzer module, VCC 5 V
 *
 *  Both MQ-2 VCC = 5 V. All grounds must be tied together.
 *  GPIO 34/35 are input-only and have no internal pull-up.
 *  Analog inputs use ADC1 (GPIO 32-39) because ADC2 stops working with WiFi.
 *
 *  DETECTION LOGIC (per zone)
 *  ---------------------------------------------------------------------------
 *  Smoke  : MQ-2 analog level as % above a clean-air baseline measured after
 *           a 3-minute warm-up. Warning 10 %, alarm 20 % (with hysteresis).
 *  Flame  : IR output sampled every 10 ms over a 500 ms window; confirmed
 *           when >= 30 % of samples detect flame, held 2 s.
 *  Temp   : DHT22 every 2.5 s, range-checked, spike-rejected, median-of-3.
 *           Alarm at 50 C or on a rise of +8 C within 60 s.
 *  Fire   : smoke AND flame in the same zone = FIRE CONFIRMED.
 *
 *  BUZZER BEHAVIOUR (all 4 buzzers together, highest priority first)
 *  ---------------------------------------------------------------------------
 *  Smoke / flame / temperature alarm (any zone) -> continuous tone
 *  Door open                          -> single 150 ms beep every 0.3 s
 *  Window open                        -> double beep, then 0.6 s pause
 *  Door AND window open               -> door and window patterns alternate
 *  Power-on                           -> three short chirps
 *  "mute" silences the current situation; any new condition sounds again.
 *
 *  SERIAL COMMANDS (spaces are ignored)
 *  ---------------------------------------------------------------------------
 *  status          full sensor report        cal       re-measure both MQ-2 baselines
 *  adc             live MQ-2 voltages        cloud     Supabase upload status
 *  m / mute        silence current alert     q / quiet pause periodic report
 *  test alarm      play the hazard tone      test door play the door beep
 *  test window     play the window beep      stop      end a test tone
 *  h / help        list commands
 *
 *  NETWORK
 *  ---------------------------------------------------------------------------
 *  http://<IP>/smoke   JSON for the camera page (zone 1 + zone 2)
 *  http://<IP>/recal   re-measure both MQ-2 baselines
 *  POST {SUPABASE_URL}/functions/v1/{EDGE_FUNCTION_NAME}
 *  Detection and alarms run normally even when WiFi or Supabase is down.
 * =============================================================================
 */

#include <WiFi.h>
#include <WebServer.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <DHT.h>
#include <stdarg.h>
#include <time.h>

// =============================================================================
//  PINS
// =============================================================================
// ---- Zone 1 ----
#define PIN_MQ2_AO    34
#define PIN_FLAME     35
#define PIN_DHT        4
// ---- Zone 2 ----
#define PIN_MQ2_AO_2  32
#define PIN_FLAME_2   33
#define PIN_DHT_2     16
// ---- Security ----
#define PIN_DOOR      25
#define PIN_WINDOW    26
// ---- Buzzers (all four play the same sound) ----
#define PIN_BUZZER_1  18
#define PIN_BUZZER_2  19
#define PIN_BUZZER_3  21
#define PIN_BUZZER_4  22

// ---- Which controller is this? ----
#ifndef PYROGUARD_BATCH
#define PYROGUARD_BATCH 2      // 2 = ESP32-002 (Kitchen + Bedroom), 1 = ESP32-001 (Entrance + Sala)
#endif
#if PYROGUARD_BATCH == 2
  #define SENSOR_DEVICE_ID "ESP32-002"
  #define ZONE1_NAME       "Kitchen"
  #define ZONE2_NAME       "Bedroom"
#else
  #define SENSOR_DEVICE_ID "ESP32-001"
  #define ZONE1_NAME       "Entrance"
  #define ZONE2_NAME       "Sala"
#endif

// =============================================================================
//  NETWORK & CLOUD CONFIGURATION
// =============================================================================
#define WIFI_SSID           "Pyroguard_Team"
#define WIFI_PASSWORD       "Pyroguard4"

#define SUPABASE_URL        "https://gljzunjbmmsbkayxtyfc.supabase.co"
#define SUPABASE_ANON_KEY   "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdsanp1bmpibW1zYmtheXh0eWZjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUwNjY1MTgsImV4cCI6MjExMDY0MjUxOH0.PTpkL8ElB23FchzghBXib_V7__hlKBLeKCr844v8kwA"
#define EDGE_FUNCTION_NAME  "sensor-ingest"   // must match the deployed function slug exactly

// This key must be accepted by sensor-ingest: set the Supabase secret
// DEVICE_KEY_ESP32_002 (or DEVICE_KEY_ESP32_001 for batch 1) to this value.
#define SENSOR_DEVICE_KEY   "B92843BBB888A4C390CEC029013DA205517A58BDFE3B6C823ADB7BD4B0766373"

// =============================================================================
//  FEATURE SWITCHES
// =============================================================================
#define ENABLE_WIFI        true    // local /smoke endpoint for the camera page
#define ENABLE_CLOUD       true    // upload readings to the Supabase edge function
#define USE_WINDOW         true    // window reed switch on GPIO 26
#define DOOR_REVERSED      false   // true if the DOOR shows OPEN when it is closed
#define WINDOW_REVERSED    true    // true if the WINDOW shows OPEN when it is closed
#define BUZZER_PASSIVE     false   // true for passive buzzers (real pitch control)
#define BUZZER_ACTIVE_LOW  false   // true if the buzzers sound when they should be silent

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

#if ENABLE_CLOUD && !ENABLE_WIFI
#error "ENABLE_CLOUD requires ENABLE_WIFI"
#endif

// =============================================================================
//  CALIBRATION & THRESHOLDS
// =============================================================================
// ---- Measurement isolation ----
#define BUZZ_SETTLE_US       2000      // buzzer-off settle time before a measurement

// ---- MQ-2 smoke sensors ----
#define MQ2_WARMUP_MS        180000UL  // 3 min heater warm-up after power-on
#define MQ2_SAMPLE_MS        100       // 10 readings per second
#define MQ2_CAL_SAMPLES      30        // 3 s of clean-air averaging for baseline
#define MQ2_CAL_RETRY_MS     10000UL   // retry delay after an invalid baseline
#define MQ2_EMA_ALPHA        0.2f      // smoothing (0..1, lower = smoother)
#define MQ2_MIN_BASELINE_MV  80        // below this: AO wire / divider problem
#define MQ2_MAX_BASELINE_MV  2500      // above this: not clean air, or no divider
#define ADC_MAX_MV           3100      // usable ADC ceiling at 11 dB attenuation
#define ADC_SAT_MV           3050      // readings above this = input saturated
#define SMOKE_WARN_PCT       10        // warning: lighter gas / paper smoke
#define SMOKE_WARN_CLEAR_PCT 7         // warning clears below this
#define SMOKE_ALARM_PCT      20        // buzzer alarm level
#define SMOKE_CLEAR_PCT      14        // alarm clears below this
#define MQ2_TRACK_RATE       0.0005f   // baseline drift tracking per sample
#define MQ2_TRACK_BELOW_PCT  5         // drift tracking only below this level

#if MQ2_TRACK_BELOW_PCT >= SMOKE_WARN_CLEAR_PCT || SMOKE_WARN_CLEAR_PCT >= SMOKE_WARN_PCT \
    || SMOKE_WARN_PCT >= SMOKE_CLEAR_PCT || SMOKE_CLEAR_PCT >= SMOKE_ALARM_PCT
#error "MQ-2 thresholds must satisfy TRACK < WARN_CLEAR < WARN < CLEAR < ALARM"
#endif

// ---- DHT22 temperature / humidity ----
#define DHT_INTERVAL_MS      2500      // DHT22 needs >= 2 s between reads
#define DHT_FAULT_STREAK     5         // consecutive failures before reporting a fault
#define DHT_STALE_MS         30000UL   // last good value is kept this long during dropouts
#define TEMP_OFFSET_C        0.0f      // correction vs. a reference thermometer
#define HUM_OFFSET_PCT       0.0f
#define TEMP_ALARM_C         50.0f     // fixed-temperature alarm
#define TEMP_CLEAR_C         47.0f     // alarm clears below this
#define TEMP_ROR_C           8.0f      // rate-of-rise alarm: this many degrees...
#define TEMP_ROR_WINDOW_MS   60000UL   // ...within this time
#define TEMP_MAX_STEP_C      10.0f     // larger single-read jumps are treated as noise

// ---- IR flame sensors ----
#define FLAME_SAMPLE_MS      10
#define FLAME_WINDOW         50        // 50 samples x 10 ms = 500 ms window
#define FLAME_ON_RATIO       30        // % of window that must detect flame
#define FLAME_HOLD_MS        2000      // keep alarm 2 s after last detection

// ---- Reed switches ----
#define CONTACT_DEBOUNCE_MS  50

// ---- Buzzers ----
#define TONE_HIGH_HZ         4000      // hazard tone (passive buzzer only)
#define TONE_MED_HZ          2000      // door tone   (passive buzzer only)
#define TONE_WINDOW_HZ       2700      // window tone (passive buzzer only)
#define DOOR_BEEP_ON_MS      150       // door: single beep...
#define DOOR_BEEP_OFF_MS     300       // ...every 0.3 s
#define WINDOW_BEEP_ON_MS    70        // window: two short beeps...
#define WINDOW_BEEP_GAP_MS   70        // ...this far apart...
#define WINDOW_PAUSE_MS      600       // ...then a pause
#define CHIRP_MS             480       // power-on chirp length

// ---- Cloud upload ----
#define CLOUD_INTERVAL_MS    10000UL   // routine upload period
#define CLOUD_TIMEOUT_MS     6000      // HTTP connect/response timeout
#define SNAPSHOT_MS          500       // how often readings are handed to the uploader

// ---- Reporting ----
#define STATUS_PRINT_MS      2000

// =============================================================================
//  TYPES & STATE
// =============================================================================
enum Condition : uint8_t {
  C_SMOKE  = 1 << 0,
  C_FLAME  = 1 << 1,
  C_TEMP   = 1 << 2,
  C_DOOR   = 1 << 3,
  C_WINDOW = 1 << 4
};
constexpr uint8_t C_HAZARD  = C_SMOKE | C_FLAME | C_TEMP;
constexpr uint8_t C_OPENING = C_DOOR | C_WINDOW;

enum Mq2State : uint8_t { MQ2_WARMING, MQ2_CALIBRATING, MQ2_READY };
enum Mq2Fault : uint8_t { MQ2_OK, MQ2_NO_SIGNAL, MQ2_SATURATED };

struct Mq2Data {
  Mq2State state      = MQ2_WARMING;
  Mq2Fault fault      = MQ2_OK;
  float    emaMv      = 0;
  float    baselineMv = 0;
  uint8_t  level      = 0;         // % above baseline
  bool     alarm      = false;
  bool     warn       = false;     // warning band (with hysteresis)
  uint32_t calSum     = 0;
  uint8_t  calCount   = 0;
  uint32_t lastSample = 0;
  uint32_t retryAt    = 0;
};

struct FlameData {
  uint8_t  window[FLAME_WINDOW] = {0};
  uint8_t  idx        = 0;
  uint8_t  lowCount   = 0;
  uint32_t lastSample = 0;
  uint32_t lastSeen   = 0;
  bool     seen       = false;
  bool     alarm      = false;
};

constexpr uint8_t ROR_SLOTS = TEMP_ROR_WINDOW_MS / DHT_INTERVAL_MS;

struct ClimateData {
  float    temp        = NAN;
  float    hum         = NAN;
  float    rise        = 0;
  float    med[3]      = {0, 0, 0};
  uint8_t  medCount    = 0, medIdx = 0;
  float    hist[ROR_SLOTS] = {0};
  uint8_t  histCount   = 0, histIdx = 0;
  uint8_t  failStreak  = 0;
  uint8_t  spikeStreak = 0;
  bool     fault       = false;
  bool     alarm       = false;
  uint32_t lastRead    = 0;
  uint32_t lastGood    = 0;
};

// One sensor zone = one MQ-2 + one flame sensor + one DHT22
struct Zone {
  const char* name;
  uint8_t     mq2Pin;
  uint8_t     flamePin;
  bool        flamePullup;       // GPIO 33 has an internal pull-up, GPIO 35 does not
  DHT*        dht;
  Mq2Data     mq2;
  FlameData   flame;
  ClimateData climate;
  bool        fireLatch;         // used only for logging fire start / end
};

struct Contact {
  uint8_t     pin;
  const char* name;
  bool        enabled;
  bool        reversed;          // invert this switch's reading
  bool        open;
  bool        raw;
  uint32_t    rawChangedAt;
};

enum BuzzMode : uint8_t { BZ_OFF, BZ_CHIRP, BZ_DOOR, BZ_WINDOW, BZ_BOTH, BZ_HAZARD };

struct BuzzerData {              // pattern logic (shared by all buzzers)
  BuzzMode mode       = BZ_OFF;
  BuzzMode testMode   = BZ_OFF;
  uint32_t phaseStart = 0;
  uint32_t chirpUntil = 0;
};

struct BuzzerOut {               // one physical buzzer
  uint8_t  pin;
  bool     activeLow;
  bool     outOn;
  uint16_t outFreq;
};

DHT   dht1(PIN_DHT,   DHT22);
DHT   dht2(PIN_DHT_2, DHT22);

constexpr uint8_t ZONE_COUNT = 2;
Zone zones[ZONE_COUNT] = {
  { ZONE1_NAME, PIN_MQ2_AO,   PIN_FLAME,   false, &dht1, {}, {}, {}, false },
  { ZONE2_NAME, PIN_MQ2_AO_2, PIN_FLAME_2, true,  &dht2, {}, {}, {}, false },
};

constexpr uint8_t BUZZER_COUNT = 4;
BuzzerOut buzzers[BUZZER_COUNT] = {
  { PIN_BUZZER_1, BUZZER_ACTIVE_LOW, false, 0 },
  { PIN_BUZZER_2, BUZZER_ACTIVE_LOW, false, 0 },
  { PIN_BUZZER_3, BUZZER_ACTIVE_LOW, false, 0 },
  { PIN_BUZZER_4, BUZZER_ACTIVE_LOW, false, 0 },
};
BuzzerData bz;

Contact doorSw   = { PIN_DOOR,   "Door",   true,       DOOR_REVERSED,   false, false, 0 };
Contact windowSw = { PIN_WINDOW, "Window", USE_WINDOW, WINDOW_REVERSED, false, false, 0 };

bool     muted      = false;
uint8_t  mutedMask  = 0;
bool     quietMode  = false;
uint32_t lastStatus = 0;

#if ENABLE_WIFI
WebServer server(80);
bool wifiUp = false;
#endif

// =============================================================================
//  UTILITIES
// =============================================================================
void logEvent(const char* fmt, ...) {
  char msg[160];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof(msg), fmt, ap);
  va_end(ap);
  Serial.printf("[%8.1fs] %s\n", millis() / 1000.0f, msg);
}

static float median3(float a, float b, float c) {
  return fmaxf(fminf(a, b), fminf(fmaxf(a, b), c));
}

static void fmtFloat(char* out, size_t n, float v) {
  if (isnan(v)) snprintf(out, n, "null");
  else          snprintf(out, n, "%.1f", v);
}

// ---- Low-level buzzer drive + measurement isolation ----
void buzzerIdle(const BuzzerOut &b) {
  pinMode(b.pin, OUTPUT);
  digitalWrite(b.pin, b.activeLow ? HIGH : LOW);
}

void buzzerDrive(const BuzzerOut &b, bool on, uint16_t freq) {
#if BUZZER_PASSIVE
  if (on) tone(b.pin, freq);
  else  { noTone(b.pin); buzzerIdle(b); }
#else
  (void)freq;                                                  // active buzzer: fixed pitch
  digitalWrite(b.pin, (on ^ b.activeLow) ? HIGH : LOW);
#endif
}

// Silence all buzzers for the length of one measurement. Their switching
// current otherwise disturbs the 3.3 V rail and ground the ADC and DHT22 use.
void measureBegin() {
  bool any = false;
  for (auto &b : buzzers) if (b.outOn) { buzzerDrive(b, false, 0); any = true; }
  if (any) delayMicroseconds(BUZZ_SETTLE_US);
}

void measureEnd() {
  for (auto &b : buzzers) if (b.outOn) buzzerDrive(b, true, b.outFreq);
}

// ---- Zone helpers ----
bool zoneFire(const Zone &z) { return z.mq2.alarm && z.flame.alarm; }

bool anyFire() {
  for (auto &z : zones) if (zoneFire(z)) return true;
  return false;
}

uint8_t conditionMask() {
  uint8_t m = 0;
  for (auto &z : zones) {
    if (z.mq2.alarm)     m |= C_SMOKE;
    if (z.flame.alarm)   m |= C_FLAME;
    if (z.climate.alarm) m |= C_TEMP;
  }
  if (doorSw.enabled && doorSw.open)     m |= C_DOOR;
  if (windowSw.enabled && windowSw.open) m |= C_WINDOW;
  return m;
}

const char* alarmName(uint8_t m) {
  if ((m & C_SMOKE) && (m & C_FLAME) && anyFire()) return "fire";
  if (m & C_FLAME)  return "flame";
  if (m & C_SMOKE)  return "smoke";
  if (m & C_TEMP)   return "temperature";
  if (m & C_DOOR)   return "door";
  if (m & C_WINDOW) return "window";
  return "none";
}

const char* smokeStatus(const Zone &z) {
  if (z.mq2.state != MQ2_READY) return "warming";
  if (z.mq2.fault != MQ2_OK)    return "fault";
  if (z.mq2.alarm)              return "danger";
  if (z.mq2.warn)               return "warning";
  return "normal";
}

const char* mq2FaultName(const Zone &z) {
  switch (z.mq2.fault) {
    case MQ2_NO_SIGNAL: return "no_signal";
    case MQ2_SATURATED: return "saturated";
    default:            return "ok";
  }
}

// =============================================================================
//  MQ-2 SMOKE SENSORS (analog)
// =============================================================================
uint32_t readMq2Mv(uint8_t pin) {
  measureBegin();
  uint32_t sum = 0;
  for (uint8_t i = 0; i < 8; i++) sum += analogReadMilliVolts(pin);   // factory-calibrated
  measureEnd();
  return sum / 8;
}

void startMq2Calibration(Zone &z) {
  z.mq2.state    = MQ2_CALIBRATING;
  z.mq2.calSum   = 0;
  z.mq2.calCount = 0;
  z.mq2.alarm    = false;
  z.mq2.warn     = false;
  logEvent("%s MQ-2: measuring clean-air baseline (keep the sensor in clean air)...", z.name);
}

void updateMq2Fault(Zone &z, Mq2Fault f) {
  if (f == z.mq2.fault) return;
  z.mq2.fault = f;
  if (f == MQ2_NO_SIGNAL)
    logEvent("%s MQ-2 FAULT: signal near 0 V - check AO wire, divider and MQ-2 power", z.name);
  else if (f == MQ2_SATURATED)
    logEvent("%s MQ-2 FAULT: signal at ADC maximum - check MQ-2 GND and the 10k/20k divider", z.name);
  else
    logEvent("%s MQ-2 signal back in normal range", z.name);
}

void updateMq2(Zone &z, uint32_t now) {
  Mq2Data &m = z.mq2;
  if (now - m.lastSample < MQ2_SAMPLE_MS) return;
  m.lastSample = now;

  uint32_t mv = readMq2Mv(z.mq2Pin);
  m.emaMv = (m.emaMv == 0) ? mv : m.emaMv + MQ2_EMA_ALPHA * ((float)mv - m.emaMv);

  switch (m.state) {
    case MQ2_WARMING:
      if (now >= MQ2_WARMUP_MS && (int32_t)(now - m.retryAt) >= 0) startMq2Calibration(z);
      break;

    case MQ2_CALIBRATING:
      m.calSum += mv;
      if (++m.calCount >= MQ2_CAL_SAMPLES) {
        float base = (float)m.calSum / m.calCount;
        if (base < MQ2_MIN_BASELINE_MV || base > MQ2_MAX_BASELINE_MV) {
          // Reject a baseline that cannot come from a working sensor in clean air
          logEvent("%s MQ-2: invalid baseline %u mV (expected %u-%u) - check wiring, retrying in %lu s",
                   z.name, (unsigned)base, MQ2_MIN_BASELINE_MV, MQ2_MAX_BASELINE_MV,
                   MQ2_CAL_RETRY_MS / 1000);
          updateMq2Fault(z, base < MQ2_MIN_BASELINE_MV ? MQ2_NO_SIGNAL : MQ2_SATURATED);
          m.state   = MQ2_WARMING;
          m.retryAt = now + MQ2_CAL_RETRY_MS;
          break;
        }
        m.baselineMv = base;
        m.emaMv      = base;
        m.state      = MQ2_READY;
        updateMq2Fault(z, MQ2_OK);
        logEvent("%s MQ-2: ready, baseline %u mV", z.name, (unsigned)base);
      }
      break;

    case MQ2_READY: {
      // Wiring sanity check (the alarm itself still follows the reading: fail-safe)
      if (m.emaMv >= ADC_SAT_MV)                    updateMq2Fault(z, MQ2_SATURATED);
      else if (m.emaMv < MQ2_MIN_BASELINE_MV / 2)   updateMq2Fault(z, MQ2_NO_SIGNAL);
      else                                          updateMq2Fault(z, MQ2_OK);

      float span = (float)ADC_MAX_MV - m.baselineMv;
      if (span < 100) span = 100;
      float pct = (m.emaMv - m.baselineMv) * 100.0f / span;
      m.level = (uint8_t)constrain(pct, 0.0f, 100.0f);

      // Follow slow clean-air drift; frozen while smoke is present
      if (m.level < MQ2_TRACK_BELOW_PCT && m.fault == MQ2_OK)
        m.baselineMv += MQ2_TRACK_RATE * (m.emaMv - m.baselineMv);

      bool prev = m.alarm;
      if (!m.alarm && m.level >= SMOKE_ALARM_PCT)     m.alarm = true;
      else if (m.alarm && m.level < SMOKE_CLEAR_PCT)  m.alarm = false;
      if (m.alarm != prev)
        logEvent(m.alarm ? "%s: SMOKE ALARM - level %u%%" : "%s: smoke cleared - level %u%%",
                 z.name, m.level);

      // Warning band with its own hysteresis (gas or light smoke)
      bool prevWarn = m.warn;
      if (!m.warn && m.level >= SMOKE_WARN_PCT)           m.warn = true;
      else if (m.warn && m.level < SMOKE_WARN_CLEAR_PCT)  m.warn = false;
      if (m.warn != prevWarn && !m.alarm)
        logEvent(m.warn ? "%s: SMOKE WARNING - level %u%% (gas or light smoke)"
                        : "%s: smoke warning cleared - level %u%%", z.name, m.level);
      break;
    }
  }
}

// =============================================================================
//  IR FLAME SENSORS (sliding-window confirmation)
// =============================================================================
void updateFlame(Zone &z, uint32_t now) {
  FlameData &f = z.flame;
  if (now - f.lastSample < FLAME_SAMPLE_MS) return;
  f.lastSample = now;

  uint8_t detected = digitalRead(z.flamePin) == LOW;     // module pulls LOW on flame
  f.lowCount = f.lowCount + detected - f.window[f.idx];
  f.window[f.idx] = detected;
  f.idx = (f.idx + 1) % FLAME_WINDOW;

  if ((uint16_t)f.lowCount * 100 >= (uint16_t)FLAME_ON_RATIO * FLAME_WINDOW) {
    f.lastSeen = now;
    f.seen     = true;
  }

  bool prev = f.alarm;
  f.alarm = f.seen && (now - f.lastSeen < FLAME_HOLD_MS);
  if (f.alarm != prev) logEvent(f.alarm ? "%s: FLAME DETECTED" : "%s: flame cleared", z.name);
}

// =============================================================================
//  DHT22 TEMPERATURE / HUMIDITY (validated + filtered)
// =============================================================================
void updateClimate(Zone &z, uint32_t now) {
  ClimateData &c = z.climate;
  if (now - c.lastRead < DHT_INTERVAL_MS) return;
  c.lastRead = now;

  measureBegin();                                    // quiet supply during the transfer
  float t = z.dht->readTemperature(false, true);     // force a fresh conversion
  float h = z.dht->readHumidity();                   // uses the same conversion
  measureEnd();

  // 1. Reject failed or physically impossible readings
  if (isnan(t) || isnan(h) || t < -40 || t > 80 || h < 0 || h > 100) {
    if (++c.failStreak == DHT_FAULT_STREAK) {
      c.fault = true;
      logEvent("%s DHT22 not responding - holding last value (check DATA wire / pull-up)", z.name);
    }
    if (!isnan(c.temp) && now - c.lastGood > DHT_STALE_MS) {
      c.temp = NAN;                                  // too old to trust
      c.hum  = NAN;
      logEvent("%s DHT22 FAULT - no valid reading for %lu s", z.name, DHT_STALE_MS / 1000);
    }
    return;
  }
  if (c.fault) logEvent("%s DHT22 recovered", z.name);
  c.fault = false;
  c.failStreak = 0;
  c.lastGood = now;

  t += TEMP_OFFSET_C;
  h  = constrain(h + HUM_OFFSET_PCT, 0.0f, 100.0f);

  // 2. Ignore a single sudden jump; accept it if the next read confirms it
  if (!isnan(c.temp) && fabsf(t - c.temp) > TEMP_MAX_STEP_C && c.spikeStreak == 0) {
    c.spikeStreak = 1;
    return;
  }
  c.spikeStreak = 0;

  // 3. Median of the last three readings
  c.med[c.medIdx] = t;
  c.medIdx = (c.medIdx + 1) % 3;
  if (c.medCount < 3) c.medCount++;
  c.temp = (c.medCount < 3) ? t : median3(c.med[0], c.med[1], c.med[2]);
  c.hum  = h;

  // 4. Rate of rise over the last TEMP_ROR_WINDOW_MS
  c.rise = (c.histCount == ROR_SLOTS) ? c.temp - c.hist[c.histIdx] : 0;
  c.hist[c.histIdx] = c.temp;
  c.histIdx = (c.histIdx + 1) % ROR_SLOTS;
  if (c.histCount < ROR_SLOTS) c.histCount++;

  // 5. Alarm with hysteresis
  bool prev = c.alarm;
  bool high = c.temp >= TEMP_ALARM_C;
  bool ror  = c.rise >= TEMP_ROR_C;
  if (!c.alarm && (high || ror)) {
    c.alarm = true;
    if (high) logEvent("%s: HIGH TEMPERATURE ALARM - %.1f C", z.name, c.temp);
    else      logEvent("%s: RAPID TEMPERATURE RISE ALARM - +%.1f C in 60 s", z.name, c.rise);
  } else if (c.alarm && c.temp < TEMP_CLEAR_C && c.rise < TEMP_ROR_C / 2) {
    c.alarm = false;
  }
  if (prev && !c.alarm) logEvent("%s: temperature back to normal - %.1f C", z.name, c.temp);
}

// =============================================================================
//  REED SWITCHES (door / window)
// =============================================================================
bool readContactRaw(const Contact &c) {
  bool open = digitalRead(c.pin) == HIGH;  // switch open = HIGH via pull-up
  return c.reversed ? !open : open;        // per-sensor correction (NC vs NO wiring)
}

void updateContact(Contact &c, uint32_t now) {
  if (!c.enabled) return;
  bool r = readContactRaw(c);
  if (r != c.raw) { c.raw = r; c.rawChangedAt = now; }
  if (r != c.open && now - c.rawChangedAt >= CONTACT_DEBOUNCE_MS) {
    c.open = r;
    logEvent("%s %s", c.name, c.open ? "OPENED" : "CLOSED");
  }
}

// =============================================================================
//  ALERT STATE (mute + per-zone fire confirmation)
// =============================================================================
void updateAlertState(uint8_t mask) {
  if (mask == 0) muted = false;                                // situation over
  if (muted && (mask & ~mutedMask)) {                          // something new happened
    muted = false;
    logEvent("New condition (%s) - mute cancelled", alarmName(mask & ~mutedMask));
  }

  for (auto &z : zones) {
    bool fire = zoneFire(z);
    if (fire && !z.fireLatch) logEvent(">>> FIRE CONFIRMED in %s - smoke AND flame detected <<<", z.name);
    if (!fire && z.fireLatch) logEvent("%s: fire condition cleared", z.name);
    z.fireLatch = fire;
  }
}

// =============================================================================
//  BUZZERS (non-blocking, situation-driven, all four together)
// =============================================================================
void buzzerOutput(BuzzerOut &b, bool on, uint16_t freq) {
  if (on == b.outOn && (!on || freq == b.outFreq)) return;     // no change, no work
  b.outOn = on;
  b.outFreq = freq;
  buzzerDrive(b, on, freq);
}

// Drive all four buzzers with the same sound (four buzzers = louder alarm)
void setBuzzers(bool on, uint16_t freq) {
  for (auto &b : buzzers) buzzerOutput(b, on, freq);
}

// Beep patterns: return true while the buzzers should sound at time t (ms)
constexpr uint32_t DOOR_CYCLE_MS   = DOOR_BEEP_ON_MS + DOOR_BEEP_OFF_MS;
constexpr uint32_t WINDOW_CYCLE_MS = 2 * WINDOW_BEEP_ON_MS + WINDOW_BEEP_GAP_MS + WINDOW_PAUSE_MS;

bool doorPattern(uint32_t t) {                 // beep . . beep . . beep
  return t % DOOR_CYCLE_MS < DOOR_BEEP_ON_MS;
}

bool windowPattern(uint32_t t) {               // beep-beep . . . . beep-beep
  t %= WINDOW_CYCLE_MS;
  return t < WINDOW_BEEP_ON_MS ||
         (t >= WINDOW_BEEP_ON_MS + WINDOW_BEEP_GAP_MS &&
          t <  2 * WINDOW_BEEP_ON_MS + WINDOW_BEEP_GAP_MS);
}

void updateBuzzer(uint32_t now, uint8_t mask) {
  BuzzMode want = BZ_OFF;
  if (!muted && (mask & C_HAZARD))                      want = BZ_HAZARD;   // a real hazard always wins
  else if (bz.testMode != BZ_OFF)                       want = bz.testMode;
  else if (!muted && (mask & C_OPENING) == C_OPENING)   want = BZ_BOTH;
  else if (!muted && (mask & C_DOOR))                   want = BZ_DOOR;
  else if (!muted && (mask & C_WINDOW))                 want = BZ_WINDOW;
  else if ((int32_t)(bz.chirpUntil - now) > 0)          want = BZ_CHIRP;

  if (want != bz.mode) { bz.mode = want; bz.phaseStart = now; }
  uint32_t t = now - bz.phaseStart;

  switch (bz.mode) {
    case BZ_HAZARD: setBuzzers(true, TONE_HIGH_HZ); break;
    case BZ_DOOR:   setBuzzers(doorPattern(t), TONE_MED_HZ); break;
    case BZ_WINDOW: setBuzzers(windowPattern(t), TONE_WINDOW_HZ); break;
    case BZ_BOTH: {                            // one door cycle, then one window cycle
      uint32_t c = t % (DOOR_CYCLE_MS + WINDOW_CYCLE_MS);
      if (c < DOOR_CYCLE_MS) setBuzzers(doorPattern(c), TONE_MED_HZ);
      else                   setBuzzers(windowPattern(c - DOOR_CYCLE_MS), TONE_WINDOW_HZ);
      break;
    }
    case BZ_CHIRP:  setBuzzers(t % 160 < 70, TONE_MED_HZ); break;
    default:        setBuzzers(false, 0); break;
  }
}

// =============================================================================
//  CLOUD UPLOAD (Supabase edge function, separate FreeRTOS task)
// =============================================================================
#if ENABLE_CLOUD
struct ZoneSnap {
  uint8_t     smokeLevel;
  uint16_t    smokeMv;
  const char* smokeStatus;
  const char* smokeFault;
  float       temp, hum;
  bool        tempAlarm, flame, fire;
};

struct Snapshot {
  ZoneSnap    z[ZONE_COUNT];
  bool        fire, muted;
  bool        doorOpen, windowOpen, windowEnabled;
  const char* alarm;
  uint32_t    uptimeS;
};

portMUX_TYPE snapMux  = portMUX_INITIALIZER_UNLOCKED;
Snapshot     snap;
bool         snapValid = false;
bool         cloudKick = false;            // send immediately (state change)

volatile int      cloudLastCode = 0;       // last HTTP status (negative = transport error)
volatile uint32_t cloudLastAt   = 0;       // millis() of last attempt
volatile uint32_t cloudOkCount  = 0, cloudFailCount = 0;

void publishSnapshot(bool urgent) {
  Snapshot s;
  for (uint8_t i = 0; i < ZONE_COUNT; i++) {
    const Zone &z = zones[i];
    s.z[i].smokeLevel  = z.mq2.level;
    s.z[i].smokeMv     = (uint16_t)z.mq2.emaMv;
    s.z[i].smokeStatus = smokeStatus(z);
    s.z[i].smokeFault  = mq2FaultName(z);
    s.z[i].temp        = z.climate.temp;
    s.z[i].hum         = z.climate.hum;
    s.z[i].tempAlarm   = z.climate.alarm;
    s.z[i].flame       = z.flame.alarm;
    s.z[i].fire        = zoneFire(z);
  }
  s.fire          = anyFire();
  s.muted         = muted;
  s.doorOpen      = doorSw.open;
  s.windowOpen    = windowSw.open;
  s.windowEnabled = windowSw.enabled;
  s.alarm         = alarmName(conditionMask());
  s.uptimeS       = millis() / 1000;

  portENTER_CRITICAL(&snapMux);
  snap = s;
  snapValid = true;
  if (urgent) cloudKick = true;
  portEXIT_CRITICAL(&snapMux);
}

static const char* tf(bool b) { return b ? "true" : "false"; }

void cloudTask(void*) {
  const String url = String(SUPABASE_URL) + "/functions/v1/" + EDGE_FUNCTION_NAME;
  uint32_t lastSend = 0;
  int      lastLoggedCode = 0;

  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(100));
    if (WiFi.status() != WL_CONNECTED) continue;
    if (time(nullptr) < 1700000000) continue;     // certificate check needs real time (NTP)

    Snapshot s;
    bool kick, valid;
    portENTER_CRITICAL(&snapMux);
    kick = cloudKick; valid = snapValid;
    if (valid) s = snap;
    portEXIT_CRITICAL(&snapMux);

    if (!valid) continue;
    if (!kick && millis() - lastSend < CLOUD_INTERVAL_MS) continue;

    portENTER_CRITICAL(&snapMux);
    cloudKick = false;
    portEXIT_CRITICAL(&snapMux);

    char t1[10], h1[10], t2[10], h2[10];
    fmtFloat(t1, sizeof(t1), s.z[0].temp);
    fmtFloat(h1, sizeof(h1), s.z[0].hum);
    fmtFloat(t2, sizeof(t2), s.z[1].temp);
    fmtFloat(h2, sizeof(h2), s.z[1].hum);

    // Zone 1 keeps the original field names; zone 2 uses the "2" fields
    char body[900];
    snprintf(body, sizeof(body),
      "{\"device_id\":\"%s\",\"device_key\":\"%s\",\"event\":\"%s\","
      "\"smoke_level\":%u,\"smoke_mv\":%u,\"smoke_status\":\"%s\",\"smoke_fault\":\"%s\","
      "\"temperature\":%s,\"humidity\":%s,\"temp_alarm\":%s,\"flame\":%s,\"fire1\":%s,"
      "\"smoke2_level\":%u,\"smoke2_mv\":%u,\"smoke2_status\":\"%s\",\"smoke2_fault\":\"%s\","
      "\"temperature2\":%s,\"humidity2\":%s,\"temp2_alarm\":%s,\"flame2\":%s,\"fire2\":%s,"
      "\"fire\":%s,\"door\":\"%s\",\"window\":\"%s\","
      "\"alarm\":\"%s\",\"muted\":%s,\"uptime_s\":%lu,\"rssi\":%d}",
      SENSOR_DEVICE_ID, SENSOR_DEVICE_KEY, kick ? "change" : "periodic",
      s.z[0].smokeLevel, s.z[0].smokeMv, s.z[0].smokeStatus, s.z[0].smokeFault,
      t1, h1, tf(s.z[0].tempAlarm), tf(s.z[0].flame), tf(s.z[0].fire),
      s.z[1].smokeLevel, s.z[1].smokeMv, s.z[1].smokeStatus, s.z[1].smokeFault,
      t2, h2, tf(s.z[1].tempAlarm), tf(s.z[1].flame), tf(s.z[1].fire),
      tf(s.fire), s.doorOpen ? "open" : "closed",
      s.windowEnabled ? (s.windowOpen ? "open" : "closed") : "n/a",
      s.alarm, tf(s.muted), (unsigned long)s.uptimeS, (int)WiFi.RSSI());

    WiFiClientSecure client;
    client.setCACert(SUPABASE_CA_ROOTS);       // verify Supabase's TLS certificate
    HTTPClient http;
    http.setConnectTimeout(CLOUD_TIMEOUT_MS);
    http.setTimeout(CLOUD_TIMEOUT_MS);

    int code = -1;
    String reply;
    if (http.begin(client, url)) {
      http.addHeader("Content-Type", "application/json");
      http.addHeader("apikey", SUPABASE_ANON_KEY);
      http.addHeader("Authorization", "Bearer " SUPABASE_ANON_KEY);
      http.addHeader("x-device-id", SENSOR_DEVICE_ID);
      http.addHeader("x-device-key", SENSOR_DEVICE_KEY);
      code = http.POST((uint8_t*)body, strlen(body));
      if (code > 0 && (code < 200 || code >= 300)) reply = http.getString();
      http.end();
    }

    lastSend      = millis();
    cloudLastAt   = lastSend;
    cloudLastCode = code;
    bool ok = code >= 200 && code < 300;
    if (ok) cloudOkCount++; else cloudFailCount++;

    // Log only when the result changes, to keep the Serial Monitor readable
    if (code != lastLoggedCode) {
      lastLoggedCode = code;
      if (ok)            logEvent("Cloud: upload OK (HTTP %d)", code);
      else if (code > 0) logEvent("Cloud: upload rejected (HTTP %d) %s", code, reply.substring(0, 80).c_str());
      else               logEvent("Cloud: upload failed (%s)", HTTPClient::errorToString(code).c_str());
    }
  }
}

void printCloudStatus() {
  if (cloudLastAt == 0) { Serial.println("Cloud: no upload attempted yet"); return; }
  Serial.printf("Cloud: last HTTP %d, %lu s ago, %lu OK / %lu failed\n",
                (int)cloudLastCode, (unsigned long)((millis() - cloudLastAt) / 1000),
                (unsigned long)cloudOkCount, (unsigned long)cloudFailCount);
}
#endif

// =============================================================================
//  STATUS REPORT
// =============================================================================
void printZone(const Zone &z, uint32_t now) {
  const ClimateData &c = z.climate;
  const Mq2Data     &m = z.mq2;

  Serial.printf(" [%s]%s\n", z.name, zoneFire(z) ? "  *** FIRE CONFIRMED ***" : "");
  if (isnan(c.temp))
    Serial.printf("   Temperature : no valid reading (check DHT22 on GPIO %d)\n",
                  z.dht == &dht1 ? PIN_DHT : PIN_DHT_2);
  else
    Serial.printf("   Temperature : %.1f C   Humidity: %.1f %%   Rise/60s: %+.1f C%s%s\n",
                  c.temp, c.hum, c.rise, c.alarm ? "   [ALARM]" : "",
                  c.fault ? "   (last good value, retrying)" : "");

  if (m.state == MQ2_WARMING && now < MQ2_WARMUP_MS)
    Serial.printf("   Smoke       : warming up (%lu s left, %.0f mV now)\n",
                  (unsigned long)((MQ2_WARMUP_MS - now) / 1000), m.emaMv);
  else if (m.state == MQ2_WARMING)
    Serial.printf("   Smoke       : waiting to retry calibration (%.0f mV now)\n", m.emaMv);
  else if (m.state == MQ2_CALIBRATING)
    Serial.println("   Smoke       : calibrating baseline...");
  else
    Serial.printf("   Smoke       : %u %%  (%.0f mV, baseline %u mV)  [%s]\n",
                  m.level, m.emaMv, (unsigned)m.baselineMv, smokeStatus(z));
  if (m.fault != MQ2_OK)
    Serial.printf("   Smoke fault : %s - check MQ-2 wiring on GPIO %d\n", mq2FaultName(z), z.mq2Pin);

  Serial.printf("   Flame       : %s\n", z.flame.alarm ? "DETECTED" : "none");
}

void printStatus() {
  uint32_t now  = millis();
  uint8_t  mask = conditionMask();

  Serial.println("------------------------------------------------------------");
  for (auto &z : zones) printZone(z, now);

  Serial.printf(" Door          : %s\n", doorSw.open ? "OPEN" : "closed");
  if (windowSw.enabled) Serial.printf(" Window        : %s\n", windowSw.open ? "OPEN" : "closed");

  if (anyFire())                Serial.print(" Alert         : FIRE CONFIRMED");
  else if (mask & C_HAZARD)     Serial.printf(" Alert         : HAZARD (%s)", alarmName(mask & C_HAZARD));
  else if (mask & C_OPENING)    Serial.printf(" Alert         : %s open", alarmName(mask));
  else                          Serial.print(" Alert         : normal");
  Serial.println(muted ? "  [muted]" : "");

#if ENABLE_WIFI
  if (wifiUp) Serial.printf(" Network       : http://%s/smoke  (RSSI %d dBm)\n",
                            WiFi.localIP().toString().c_str(), (int)WiFi.RSSI());
  else        Serial.println(" Network       : offline (alarms still active)");
#endif
#if ENABLE_CLOUD
  if (cloudLastAt) {
    int c = cloudLastCode;
    Serial.printf(" Cloud         : %s (HTTP %d)\n", (c >= 200 && c < 300) ? "OK" : "FAILED", c);
  }
#endif
}

// =============================================================================
//  SERIAL COMMANDS
// =============================================================================
void printHelp() {
  Serial.println("Commands: status, adc, cloud, m/mute, cal, test alarm, test door, test window, stop, q/quiet, h/help");
}

void recalibrateAll() {
  for (auto &z : zones) startMq2Calibration(z);
}

void handleCommand(const char* in) {
  #define IS(x) (strcmp(in, x) == 0)

  if (IS("h") || IS("help")) {
    printHelp();
  } else if (IS("status")) {
    printStatus();
  } else if (IS("adc")) {
    for (auto &z : zones)
      Serial.printf("%s MQ-2 AO (GPIO %d) now: %u mV, smoothed %.0f mV, baseline %u mV\n",
                    z.name, z.mq2Pin, (unsigned)readMq2Mv(z.mq2Pin), z.mq2.emaMv,
                    (unsigned)z.mq2.baselineMv);
  } else if (IS("cloud")) {
#if ENABLE_CLOUD
    printCloudStatus();
#else
    Serial.println("Cloud upload is disabled (ENABLE_CLOUD false)");
#endif
  } else if (IS("m") || IS("mute")) {
    uint8_t mask = conditionMask();
    if (mask == 0) Serial.println("Nothing to mute");
    else { muted = true; mutedMask = mask; logEvent("Alert MUTED (%s) - new conditions will still sound", alarmName(mask)); }
  } else if (IS("testalarm")) {
    bz.testMode = BZ_HAZARD; Serial.println("Playing hazard tone on all buzzers (type stop to end)");
  } else if (IS("testdoor")) {
    bz.testMode = BZ_DOOR;   Serial.println("Playing door beep on all buzzers (type stop to end)");
  } else if (IS("testwindow")) {
    bz.testMode = BZ_WINDOW; Serial.println("Playing window beep on all buzzers (type stop to end)");
  } else if (IS("stop")) {
    bz.testMode = BZ_OFF;    Serial.println("Test tone stopped");
  } else if (IS("cal") || IS("recal")) {
    if (millis() < MQ2_WARMUP_MS) Serial.println("MQ-2 sensors are still warming up - try again later");
    else recalibrateAll();
  } else if (IS("q") || IS("quiet")) {
    quietMode = !quietMode;
    Serial.println(quietMode ? "Periodic report PAUSED (events still shown)" : "Periodic report RESUMED");
  } else {
    Serial.println("Unknown command");
    printHelp();
  }
  #undef IS
}

void pollSerial() {
  static char    buf[32];
  static uint8_t len = 0;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (len) { buf[len] = '\0'; handleCommand(buf); len = 0; }
    } else if (ch != ' ' && len < sizeof(buf) - 1) {
      buf[len++] = tolower((unsigned char)ch);
    }
  }
}

// =============================================================================
//  LOCAL NETWORK (camera page feed)
// =============================================================================
#if ENABLE_WIFI
void handleSmoke() {
  uint32_t now = millis();
  const Zone &a = zones[0];
  const Zone &b = zones[1];
  char t1[10], h1[10], t2[10], h2[10];
  fmtFloat(t1, sizeof(t1), a.climate.temp);
  fmtFloat(h1, sizeof(h1), a.climate.hum);
  fmtFloat(t2, sizeof(t2), b.climate.temp);
  fmtFloat(h2, sizeof(h2), b.climate.hum);

  bool ready = a.mq2.state == MQ2_READY && b.mq2.state == MQ2_READY;
  unsigned long warmLeft = (now < MQ2_WARMUP_MS) ? (MQ2_WARMUP_MS - now) / 1000 : (ready ? 0 : 1);
  uint8_t mask = conditionMask();

  // Zone 1 keeps the original field names so the camera page keeps working
  char json[700];
  snprintf(json, sizeof(json),
    "{\"level\":%u,\"raw\":%u,\"baseline\":%u,\"status\":\"%s\",\"fault\":\"%s\","
    "\"temp\":%s,\"hum\":%s,\"temp_alarm\":%d,\"flame\":%d,\"fire1\":%d,"
    "\"level2\":%u,\"raw2\":%u,\"baseline2\":%u,\"status2\":\"%s\",\"fault2\":\"%s\","
    "\"temp2\":%s,\"hum2\":%s,\"temp_alarm2\":%d,\"flame2\":%d,\"fire2\":%d,"
    "\"warm_left\":%lu,\"door\":\"%s\",\"window\":\"%s\","
    "\"alarm\":\"%s\",\"fire\":%d,\"muted\":%d}",
    a.mq2.level, (unsigned)a.mq2.emaMv, (unsigned)a.mq2.baselineMv, smokeStatus(a), mq2FaultName(a),
    t1, h1, a.climate.alarm ? 1 : 0, a.flame.alarm ? 1 : 0, zoneFire(a) ? 1 : 0,
    b.mq2.level, (unsigned)b.mq2.emaMv, (unsigned)b.mq2.baselineMv, smokeStatus(b), mq2FaultName(b),
    t2, h2, b.climate.alarm ? 1 : 0, b.flame.alarm ? 1 : 0, zoneFire(b) ? 1 : 0,
    warmLeft, doorSw.open ? "open" : "closed",
    windowSw.enabled ? (windowSw.open ? "open" : "closed") : "n/a",
    alarmName(mask), anyFire() ? 1 : 0, muted ? 1 : 0);

  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json", json);
}

void handleRecal() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  if (millis() < MQ2_WARMUP_MS) { server.send(409, "text/plain", "warming"); return; }
  recalibrateAll();
  server.send(200, "text/plain", "OK");
}

void setupNetwork() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);          // non-blocking: sensors start immediately
  configTime(0, 0, "pool.ntp.org", "time.google.com");   // for HTTPS certificate checks
  server.on("/smoke",  HTTP_GET, handleSmoke);
  server.on("/status", HTTP_GET, handleSmoke);
  server.on("/recal",  HTTP_GET, handleRecal);
  server.begin();
  Serial.println("PyroGuard sensor HTTP server started");
}

void updateNetwork() {
  bool up = WiFi.status() == WL_CONNECTED;
  if (up && !wifiUp)  logEvent("WiFi connected to %s - http://%s/smoke (use as SENSOR_IP in the camera sketch)",
                               WIFI_SSID, WiFi.localIP().toString().c_str());
  if (!up && wifiUp)  logEvent("WiFi lost - reconnecting (alarms still active)");
  wifiUp = up;
  if (up) server.handleClient();
}
#endif

// =============================================================================
//  SETUP / LOOP
// =============================================================================
void setup() {
  for (auto &b : buzzers) buzzerIdle(b);         // silence all buzzers immediately
  Serial.begin(115200);
  delay(300);

  analogReadResolution(12);
  for (auto &z : zones) {
    analogSetPinAttenuation(z.mq2Pin, ADC_11db); // 0 - ~3.1 V input range
    pinMode(z.flamePin, z.flamePullup ? INPUT_PULLUP : INPUT);
    z.dht->begin();
  }
  // Stagger the two DHT22 reads so they never happen in the same loop pass
  zones[0].climate.lastRead = millis();
  zones[1].climate.lastRead = millis() - DHT_INTERVAL_MS / 2;

  pinMode(PIN_DOOR, INPUT_PULLUP);
  if (USE_WINDOW) pinMode(PIN_WINDOW, INPUT_PULLUP);
  delay(5);
  doorSw.open = doorSw.raw = readContactRaw(doorSw);
  if (windowSw.enabled) windowSw.open = windowSw.raw = readContactRaw(windowSw);

#if ENABLE_WIFI
  setupNetwork();
#endif
#if ENABLE_CLOUD
  xTaskCreatePinnedToCore(cloudTask, "cloud", 8192, nullptr, 1, nullptr, 0);  // core 0, away from loop()
#endif

  Serial.println();
  Serial.println("============================================================");
  Serial.printf(" PyroGuard Main Controller v3.1-sync  (%s: %s + %s)\n", SENSOR_DEVICE_ID, ZONE1_NAME, ZONE2_NAME);
  Serial.println(" 2 zones x (MQ-2 AO | Flame | DHT22) | Door/Window | 4 Buzzers");
  Serial.println("============================================================");
  for (auto &z : zones)
    Serial.printf(" %s: MQ-2 GPIO %d, Flame GPIO %d, DHT22 GPIO %d\n", z.name, z.mq2Pin, z.flamePin,
                  z.dht == &dht1 ? PIN_DHT : PIN_DHT_2);
  Serial.printf(" MQ-2 warming up for %lu s - smoke alarm starts after calibration\n",
                (unsigned long)(MQ2_WARMUP_MS / 1000));
  Serial.printf(" Door (GPIO %d) is %s\n", PIN_DOOR, doorSw.open ? "OPEN" : "closed");
  if (windowSw.enabled) Serial.printf(" Window (GPIO %d) is %s\n", PIN_WINDOW, windowSw.open ? "OPEN" : "closed");
  Serial.printf(" Buzzers: GPIO %d, %d, %d, %d - same sound on all (%s)\n",
                PIN_BUZZER_1, PIN_BUZZER_2, PIN_BUZZER_3, PIN_BUZZER_4,
                BUZZER_PASSIVE ? "passive" : "active");
  Serial.printf(" Cloud : %s\n", ENABLE_CLOUD ? "uploading to Supabase " EDGE_FUNCTION_NAME : "disabled");
  printHelp();

  bz.chirpUntil = millis() + CHIRP_MS;           // three start-up chirps
}

void loop() {
  uint32_t now = millis();

  // 1. Inputs
  updateContact(doorSw, now);
  updateContact(windowSw, now);
  for (auto &z : zones) {
    updateFlame(z, now);
    updateMq2(z, now);
    updateClimate(z, now);
  }

  // 2. Decision
  uint8_t mask = conditionMask();
  updateAlertState(mask);

  // 3. Outputs
  updateBuzzer(now, mask);

  // 4. Interfaces
  pollSerial();
#if ENABLE_WIFI
  updateNetwork();
#endif
#if ENABLE_CLOUD
  static uint32_t    lastSnap = 0;
  static uint8_t     lastMask = 0;
  static uint8_t     lastFire = 0;
  static const char* lastSmoke[ZONE_COUNT] = { "", "" };
  bool changed = (mask != lastMask);
  uint8_t fireBits = 0;
  for (uint8_t i = 0; i < ZONE_COUNT; i++) {
    const char* st = smokeStatus(zones[i]);       // covers warning and fault changes
    if (st != lastSmoke[i]) { changed = true; lastSmoke[i] = st; }
    if (zoneFire(zones[i])) fireBits |= 1 << i;
  }
  if (fireBits != lastFire) { changed = true; lastFire = fireBits; }
  if (changed || now - lastSnap >= SNAPSHOT_MS) {
    publishSnapshot(changed);                    // a change is uploaded right away
    lastSnap = now;
    lastMask = mask;
  }
#endif

  if (!quietMode && now - lastStatus >= STATUS_PRINT_MS) {
    lastStatus = now;
    printStatus();
  }
}
