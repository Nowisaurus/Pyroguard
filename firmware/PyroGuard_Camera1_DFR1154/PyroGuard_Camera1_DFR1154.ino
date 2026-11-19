/*
  ===================================================
  PYROGUARD CAMERA 1
  DFRobot DFR1154 ESP32-S3
  ===================================================

  FEATURES:
  - Live MJPEG camera stream (auto-starts, auto-reconnects in the web page)
  - JPEG photo capture
  - Camera image controls
  - IR LED controls
  - Lightweight onboard motion detection with X/Y position
  - Background motion processing task
  - Onboard microphone recording + speaker playback
  - WiFi reconnection
  - Optional Supabase integration
  - Direct LAN link with ESP32-001 (/link)
  - Manual PTZ relay for the Flutter app (/ptz)

  WEB DASHBOARD (open http://192.168.8.99/ in a browser):
  - Live video with LIVE badge and a red circle on the moving object
  - Motion ON/OFF, detection count, position
  - Pan/Tilt pad, auto-follow ON/OFF, live servo angles from ESP32-001
  - IR ON/OFF, camera ON/OFF, photo download, fullscreen
  - Brightness / contrast / saturation / sharpness / denoise
  - Listen through the camera microphone, speaker test tone, play a WAV
  - Hardware + Wi-Fi + controller-link status

  CHANGES 2026-11-19 (Supabase sync fix):
  - SUPABASE_URL is the NEW PyroGuard project (gljzunjbmmsbkayxtyfc), the same
    one the app and both ESP32s now use.
  - Cloud ON: heartbeat every 60 s -> camera-ingest -> pyroguard_camera_telemetry.
  - Photos -> camera-ingest -> Storage bucket "incident-media" + camera_events:
      * automatically when motion starts (at most one per CLOUD_MOTION_PHOTO_GAP_MS)
      * when ESP32-001 reports a fire/intrusion (POST /save?reason=fire|intrusion)
      * from the dashboard "Save to cloud" button (/save?reason=manual)
    The incident-email function attaches the newest photo to alert e-mails.
  - /save no longer blocks the web server: it queues the upload for loop().
  - CA bundle now has GTS Root R1 + R4 + ISRG Root X1 (same as the ESP32s).

  CHANGES IN THIS VERSION:
  - Web page rebuilt so every feature is visible and usable in the browser
  - Page JavaScript uses arrow functions (the Arduino IDE no longer
    mistakes it for C++ functions -> no "does not name a type" errors)
  - Page served as UTF-8 (symbols display correctly)
  - /audio/record?sec=1..5 (was fixed at 1 s)
  - /status also reports brightness/contrast/saturation/denoise so the
    page sliders show the real values; RSSI is 0 when Wi-Fi is down
  - CORS headers also allow X-Device-Key and Chrome private-network access
    (helps the Flutter web build reach the camera on the LAN)

  NO SERVO HARDWARE ON THIS CAMERA. The pan/tilt
  servos are wired to ESP32-001 (the main controller).

  AUTOMATIC MOTION-FOLLOWING (system-controlled):
    Camera 1 analyses its own frames and publishes the
    moving object's position (/link). ESP32-001 reads it
    4x per second and DECIDES the servo movement itself.
  MANUAL PTZ (app) always overrides auto-follow:
    Flutter --POST /ptz--> Camera 1 --POST /ptz--> ESP32-001
    ESP32-001 --GET /link (key, IP, angles)--> Camera 1

  Camera 1: pyroguard_camera_001
  Controller: ESP32-001 (separate firmware)
  Batch 1 coverage: Entrance + Sala

  REQUIRED ARDUINO SETTINGS:
  Board: ESP32S3 Dev Module
  USB CDC On Boot: Enabled
  PSRAM: OPI PSRAM
  Flash: 16MB
  Partition: a scheme with at least 3MB APP
  Serial Monitor: 115200

  Built for ESP32 Arduino Core 3.x.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <esp_camera.h>
#include <esp_http_server.h>
#include <img_converters.h>
#include <ESP_I2S.h>
#include <time.h>
#include <cstring>
#include <math.h>
#include <lwip/sockets.h>

// ===================================================
// WIFI AND DEVICE SETTINGS
// ===================================================

#define WIFI_SSID "Pyroguard_Team"
#define WIFI_PASSWORD "Pyroguard4"

#define CAMERA_DEVICE_ID "pyroguard_camera_001"

#define EDGE_FUNCTION_NAME "camera-ingest"
// Set true only if this address is free and your router uses 192.168.8.x.
#define USE_FIXED_CAMERA_IP true
static const IPAddress CAMERA_FIXED_IP(192, 168, 8, 99);
static const IPAddress CAMERA_GATEWAY(192, 168, 8, 1);
static const IPAddress CAMERA_SUBNET(255, 255, 255, 0);
static const IPAddress CAMERA_DNS(192, 168, 8, 1);

#define SUPABASE_URL \
  "https://gljzunjbmmsbkayxtyfc.supabase.co"

// No Supabase API/service-role token belongs in device firmware.
// The key below is checked by camera-ingest against the Supabase secret
// DEVICE_KEY_PYROGUARD_CAMERA_001 (or its SHA-256 / PYROGUARD_DEVICE_KEY).
#define ENABLE_CLOUD true
#define CLOUD_MOTION_PHOTOS true            // upload a photo when motion starts
#define CLOUD_MOTION_PHOTO_GAP_MS 60000UL   // at most one motion photo per minute
#define CAMERA_DEVICE_KEY "8DEBA5CFC59BB60D05E3EAE3249AB333BD0C9895F50C0FC7EB68F8F1C13EEDE1"

// ===================================================
// ESP32-001 PTZ CONTROLLER LINK (LOCAL WI-FI ONLY)
// ===================================================
// MUST be identical to DEVICE_HTTP_KEY in the ESP32-001 sketch.
#define CONTROLLER_HTTP_KEY "BE16B76655384080D1C3D15AE03CAC962DE1BBC4924BD5AC687C7144421A7A10"
#define CONTROLLER_DEVICE_ID "ESP32-001"
#define CONTROLLER_FALLBACK_IP ""
#define CONTROLLER_LINK_FRESH_MS 6000UL
#define PTZ_RELAY_TIMEOUT_MS 900
#define PTZ_RELAY_WAIT_MS 1500UL
#define PTZ_MOTION_SETTLE_MS 700UL

// ===================================================
// STREAM TUNING
// ===================================================
#define STREAM_MIN_FRAME_INTERVAL_MS 40UL
#define STREAM_CAPTURE_RETRIES 3

static const char PYROGUARD_CA_CERT[] = R"EOF(-----BEGIN CERTIFICATE-----
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
)EOF";

// ===================================================
// DFR1154 CAMERA PINS
// ===================================================

#define PWDN_GPIO_NUM -1
#define RESET_GPIO_NUM -1

#define XCLK_GPIO_NUM 5
#define SIOD_GPIO_NUM 8
#define SIOC_GPIO_NUM 9

#define Y9_GPIO_NUM 4
#define Y8_GPIO_NUM 6
#define Y7_GPIO_NUM 7
#define Y6_GPIO_NUM 14
#define Y5_GPIO_NUM 17
#define Y4_GPIO_NUM 21
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 16

#define VSYNC_GPIO_NUM 1
#define HREF_GPIO_NUM 2
#define PCLK_GPIO_NUM 15

#define IR_LED_PIN 47
#define STATUS_LED_PIN 3

// ===================================================
// ONBOARD AUDIO
// ===================================================

#define MIC_PDM_CLK GPIO_NUM_38
#define MIC_PDM_DATA GPIO_NUM_39

#define SPK_I2S_BCLK 45
#define SPK_I2S_LRCLK 46
#define SPK_I2S_DATA 42

#define AUDIO_SAMPLE_RATE 16000
#define MAX_AUDIO_UPLOAD 120000
#define MAX_RECORD_SECONDS 5

I2SClass microphoneI2S;
I2SClass speakerI2S;

bool micReady = false;
bool speakerReady = false;

volatile bool micEnabled = false;
volatile bool speakerEnabled = false;
volatile bool audioBusy = false;

// ===================================================
// PERFORMANCE CONFIGURATION
// ===================================================

#define DEFAULT_FRAME_SIZE FRAMESIZE_VGA
#define DEFAULT_JPEG_QUALITY 10
#define LOCK_VIDEO_QUALITY true
#define DEFAULT_SHARPNESS 2      // -3..3
#define DEFAULT_DENOISE 1        // 0..8

#define MOTION_INTERVAL_MS 300UL
#define MOTION_PIXEL_THRESHOLD 30
#define MOTION_MIN_CHANGED_FRACTION 0.045f
#define MOTION_MAX_CHANGED_FRACTION 0.55f
#define MOTION_CONFIRM_FRAMES 2
#define MOTION_CLEAR_MS 1800UL
#define MOTION_STALE_MS 2400UL
#define MOTION_MAX_WIDTH 400
#define MOTION_MAX_HEIGHT 300
#define MOTION_STEP 16
#define MOTION_GRID_MAX ((MOTION_MAX_WIDTH / MOTION_STEP) * (MOTION_MAX_HEIGHT / MOTION_STEP))
#define MOTION_JPEG_CAPACITY (160 * 1024)

// ===================================================
// GENERAL TIMING
// ===================================================

#define WIFI_TIMEOUT_MS 20000UL
#define WIFI_RETRY_MS 15000UL
#define HEARTBEAT_INTERVAL_MS 60000UL
#define ADDRESS_INTERVAL_MS 30000UL
#define SERIAL_HEALTH_INTERVAL_MS 10000UL

unsigned long lastWifiAttempt = 0;
unsigned long lastHeartbeat = 0;
unsigned long lastAddressPrint = 0;
unsigned long lastServerRetry = 0;
unsigned long lastSerialHealth = 0;

volatile unsigned long lastStreamFrameMs = 0;

// Cloud photo queue (filled by /save and motion, sent by loop()).
volatile int pendingPhotoReason = 0;   // 0 none, 1 manual, 2 motion, 3 fire, 4 intrusion
unsigned long lastMotionPhotoMs = 0;
uint32_t lastPhotoMotionCount = 0;
uint32_t cloudPhotoOk = 0, cloudPhotoFailed = 0;
const char* photoReasonName(int r) {
  switch (r) { case 2: return "motion"; case 3: return "fire"; case 4: return "intrusion"; default: return "manual"; }
}

// ===================================================
// CAMERA STATE
// ===================================================

bool cameraReady = false;
bool serversStarted = false;
bool irEnabled = false;

volatile bool cameraEnabled = true;
volatile int currentFrameSizeIndex = 1;

httpd_handle_t webServer = nullptr;
httpd_handle_t streamServer = nullptr;

// ===================================================
// MOTION STATE AND BUFFERS
// ===================================================

volatile bool motionEnabled = true;
volatile bool motionReady = false;

uint8_t previousLuma[MOTION_GRID_MAX];

uint8_t* motionJPEG = nullptr;
uint8_t* motionPixels = nullptr;
uint16_t motionFrameWidth = 0;
uint16_t motionFrameHeight = 0;
uint16_t motionGridW = 0;
uint16_t motionGridH = 0;

SemaphoreHandle_t motionMutex = nullptr;
TaskHandle_t motionTaskHandle = nullptr;

bool motionJobBusy = false;
size_t motionJPEGLength = 0;
bool motionBackgroundReady = false;

unsigned long lastMotionQueued = 0;
unsigned long lastMotionAnalysis = 0;
unsigned long lastMotionSeen = 0;

bool motionDetected = false;
bool motionCandidate = false;

float motionX = 0.5f;
float motionY = 0.5f;
float motionScore = 0.0f;

uint8_t motionPositiveCount = 0;
uint32_t motionAnalysisCount = 0;
uint32_t motionDetectionCount = 0;

volatile unsigned long ptzSettleUntil = 0;
volatile uint32_t motionChangedSamples = 0;

// ===================================================
// ESP32-001 CONTROLLER LINK STATE
// ===================================================

portMUX_TYPE controllerMux = portMUX_INITIALIZER_UNLOCKED;
uint32_t controllerIp = 0;
unsigned long controllerLastSeen = 0;
int controllerPan = -1;
int controllerTilt = -1;
int controllerTargetPan = -1;
int controllerTargetTilt = -1;
bool controllerMoving = false;
bool controllerAutoFollow = false;
bool controllerAutoPaused = false;
uint32_t controllerLinkCount = 0;

struct PtzRelayJob {
  uint32_t seq;
  char action[12];
  int step;
};

QueueHandle_t ptzQueue = nullptr;
TaskHandle_t ptzRelayTaskHandle = nullptr;
uint32_t ptzNextSeq = 1;
volatile uint32_t ptzDoneSeq = 0;
volatile int ptzDoneHttp = 0;
volatile unsigned long ptzLastRelayMs = 0;
uint32_t ptzRelayOk = 0;
uint32_t ptzRelayFailed = 0;

// ===================================================
// UTILITY
// ===================================================

String boolJson(bool value) {
  return value ? "true" : "false";
}

String edgeURL(const char* action) {
  return String(SUPABASE_URL) + "/functions/v1/" + EDGE_FUNCTION_NAME + "?action=" + action;
}

void addHeaders(httpd_req_t* req) {
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  // Development on a trusted LAN only. This does not authenticate requests.
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type, X-Device-Key");
  // Chrome Private Network Access: lets a localhost Flutter web build call the LAN camera.
  httpd_resp_set_hdr(req, "Access-Control-Allow-Private-Network", "true");
}

static esp_err_t optionsHandler(httpd_req_t* req) {
  addHeaders(req);
  httpd_resp_set_status(req, "204 No Content");
  return httpd_resp_send(req, nullptr, 0);
}

// ===================================================
// WIFI
// ===================================================

bool connectWiFi() {
  lastWifiAttempt = millis();

  Serial.println();
  Serial.println("==================================");
  Serial.println("[WIFI] Starting clean connection");
  Serial.println("==================================");

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("[WIFI] Already connected, IP: ");
    Serial.println(WiFi.localIP());
    return true;
  }

  WiFi.mode(WIFI_OFF);
  delay(500);
  WiFi.mode(WIFI_STA);
  delay(250);
  WiFi.setAutoReconnect(false);
  WiFi.setSleep(false);

  Serial.print("[WIFI] SSID: ");
  Serial.println(WIFI_SSID);

  if (USE_FIXED_CAMERA_IP) {
    if (!WiFi.config(CAMERA_FIXED_IP, CAMERA_GATEWAY, CAMERA_SUBNET, CAMERA_DNS)) {
      Serial.println("[WIFI] Fixed IP configuration failed; retrying later.");
      return false;
    }
    Serial.print("[WIFI] Requested fixed IP: ");
    Serial.println(CAMERA_FIXED_IP);
  } else {
    WiFi.config(IPAddress(0, 0, 0, 0), IPAddress(0, 0, 0, 0), IPAddress(0, 0, 0, 0));
  }

  wl_status_t initialStatus = WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("[WIFI] Initial status: ");
  Serial.println((int)initialStatus);

  unsigned long started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < WIFI_TIMEOUT_MS) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("[WIFI] CONNECTED!");
    Serial.print("[WIFI] IP Address: ");
    Serial.println(WiFi.localIP());
    Serial.print("[WIFI] Gateway: ");
    Serial.println(WiFi.gatewayIP());
    Serial.print("[WIFI] Signal: ");
    Serial.print(WiFi.RSSI());
    Serial.println(" dBm");
    return true;
  }

  Serial.println("[WIFI] CONNECTION FAILED");
  Serial.print("[WIFI] Status: ");
  Serial.println((int)WiFi.status());
  WiFi.disconnect(false, false);
  delay(300);
  return false;
}

void printAddresses() {
  Serial.println();
  Serial.println("====================================");
  Serial.println("       PYROGUARD CAMERA 1           ");
  Serial.println("====================================");
  Serial.print("Device: ");
  Serial.println(CAMERA_DEVICE_ID);

  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("SSID: ");
    Serial.println(WiFi.SSID());
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());
    Serial.printf("HTTP server: %s\n", serversStarted ? "READY" : "NOT READY");
    if (serversStarted) {
      const String ip = WiFi.localIP().toString();
      Serial.printf("WEB DASHBOARD: http://%s/\n", ip.c_str());
      Serial.printf("STREAM:  http://%s:81/stream\n", ip.c_str());
      Serial.printf("CAPTURE: http://%s/capture\n", ip.c_str());
      Serial.printf("STATUS:  http://%s/status\n", ip.c_str());
      Serial.printf("MOTION:  http://%s/motion\n", ip.c_str());
    } else {
      Serial.println("[HTTP] URLs unavailable until servers start; see HTTP errors above.");
    }
  } else {
    Serial.println("WiFi disconnected.");
  }

  Serial.println("====================================");
  lastAddressPrint = millis();
}

// ===================================================
// INITIALIZE CAMERA
// ===================================================

bool initializeCamera() {
  Serial.println("[CAMERA] Initializing sensor...");

  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = DEFAULT_FRAME_SIZE;
  config.jpeg_quality = DEFAULT_JPEG_QUALITY;
  config.grab_mode = CAMERA_GRAB_LATEST;

  if (psramFound()) {
    config.fb_count = 2;
    config.fb_location = CAMERA_FB_IN_PSRAM;
    Serial.println("[CAMERA] PSRAM available.");
  } else {
    config.fb_count = 1;
    config.fb_location = CAMERA_FB_IN_DRAM;
    Serial.println("[CAMERA] No PSRAM.");
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[CAMERA] Init FAILED: 0x%x\n", (unsigned)err);
    return false;
  }

  sensor_t* sensor = esp_camera_sensor_get();
  if (!sensor) {
    Serial.println("[CAMERA] Sensor missing.");
    esp_camera_deinit();
    return false;
  }

  sensor->set_vflip(sensor, 1);
  sensor->set_quality(sensor, DEFAULT_JPEG_QUALITY);
  sensor->set_whitebal(sensor, 1);
  sensor->set_awb_gain(sensor, 1);
  sensor->set_exposure_ctrl(sensor, 1);
  sensor->set_gain_ctrl(sensor, 1);
  sensor->set_brightness(sensor, 0);
  sensor->set_contrast(sensor, 0);
  sensor->set_saturation(sensor, 0);
  sensor->set_special_effect(sensor, 0);

  if (sensor->set_lenc) sensor->set_lenc(sensor, 1);
  if (sensor->set_bpc) sensor->set_bpc(sensor, 1);
  if (sensor->set_wpc) sensor->set_wpc(sensor, 1);
  if (sensor->set_raw_gma) sensor->set_raw_gma(sensor, 1);
  if (sensor->set_dcw) sensor->set_dcw(sensor, 1);
  if (sensor->set_sharpness) sensor->set_sharpness(sensor, DEFAULT_SHARPNESS);
  if (sensor->set_denoise) sensor->set_denoise(sensor, DEFAULT_DENOISE);

  cameraReady = true;
  Serial.println("[CAMERA] READY");
  return true;
}

// ===================================================
// MOTION: QUEUE A COPY OF AN EXISTING JPEG
// ===================================================

void queueMotionFrame(camera_fb_t* frame) {
  if (!motionEnabled || !motionReady) return;
  if (!frame || !motionJPEG || !motionMutex) return;
  if (frame->format != PIXFORMAT_JPEG || frame->width < 64 || frame->height < 48) return;
  if (frame->len == 0 || frame->len > MOTION_JPEG_CAPACITY) return;

  unsigned long now = millis();
  if (now - lastMotionQueued < MOTION_INTERVAL_MS) return;

  if (xSemaphoreTake(motionMutex, 0) != pdTRUE) return;

  if (motionJobBusy) {
    xSemaphoreGive(motionMutex);
    return;
  }

  motionJobBusy = true;
  memcpy(motionJPEG, frame->buf, frame->len);
  motionJPEGLength = frame->len;
  motionFrameWidth = frame->width;
  motionFrameHeight = frame->height;
  lastMotionQueued = now;

  xSemaphoreGive(motionMutex);

  if (motionTaskHandle) xTaskNotifyGive(motionTaskHandle);
}

// ===================================================
// MOTION: BACKGROUND ANALYSIS
// ===================================================

static inline uint8_t rgb565Luma(const uint8_t* px) {
  // esp32-camera writes RGB565 little-endian (low byte first).
  const uint16_t c = (uint16_t)px[0] | ((uint16_t)px[1] << 8);
  const int r = (c >> 8) & 0xF8;
  const int g = (c >> 3) & 0xFC;
  const int b = (c << 3) & 0xF8;
  return (uint8_t)((77 * r + 150 * g + 29 * b) >> 8);
}

void motionWorker(void* parameter) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);

    if (!motionReady || !motionJPEG || !motionPixels || !motionMutex) continue;

    size_t jpegLength = 0;
    uint16_t frameW = 0, frameH = 0;

    if (xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
      if (motionJobBusy) {
        jpegLength = motionJPEGLength;
        frameW = motionFrameWidth;
        frameH = motionFrameHeight;
      }
      xSemaphoreGive(motionMutex);
    }

    if (jpegLength == 0) continue;

    // decltype keeps this working on every esp32-camera version.
    decltype(JPG_SCALE_NONE) scale = JPG_SCALE_NONE;
    uint16_t width = frameW, height = frameH;
    if (width > MOTION_MAX_WIDTH * 4 || height > MOTION_MAX_HEIGHT * 4) {
      scale = JPG_SCALE_8X; width /= 8; height /= 8;
    } else if (width > MOTION_MAX_WIDTH * 2 || height > MOTION_MAX_HEIGHT * 2) {
      scale = JPG_SCALE_4X; width /= 4; height /= 4;
    } else if (width > MOTION_MAX_WIDTH || height > MOTION_MAX_HEIGHT) {
      scale = JPG_SCALE_2X; width /= 2; height /= 2;
    }

    const uint16_t gridW = width / MOTION_STEP;
    const uint16_t gridH = height / MOTION_STEP;
    const int gridSize = gridW * gridH;

    bool converted = gridSize > 0 && gridSize <= MOTION_GRID_MAX &&
                     jpg2rgb565(motionJPEG, jpegLength, motionPixels, scale);

    if (converted && (gridW != motionGridW || gridH != motionGridH)) {
      motionGridW = gridW;
      motionGridH = gridH;
      motionBackgroundReady = false;
    }

    const bool ptzSettling = (long)(ptzSettleUntil - millis()) > 0;

    if (converted && motionEnabled && ptzSettling) {
      if (xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        motionBackgroundReady = false;
        motionCandidate = false;
        motionPositiveCount = 0;
        motionDetected = false;
        motionScore = 0.0f;
        lastMotionAnalysis = millis();
        motionAnalysisCount++;
        xSemaphoreGive(motionMutex);
      }
    } else if (converted && motionEnabled) {
      int changed = 0;
      float sumX = 0.0f;
      float sumY = 0.0f;
      int sampleIndex = 0;

      for (int gy = 0; gy < gridH; gy++) {
        for (int gx = 0; gx < gridW; gx++) {
          int x = gx * MOTION_STEP + MOTION_STEP / 2;
          int y = gy * MOTION_STEP + MOTION_STEP / 2;
          size_t pixelIndex = ((size_t)y * width + (size_t)x) * 2;
          uint8_t luma = rgb565Luma(motionPixels + pixelIndex);

          if (motionBackgroundReady) {
            int difference = abs((int)luma - (int)previousLuma[sampleIndex]);
            if (difference >= MOTION_PIXEL_THRESHOLD) {
              changed++;
              sumX += x;
              sumY += y;
            }
            previousLuma[sampleIndex] = (7 * (int)previousLuma[sampleIndex] + (int)luma) / 8;
          } else {
            previousLuma[sampleIndex] = luma;
          }
          sampleIndex++;
        }
      }

      unsigned long now = millis();

      if (!motionBackgroundReady) {
        motionBackgroundReady = true;
      } else {
        const int minChanged = max(6, (int)(gridSize * MOTION_MIN_CHANGED_FRACTION + 0.5f));
        bool positive = changed >= minChanged &&
                        changed <= (int)(gridSize * MOTION_MAX_CHANGED_FRACTION);
        float score = (float)changed / (float)gridSize;

        if (motionMutex && xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
          motionAnalysisCount++;
          motionCandidate = positive;
          motionScore = score;
          motionChangedSamples = positive ? (uint32_t)changed : 0;
          lastMotionAnalysis = now;

          if (positive) {
            const float newX = (sumX / (float)changed) / width;
            const float newY = (sumY / (float)changed) / height;

            if (motionPositiveCount > 0) {
              motionX = 0.4f * motionX + 0.6f * newX;
              motionY = 0.4f * motionY + 0.6f * newY;
            } else {
              motionX = newX;
              motionY = newY;
            }

            if (motionPositiveCount < 255) motionPositiveCount++;

            if (motionPositiveCount >= MOTION_CONFIRM_FRAMES) {
              if (!motionDetected) {
                motionDetectionCount++;
                Serial.printf("[MOTION] Movement detected x=%.2f y=%.2f\n", motionX, motionY);
              }
              motionDetected = true;
              lastMotionSeen = now;
            }
          } else {
            motionPositiveCount = 0;
            if (now - lastMotionSeen > MOTION_CLEAR_MS) motionDetected = false;
          }

          xSemaphoreGive(motionMutex);
        }
      }
    }

    if (xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
      motionJobBusy = false;
      motionJPEGLength = 0;
      xSemaphoreGive(motionMutex);
    }

    vTaskDelay(pdMS_TO_TICKS(10));
  }
}

// ===================================================
// MOTION INITIALIZATION
// ===================================================

void initializeMotion() {
  Serial.println("[MOTION] Initializing background detector...");

  if (!psramFound()) {
    Serial.println("[MOTION] No PSRAM - detector unavailable.");
    motionEnabled = false;
    return;
  }

  motionJPEG = (uint8_t*)ps_malloc(MOTION_JPEG_CAPACITY);
  motionPixels = (uint8_t*)ps_malloc(MOTION_MAX_WIDTH * MOTION_MAX_HEIGHT * 2);

  if (!motionJPEG || !motionPixels) {
    Serial.println("[MOTION] PSRAM allocation failed.");
    if (motionJPEG) free(motionJPEG);
    if (motionPixels) free(motionPixels);
    motionJPEG = nullptr;
    motionPixels = nullptr;
    motionEnabled = false;
    return;
  }

  motionMutex = xSemaphoreCreateMutex();
  if (!motionMutex) {
    Serial.println("[MOTION] Mutex failed.");
    free(motionJPEG);
    free(motionPixels);
    motionJPEG = nullptr;
    motionPixels = nullptr;
    motionEnabled = false;
    return;
  }

  memset(previousLuma, 0, sizeof(previousLuma));

  BaseType_t result = xTaskCreatePinnedToCore(
    motionWorker, "PyroMotion", 8192, nullptr, 1, &motionTaskHandle, 1);

  if (result != pdPASS) {
    Serial.println("[MOTION] Task creation failed.");
    vSemaphoreDelete(motionMutex);
    motionMutex = nullptr;
    free(motionJPEG);
    free(motionPixels);
    motionJPEG = nullptr;
    motionPixels = nullptr;
    motionEnabled = false;
    return;
  }

  motionReady = true;
  Serial.println("[MOTION] Background detector READY");
}

// ===================================================
// MOTION JSON
// ===================================================

String motionJson() {
  bool detected, candidate, enabled;
  float x, y, score;
  uint32_t analyses, detections;
  unsigned long seen, analyzed;

  const bool locked = motionMutex && xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE;
  detected = motionDetected;
  candidate = motionCandidate;
  enabled = motionEnabled;
  x = motionX;
  y = motionY;
  score = motionScore;
  analyses = motionAnalysisCount;
  detections = motionDetectionCount;
  seen = lastMotionSeen;
  analyzed = lastMotionAnalysis;
  if (locked) xSemaphoreGive(motionMutex);

  const bool fresh = enabled && motionReady && analyzed && millis() - analyzed <= MOTION_STALE_MS;

  String json = "{";
  json += "\"device_id\":\"";
  json += CAMERA_DEVICE_ID;
  json += "\",\"motion_ready\":";
  json += boolJson(motionReady);
  json += ",\"motion_enabled\":";
  json += boolJson(enabled);
  json += ",\"motion_detected\":";
  json += boolJson(fresh && detected);
  json += ",\"motion_candidate\":";
  json += boolJson(candidate);
  json += ",\"motion_x\":";
  json += String(x, 4);
  json += ",\"motion_y\":";
  json += String(y, 4);
  json += ",\"motion_score\":";
  json += String(score, 4);
  json += ",\"analysis_count\":";
  json += String(analyses);
  json += ",\"detection_count\":";
  json += String(detections);
  json += ",\"last_motion_ms\":";
  json += String(seen);
  json += ",\"last_analysis_ms\":";
  json += String(analyzed);
  json += ",\"analysis_age_ms\":";
  json += analyzed ? String(millis() - analyzed) : String("null");
  json += ",\"motion_fresh\":";
  json += boolJson(fresh);
  json += ",\"ptz_settling\":";
  json += boolJson((long)(ptzSettleUntil - millis()) > 0);
  json += ",\"analysis_grid\":\"";
  json += String(motionGridW);
  json += "x";
  json += String(motionGridH);
  json += "\",\"changed_samples\":";
  json += String((unsigned long)motionChangedSamples);
  {
    const int rssi = WiFi.status() == WL_CONNECTED ? WiFi.RSSI() : 0;
    json += ",\"wifi_rssi\":";
    json += String(rssi);
    json += ",\"wifi_rssi_abs\":";
    json += String(abs(rssi));
  }
  json += ",\"uptime_ms\":";
  json += String((unsigned long)millis());
  json += "}";
  return json;
}

// ===================================================
// ESP32-001 LINK + MANUAL PTZ RELAY
// ===================================================

String ipToString(uint32_t ip) {
  return IPAddress(ip).toString();
}

bool keyMatches(const char* supplied) {
  const size_t expectedLength = strlen(CONTROLLER_HTTP_KEY);
  if (!supplied || strlen(supplied) != expectedLength || expectedLength < 16) return false;
  uint8_t diff = 0;
  for (size_t i = 0; i < expectedLength; i++) {
    diff |= (uint8_t)(supplied[i] ^ CONTROLLER_HTTP_KEY[i]);
  }
  return diff == 0;
}

int queryInt(const char* query, const char* key, int fallback) {
  char value[12] = {};
  if (httpd_query_key_value(query, key, value, sizeof(value)) != ESP_OK) return fallback;
  char* end = nullptr;
  long parsed = strtol(value, &end, 10);
  if (end == value) return fallback;
  return (int)parsed;
}

uint32_t currentControllerIp(bool* fresh = nullptr) {
  uint32_t ip;
  unsigned long seen;
  portENTER_CRITICAL(&controllerMux);
  ip = controllerIp;
  seen = controllerLastSeen;
  portEXIT_CRITICAL(&controllerMux);
  const unsigned long now = millis();
  const bool isFresh = ip != 0 && seen != 0 && now - seen <= CONTROLLER_LINK_FRESH_MS;
  if (fresh) *fresh = isFresh;
  if (isFresh) return ip;
  IPAddress fallback;
  if (strlen(CONTROLLER_FALLBACK_IP) > 0 && fallback.fromString(CONTROLLER_FALLBACK_IP)) {
    return (uint32_t)fallback;
  }
  return ip;
}

bool jsonInt(const String& json, const char* key, int& out) {
  String label = String("\"") + key + "\":";
  int pos = json.indexOf(label);
  if (pos < 0) return false;
  pos += label.length();
  const char* start = json.c_str() + pos;
  char* end = nullptr;
  long value = strtol(start, &end, 10);
  if (end == start) return false;
  out = (int)value;
  return true;
}

void ptzRelayWorker(void* parameter) {
  PtzRelayJob job;
  for (;;) {
    if (xQueueReceive(ptzQueue, &job, portMAX_DELAY) != pdTRUE) continue;

    int httpStatus = 0;
    const uint32_t ip = currentControllerIp();

    if (ip != 0 && WiFi.status() == WL_CONNECTED) {
      String url = "http://";
      url += ipToString(ip);
      url += "/ptz?action=";
      url += job.action;
      if (job.step > 0) {
        url += "&step=";
        url += String(job.step);
      }

      HTTPClient http;
      http.setTimeout(PTZ_RELAY_TIMEOUT_MS);
      http.setConnectTimeout(PTZ_RELAY_TIMEOUT_MS);
      http.setReuse(false);

      if (http.begin(url)) {
        http.addHeader("X-Device-Key", CONTROLLER_HTTP_KEY);
        httpStatus = http.POST(String());

        if (httpStatus == 200) {
          const String body = http.getString();
          int pan = -1, tilt = -1, targetPan = -1, targetTilt = -1;
          const bool hasPan = jsonInt(body, "pan", pan);
          const bool hasTilt = jsonInt(body, "tilt", tilt);
          const bool hasTargetPan = jsonInt(body, "target_pan", targetPan);
          const bool hasTargetTilt = jsonInt(body, "target_tilt", targetTilt);
          const bool hasAuto = body.indexOf("\"auto_follow\":") >= 0;
          const bool autoOn = body.indexOf("\"auto_follow\":true") >= 0;
          const bool autoPaused = body.indexOf("\"auto_paused\":true") >= 0;
          const unsigned long now = millis();
          portENTER_CRITICAL(&controllerMux);
          if (hasPan) controllerPan = pan;
          if (hasTilt) controllerTilt = tilt;
          if (hasTargetPan) controllerTargetPan = targetPan;
          if (hasTargetTilt) controllerTargetTilt = targetTilt;
          if (hasAuto) {
            controllerAutoFollow = autoOn;
            controllerAutoPaused = autoPaused;
          }
          controllerMoving = controllerPan != controllerTargetPan ||
                             controllerTilt != controllerTargetTilt;
          controllerLastSeen = now;
          portEXIT_CRITICAL(&controllerMux);
        }
        http.end();
      }
    }

    if (httpStatus == 200) {
      ptzRelayOk++;
      ptzSettleUntil = millis() + PTZ_MOTION_SETTLE_MS;
    } else {
      ptzRelayFailed++;
      Serial.printf("[PTZ] Relay '%s' to %s failed HTTP=%d\n",
                    job.action, ip ? ipToString(ip).c_str() : "(no link)", httpStatus);
    }

    ptzDoneHttp = httpStatus;
    ptzLastRelayMs = millis();
    ptzDoneSeq = job.seq;
  }
}

void initializePtzRelay() {
  ptzQueue = xQueueCreate(3, sizeof(PtzRelayJob));
  if (!ptzQueue) {
    Serial.println("[PTZ] Relay queue failed.");
    return;
  }
  if (xTaskCreatePinnedToCore(ptzRelayWorker, "PtzRelay", 6144, nullptr, 2,
                              &ptzRelayTaskHandle, 0) != pdPASS) {
    vQueueDelete(ptzQueue);
    ptzQueue = nullptr;
    Serial.println("[PTZ] Relay task failed.");
    return;
  }
  Serial.println("[PTZ] Manual PTZ relay READY (Flutter -> /ptz -> ESP32-001)");
}

String controllerJson() {
  uint32_t ip;
  unsigned long seen;
  int pan, tilt, targetPan, targetTilt;
  bool moving, autoFollow, autoPaused;
  uint32_t links;
  portENTER_CRITICAL(&controllerMux);
  ip = controllerIp;
  seen = controllerLastSeen;
  pan = controllerPan;
  tilt = controllerTilt;
  targetPan = controllerTargetPan;
  targetTilt = controllerTargetTilt;
  moving = controllerMoving;
  autoFollow = controllerAutoFollow;
  autoPaused = controllerAutoPaused;
  links = controllerLinkCount;
  portEXIT_CRITICAL(&controllerMux);

  const bool fresh = ip != 0 && seen != 0 && millis() - seen <= CONTROLLER_LINK_FRESH_MS;
  String json = "{\"device_id\":\"";
  json += CONTROLLER_DEVICE_ID;
  json += "\",\"mode\":\"";
  json += !fresh ? "unknown" : !autoFollow ? "manual" : autoPaused ? "auto_paused" : "auto";
  json += "\",\"auto_follow\":";
  json += boolJson(fresh && autoFollow);
  json += ",\"auto_paused\":";
  json += boolJson(fresh && autoFollow && autoPaused);
  json += ",\"linked\":";
  json += boolJson(fresh);
  json += ",\"ip\":";
  if (ip) {
    json += "\"";
    json += ipToString(ip);
    json += "\"";
  } else {
    json += "null";
  }
  json += ",\"age_ms\":";
  json += seen ? String(millis() - seen) : String("null");
  json += ",\"pan\":";
  json += pan >= 0 ? String(pan) : String("null");
  json += ",\"tilt\":";
  json += tilt >= 0 ? String(tilt) : String("null");
  json += ",\"target_pan\":";
  json += targetPan >= 0 ? String(targetPan) : String("null");
  json += ",\"target_tilt\":";
  json += targetTilt >= 0 ? String(targetTilt) : String("null");
  json += ",\"moving\":";
  json += boolJson(fresh && moving);
  json += ",\"link_count\":";
  json += String(links);
  json += ",\"relay_ok\":";
  json += String(ptzRelayOk);
  json += ",\"relay_failed\":";
  json += String(ptzRelayFailed);
  json += ",\"relay_ready\":";
  json += boolJson(ptzQueue != nullptr);
  json += "}";
  return json;
}

// ===================================================
// AUDIO INITIALIZATION
// ===================================================

void initializeAudio() {
  Serial.println("[AUDIO] Initializing...");

  microphoneI2S.setPinsPdmRx(MIC_PDM_CLK, MIC_PDM_DATA);
  micReady = microphoneI2S.begin(I2S_MODE_PDM_RX, AUDIO_SAMPLE_RATE,
                                 I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);

  speakerI2S.setPins(SPK_I2S_BCLK, SPK_I2S_LRCLK, SPK_I2S_DATA);
  speakerReady = speakerI2S.begin(I2S_MODE_STD, AUDIO_SAMPLE_RATE,
                                  I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO);

  Serial.printf("[AUDIO] Mic=%s Speaker=%s\n",
                micReady ? "READY" : "FAILED", speakerReady ? "READY" : "FAILED");
}

// ===================================================
// SUPABASE HELPERS
// ===================================================

bool cloudConfigured() {
  if (!ENABLE_CLOUD) return false;
  if (String(CAMERA_DEVICE_KEY).startsWith("REPLACE_") || strlen(CAMERA_DEVICE_KEY) < 32) return false;
  if (strstr(PYROGUARD_CA_CERT, "REPLACE_WITH_") != nullptr) return false;
  return time(nullptr) > 1700000000;
}

bool sendHeartbeat() {
  if (!cloudConfigured()) return false;
  if (WiFi.status() != WL_CONNECTED) return false;

  WiFiClientSecure client;
  client.setCACert(PYROGUARD_CA_CERT);

  HTTPClient http;
  http.setTimeout(5000);
  if (!http.begin(client, edgeURL("heartbeat"))) return false;

  http.addHeader("Content-Type", "application/json");
  http.addHeader("x-device-key", CAMERA_DEVICE_KEY);

  String json = "{\"device_id\":\"";
  json += CAMERA_DEVICE_ID;
  json += "\",\"ip_address\":\"";
  json += WiFi.localIP().toString();
  json += "\",\"rssi\":";
  json += String(WiFi.RSSI());
  json += ",\"uptime_ms\":";
  json += String((unsigned long)millis());
  json += ",\"motion_detected\":";
  json += boolJson(motionDetected);
  json += "}";

  int status = http.POST(json);
  Serial.printf("[CLOUD] Heartbeat HTTP=%d\n", status);
  http.end();
  return status >= 200 && status < 300;
}

bool uploadPhotoToSupabase(const char* reason) {
  if (!cloudConfigured()) return false;
  if (!cameraEnabled || !cameraReady) return false;
  if (WiFi.status() != WL_CONNECTED) return false;

  camera_fb_t* frame = esp_camera_fb_get();
  if (!frame) return false;

  WiFiClientSecure client;
  client.setCACert(PYROGUARD_CA_CERT);

  HTTPClient http;
  http.setTimeout(15000);

  String url = edgeURL("photo");
  url += "&device_id=";
  url += CAMERA_DEVICE_ID;
  url += "&reason=";
  url += reason;

  if (!http.begin(client, url)) {
    esp_camera_fb_return(frame);
    return false;
  }

  http.addHeader("Content-Type", "image/jpeg");
  http.addHeader("x-device-key", CAMERA_DEVICE_KEY);

  int status = http.POST(frame->buf, frame->len);
  Serial.printf("[CLOUD] Photo (%s, %u bytes) HTTP=%d\n", reason, (unsigned)frame->len, status);
  if (status < 200 || status >= 300) Serial.printf("[CLOUD] Photo reply: %.160s\n", http.getString().c_str());

  http.end();
  esp_camera_fb_return(frame);
  return status >= 200 && status < 300;
}

// ===================================================
// CAMERA WEB PAGE (dashboard)
// NOTE: the page script uses only arrow functions on purpose.
// ===================================================

static const char PAGE[] PROGMEM = R"HTML(
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PyroGuard Camera 1</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#0b1220;color:#eef3fa;font-family:system-ui,Arial,sans-serif}
.wrap{max-width:1100px;margin:auto;padding:20px}
h1{margin:0 0 4px;font-size:24px;color:#fb923c}
h3{margin:0 0 12px}
.sub{color:#9aabc3;font-size:14px;margin-bottom:18px}
.card{background:#152135;border:1px solid #293a52;border-radius:15px;padding:18px;margin-bottom:18px}
.viewer{position:relative;background:#05080d;border-radius:12px;overflow:hidden;min-height:240px}
#stream{display:block;width:100%;height:auto}
#placeholder{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#8294ae;text-align:center;padding:20px}
.badge{position:absolute;top:12px;padding:6px 11px;border-radius:16px;background:#364358;color:#fff;font-size:12px;z-index:3}
#liveBadge{left:12px}
#motionBadge{right:12px}
#marker{position:absolute;width:60px;height:60px;margin:-30px 0 0 -30px;border:3px solid #ef4444;border-radius:50%;
  box-shadow:0 0 14px #ef4444;display:none;z-index:2;pointer-events:none;transition:left .25s,top .25s}
.row{display:flex;flex-wrap:wrap;gap:10px;margin-top:12px;align-items:center}
button{border:0;border-radius:9px;padding:11px 16px;background:#c2410c;color:#fff;font-size:14px;cursor:pointer}
button:hover{opacity:.85}
button:disabled{opacity:.45;cursor:not-allowed}
button.alt{background:#475569}
button.blue{background:#2563eb}
button.on{background:#16a34a}
.pad{display:grid;grid-template-columns:repeat(3,70px);gap:8px}
.pad button{padding:14px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
label{display:flex;flex-direction:column;gap:6px;color:#c5d0e0;font-size:14px}
input[type=range]{width:100%}
select,input[type=file]{background:#0b1525;color:#fff;border:1px solid #475569;border-radius:8px;padding:8px}
.info{color:#a8b8ce;font-size:13px;line-height:1.8}
.note{color:#8294ae;font-size:12px;margin-top:8px}
audio{width:100%;margin-top:10px}
#msg{position:sticky;bottom:0;background:#0b1220;color:#facc15;min-height:24px;padding:8px 0;font-size:14px}
</style>
</head>
<body>
<div class="wrap">
<h1>PyroGuard Camera 1</h1>
<div class="sub">DFR1154 · Live Video · Motion Detection · Pan/Tilt via ESP32-001 · Audio</div>

<div class="card">
  <div class="viewer" id="viewer">
    <div id="liveBadge" class="badge">CONNECTING</div>
    <div id="motionBadge" class="badge">MOTION …</div>
    <div id="marker"></div>
    <div id="placeholder">Starting live view…</div>
    <img id="stream" alt="Camera 1 live stream">
  </div>
  <div class="row">
    <button id="startBtn" onclick="startLive()" disabled>Start Live</button>
    <button id="stopBtn" class="alt" onclick="stopLive(true)">Stop Live</button>
    <button class="blue" onclick="capturePhoto()">Capture Photo</button>
    <button class="blue" onclick="savePhoto()">Save to Cloud</button>
    <button class="alt" onclick="fullScreen()">Fullscreen</button>
    <button id="irBtn" class="alt" onclick="toggleIr()">IR: OFF</button>
    <button id="camBtn" class="on" onclick="toggleCamera()">Camera: ON</button>
  </div>
</div>

<div class="card">
  <h3>Motion Detection</h3>
  <div class="row" style="margin-top:0">
    <button id="motionBtn" class="on" onclick="toggleMotion()">Motion: ON</button>
  </div>
  <div id="motionInfo" class="info" style="margin-top:10px">Loading…</div>
</div>

<div class="card">
  <h3>Pan / Tilt (servos on ESP32-001)</h3>
  <div class="grid">
    <div class="pad">
      <span></span><button onclick="ptz('up')">▲</button><span></span>
      <button onclick="ptz('left')">◀</button><button class="alt" onclick="ptz('center')">●</button><button onclick="ptz('right')">▶</button>
      <span></span><button onclick="ptz('down')">▼</button><button class="alt" onclick="ptz('stop')">Stop</button>
    </div>
    <div>
      <button id="autoBtn" class="alt" onclick="toggleAuto()">Auto-follow: OFF</button>
      <div id="ptzInfo" class="info" style="margin-top:10px">Checking ESP32-001 link…</div>
      <div class="note">Manual buttons pause auto-follow for a while; it resumes by itself.</div>
    </div>
  </div>
</div>

<div class="card">
  <h3>Image</h3>
  <div class="grid">
    <label>Brightness <input type="range" id="bright" min="-2" max="2" value="0" onchange="setCamera('bright',this.value)"></label>
    <label>Contrast <input type="range" id="contrast" min="-2" max="2" value="0" onchange="setCamera('contrast',this.value)"></label>
    <label>Saturation <input type="range" id="sat" min="-2" max="2" value="0" onchange="setCamera('sat',this.value)"></label>
    <label>Sharpness <input type="range" id="sharp" min="-3" max="3" value="2" onchange="setCamera('sharp',this.value)"></label>
    <label>Denoise <input type="range" id="denoise" min="0" max="8" value="1" onchange="setCamera('denoise',this.value)"></label>
  </div>
  <div class="note">Video is fixed at VGA 640×480, JPEG quality 10 for a stable stream.</div>
</div>

<div class="card">
  <h3>Audio</h3>
  <div class="grid">
    <div>
      <div class="info">Camera microphone</div>
      <div class="row">
        <select id="listenSec"><option value="2">2 s</option><option value="3" selected>3 s</option><option value="5">5 s</option></select>
        <button id="listenBtn" class="blue" onclick="listen()">Listen</button>
        <button id="micBtn" class="alt" onclick="toggleMic()">Mic: OFF</button>
      </div>
      <audio id="player" controls></audio>
    </div>
    <div>
      <div class="info">Camera speaker</div>
      <div class="row">
        <button class="blue" onclick="testTone()">Test Tone</button>
        <button id="spkBtn" class="alt" onclick="toggleSpeaker()">Speaker: OFF</button>
      </div>
      <div class="row">
        <input type="file" id="wavFile" accept=".wav,audio/wav">
        <button onclick="playFile()">Play WAV</button>
      </div>
      <div class="note">WAV: 16 kHz, 16-bit, mono, max 120 KB (about 3.5 s).</div>
    </div>
  </div>
</div>

<div class="card">
  <h3>Hardware Status</h3>
  <div id="statusInfo" class="info">Checking camera…</div>
</div>

<div id="msg"></div>
</div>

<script>
const $ = id => document.getElementById(id);
const host = location.hostname;
const img = $("stream");

let liveOn = false, userStopped = false, retryT = null, liveT = null, wasDown = false;
let irOn = false, camOn = true, motionOn = true, autoOn = false, micOn = false, spkOn = false;
let slidersSynced = false;

const say = t => { $("msg").textContent = t; };
const setBadge = (id, t, c) => { const b = $(id); b.textContent = t; b.style.background = c; };
const setToggle = (id, label, on) => { const b = $(id); b.textContent = label + ": " + (on ? "ON" : "OFF"); b.className = on ? "on" : "alt"; };
const streamURL = () => "http://" + host + ":81/stream?t=" + Date.now();

const api = async (path, method) => {
  const r = await fetch(path, { method: method || "GET", cache: "no-store" });
  const text = await r.text();
  if (!r.ok) throw new Error(text || ("HTTP " + r.status));
  return text;
};

// ---------- LIVE VIDEO (auto start + auto reconnect) ----------
const startLive = () => {
  clearTimeout(retryT);
  userStopped = false;
  liveOn = true;
  $("placeholder").textContent = "Connecting to camera…";
  $("placeholder").style.display = "flex";
  setBadge("liveBadge", "CONNECTING", "#475569");
  $("startBtn").disabled = true;
  $("stopBtn").disabled = false;
  img.src = streamURL();
  clearInterval(liveT);
  liveT = setInterval(() => {
    if (liveOn && img.naturalWidth > 0) {
      setBadge("liveBadge", "● LIVE", "#166534");
      $("placeholder").style.display = "none";
      clearInterval(liveT);
    }
  }, 300);
};

const stopLive = (byUser) => {
  if (byUser) userStopped = true;
  liveOn = false;
  clearInterval(liveT);
  clearTimeout(retryT);
  img.removeAttribute("src");
  $("marker").style.display = "none";
  $("placeholder").style.display = "flex";
  $("placeholder").textContent = byUser ? "Live stopped. Click Start Live to resume." : "Reconnecting…";
  setBadge("liveBadge", byUser ? "STOPPED" : "RECONNECTING", byUser ? "#475569" : "#b45309");
  $("startBtn").disabled = !byUser;
  $("stopBtn").disabled = byUser;
};

const scheduleReconnect = () => {
  if (userStopped) return;
  stopLive(false);
  retryT = setTimeout(startLive, 3000);
};

img.onerror = () => { if (liveOn) scheduleReconnect(); };
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !userStopped) startLive();
});

const fullScreen = () => { $("viewer").requestFullscreen?.(); };

const capturePhoto = async () => {
  try {
    const r = await fetch("/capture?t=" + Date.now(), { cache: "no-store" });
    if (!r.ok) throw new Error(await r.text());
    const blob = await r.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "PyroGuard_Cam1_" + Date.now() + ".jpg";
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
    say("Photo saved");
  } catch (e) { say("Capture failed: " + e.message); }
};

const savePhoto = async () => {
  try { await api("/save?reason=manual", "POST"); say("Photo queued for upload to PyroGuard cloud"); }
  catch (e) { say("Cloud save failed: " + e.message); }
};

// ---------- CAMERA / IR / MOTION ----------
const setCamera = async (name, value) => {
  try { await api("/set?var=" + encodeURIComponent(name) + "&val=" + encodeURIComponent(value)); say("Updated " + name + " = " + value); }
  catch (e) { say("Setting failed: " + e.message); }
};

const toggleIr = async () => {
  await setCamera("ir", irOn ? 0 : 1);
  irOn = !irOn;
  setToggle("irBtn", "IR", irOn);
};

const toggleCamera = async () => {
  try {
    await api(camOn ? "/api/camera/off" : "/api/camera/on", "POST");
    camOn = !camOn;
    setToggle("camBtn", "Camera", camOn);
    if (camOn) startLive(); else stopLive(true);
    say(camOn ? "Camera turned on" : "Camera turned off");
  } catch (e) { say(e.message); }
};

const toggleMotion = async () => {
  try {
    await api(motionOn ? "/api/motion/off" : "/api/motion/on", "POST");
    motionOn = !motionOn;
    setToggle("motionBtn", "Motion", motionOn);
    pollMotion();
  } catch (e) { say("Motion: " + e.message); }
};

const area = (x, y) => {
  const h = x < 0.33 ? "left" : (x < 0.66 ? "center" : "right");
  const v = y < 0.33 ? "top" : (y < 0.66 ? "middle" : "bottom");
  return v + " " + h;
};

const pollMotion = async () => {
  try {
    const m = JSON.parse(await api("/motion"));
    const mk = $("marker");
    motionOn = !!m.motion_enabled;
    setToggle("motionBtn", "Motion", motionOn);
    if (!m.motion_ready || !m.motion_enabled) {
      setBadge("motionBadge", m.motion_ready ? "MOTION OFF" : "MOTION UNAVAILABLE", "#364358");
      mk.style.display = "none";
    } else if (m.ptz_settling) {
      setBadge("motionBadge", "CAMERA MOVING", "#b45309");
      mk.style.display = "none";
    } else if (m.motion_detected) {
      setBadge("motionBadge", "⚠ MOTION · " + area(m.motion_x, m.motion_y), "#b91c1c");
      mk.style.left = (m.motion_x * 100) + "%";
      mk.style.top = (m.motion_y * 100) + "%";
      mk.style.display = (liveOn && img.naturalWidth) ? "block" : "none";
    } else {
      setBadge("motionBadge", "WATCHING", "#1e3a5f");
      mk.style.display = "none";
    }
    $("motionInfo").textContent =
      "Detections since boot: " + m.detection_count +
      " | Activity: " + (m.motion_score * 100).toFixed(1) + "%" +
      " | Position: x " + Number(m.motion_x).toFixed(2) + ", y " + Number(m.motion_y).toFixed(2) +
      " (" + area(m.motion_x, m.motion_y) + ")" +
      " | Analyses: " + m.analysis_count + " | Grid: " + m.analysis_grid;
  } catch (e) {}
};

// ---------- PTZ ----------
const ptz = async (action) => {
  try {
    const r = await fetch("/ptz?action=" + action, { method: "POST" });
    const j = await r.json();
    const c = j.controller || {};
    if (j.delivered) say("PTZ " + action + " → pan " + c.target_pan + "° / tilt " + c.target_tilt + "°");
    else if (j.queued) say("PTZ " + action + " sent, waiting for ESP32-001…");
    else say("PTZ not delivered: " + (j.error || ("controller HTTP " + j.controller_http)));
    pollStatus();
  } catch (e) { say("PTZ failed: " + e.message); }
};

const toggleAuto = () => ptz(autoOn ? "auto_off" : "auto_on");

// ---------- AUDIO ----------
const toggleMic = async () => {
  try { await api(micOn ? "/api/mic/off" : "/api/mic/on", "POST"); micOn = !micOn; setToggle("micBtn", "Mic", micOn); }
  catch (e) { say("Mic: " + e.message); }
};

const toggleSpeaker = async () => {
  try { await api(spkOn ? "/api/speaker/off" : "/api/speaker/on", "POST"); spkOn = !spkOn; setToggle("spkBtn", "Speaker", spkOn); }
  catch (e) { say("Speaker: " + e.message); }
};

const listen = async () => {
  const sec = $("listenSec").value;
  $("listenBtn").disabled = true;
  say("Recording " + sec + " s from the camera microphone…");
  try {
    if (!micOn) { await api("/api/mic/on", "POST"); micOn = true; setToggle("micBtn", "Mic", true); }
    const r = await fetch("/audio/record?sec=" + sec, { cache: "no-store" });
    if (!r.ok) throw new Error(await r.text());
    const blob = await r.blob();
    const p = $("player");
    p.src = URL.createObjectURL(blob);
    p.play().catch(() => {});
    say("Recording ready, playing in the browser");
  } catch (e) { say("Listen failed: " + e.message); }
  $("listenBtn").disabled = false;
};

const sendToSpeaker = async (blob, label) => {
  try {
    if (!spkOn) { await api("/api/speaker/on", "POST"); spkOn = true; setToggle("spkBtn", "Speaker", true); }
    const r = await fetch("/audio/play", { method: "POST", body: blob, headers: { "Content-Type": "audio/wav" } });
    const text = await r.text();
    say(r.ok ? (label + " played on the camera speaker") : ("Speaker: " + text));
  } catch (e) { say("Speaker failed: " + e.message); }
};

const makeTone = () => {
  const rate = 16000, n = 9600;  // 0.6 s at 1 kHz
  const buf = new ArrayBuffer(44 + n * 2);
  const v = new DataView(buf);
  const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  w(0, "RIFF"); v.setUint32(4, 36 + n * 2, true); w(8, "WAVE"); w(12, "fmt ");
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, rate, true); v.setUint32(28, rate * 2, true);
  v.setUint16(32, 2, true); v.setUint16(34, 16, true);
  w(36, "data"); v.setUint32(40, n * 2, true);
  for (let i = 0; i < n; i++) v.setInt16(44 + i * 2, Math.round(Math.sin(2 * Math.PI * 1000 * i / rate) * 9000), true);
  return new Blob([buf], { type: "audio/wav" });
};

const testTone = () => sendToSpeaker(makeTone(), "Test tone");

const playFile = () => {
  const f = $("wavFile").files[0];
  if (!f) { say("Choose a WAV file first"); return; }
  if (f.size > 120000) { say("File too large: max 120 KB (about 3.5 s of 16 kHz mono)"); return; }
  sendToSpeaker(f, f.name);
};

// ---------- STATUS ----------
const pollStatus = async () => {
  try {
    const s = JSON.parse(await api("/status"));
    const c = s.ptz_controller || {};

    irOn = !!s.ir_enabled;       setToggle("irBtn", "IR", irOn);
    camOn = !!s.camera_enabled;  setToggle("camBtn", "Camera", camOn);
    micOn = !!s.mic_enabled;     setToggle("micBtn", "Mic", micOn);
    spkOn = !!s.speaker_enabled; setToggle("spkBtn", "Speaker", spkOn);
    autoOn = !!c.auto_follow;
    $("autoBtn").textContent = "Auto-follow: " + (autoOn ? (c.auto_paused ? "PAUSED" : "ON") : "OFF");
    $("autoBtn").className = autoOn ? "on" : "alt";

    $("ptzInfo").textContent = c.linked
      ? ("ESP32-001 linked at " + c.ip + " | Mode: " + c.mode +
         " | Pan " + c.pan + "° / Tilt " + c.tilt + "°" + (c.moving ? " (moving)" : "") +
         " | Relayed OK: " + c.relay_ok + ", failed: " + c.relay_failed)
      : "ESP32-001 not linked yet. It links automatically once it is powered and on the same Wi-Fi.";

    if (!slidersSynced) {
      if (s.brightness !== undefined) $("bright").value = s.brightness;
      if (s.contrast !== undefined) $("contrast").value = s.contrast;
      if (s.saturation !== undefined) $("sat").value = s.saturation;
      if (s.sharpness !== null && s.sharpness !== undefined) $("sharp").value = s.sharpness;
      if (s.denoise !== undefined) $("denoise").value = s.denoise;
      slidersSynced = true;
    }

    $("statusInfo").textContent =
      "Device: " + s.device_id + " | IP: " + s.ip_address +
      " | Wi-Fi: " + (s.wifi_connected ? "Connected" : "Disconnected") + " (" + s.rssi + " dBm)" +
      " | Camera: " + (s.camera_connected ? "OK" : "NOT DETECTED") +
      " | Mic: " + (s.mic_ready ? "ready" : "failed") +
      " | Speaker: " + (s.speaker_ready ? "ready" : "failed") +
      " | IR: " + (s.ir_enabled ? "on" : "off") +
      " | Free heap: " + s.free_heap + " | PSRAM free: " + s.free_psram +
      " | Uptime: " + Math.floor(s.uptime_ms / 60000) + " min";

    if (wasDown && !userStopped) startLive();
    wasDown = false;
  } catch (e) {
    wasDown = true;
    $("statusInfo").textContent = "Camera not reachable, retrying…";
  }
};

window.addEventListener("load", () => {
  startLive();
  pollMotion();
  pollStatus();
});
setInterval(pollMotion, 700);
setInterval(pollStatus, 3000);
</script>
</body>
</html>
)HTML";

// ===================================================
// HTTP: PAGE
// ===================================================

static esp_err_t pageHandler(httpd_req_t* req) {
  addHeaders(req);
  httpd_resp_set_type(req, "text/html; charset=utf-8");
  return httpd_resp_send(req, PAGE, HTTPD_RESP_USE_STRLEN);
}

// ===================================================
// HTTP: MOTION
// ===================================================

static esp_err_t motionHandler(httpd_req_t* req) {
  addHeaders(req);
  httpd_resp_set_type(req, "application/json");
  String json = motionJson();
  return httpd_resp_send(req, json.c_str(), HTTPD_RESP_USE_STRLEN);
}

// ===================================================
// HTTP: ESP32-001 LINK (key-protected)
// ===================================================

static esp_err_t sendJson(httpd_req_t* req, const char* status, const String& body) {
  if (status) httpd_resp_set_status(req, status);
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_send(req, body.c_str(), HTTPD_RESP_USE_STRLEN);
}

static esp_err_t linkHandler(httpd_req_t* req) {
  addHeaders(req);

  char key[96] = {};
  if (httpd_req_get_hdr_value_str(req, "X-Device-Key", key, sizeof(key)) != ESP_OK ||
      !keyMatches(key)) {
    return sendJson(req, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
  }

  char query[200] = {};
  char controller[24] = {};
  char ipText[20] = {};
  IPAddress reported;

  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "controller", controller, sizeof(controller)) != ESP_OK ||
      strcmp(controller, CONTROLLER_DEVICE_ID) != 0 ||
      httpd_query_key_value(query, "ip", ipText, sizeof(ipText)) != ESP_OK ||
      !reported.fromString(ipText) || (uint32_t)reported == 0) {
    return sendJson(req, "400 Bad Request", "{\"error\":\"invalid_link\"}");
  }

  const int pan = queryInt(query, "pan", -1);
  const int tilt = queryInt(query, "tilt", -1);
  const int targetPan = queryInt(query, "target_pan", -1);
  const int targetTilt = queryInt(query, "target_tilt", -1);
  const bool moving = queryInt(query, "moving", 0) == 1;
  const bool autoFollow = queryInt(query, "auto", 0) == 1;
  const bool autoPaused = queryInt(query, "paused", 0) == 1;
  const uint32_t ip = (uint32_t)reported;
  const unsigned long now = millis();

  uint32_t previousIp;
  portENTER_CRITICAL(&controllerMux);
  previousIp = controllerIp;
  controllerIp = ip;
  controllerLastSeen = now;
  if (pan >= 0 && pan <= 180) controllerPan = pan;
  if (tilt >= 0 && tilt <= 180) controllerTilt = tilt;
  if (targetPan >= 0 && targetPan <= 180) controllerTargetPan = targetPan;
  if (targetTilt >= 0 && targetTilt <= 180) controllerTargetTilt = targetTilt;
  controllerMoving = moving;
  controllerAutoFollow = autoFollow;
  controllerAutoPaused = autoPaused;
  controllerLinkCount++;
  portEXIT_CRITICAL(&controllerMux);

  if (moving) ptzSettleUntil = now + PTZ_MOTION_SETTLE_MS;

  if (previousIp != ip) {
    Serial.printf("[LINK] %s linked at %s (manual PTZ relay ready)\n", CONTROLLER_DEVICE_ID, ipText);
  }

  return sendJson(req, nullptr, motionJson());
}

// ===================================================
// HTTP: MANUAL PTZ (Flutter / web page -> Camera 1 -> ESP32-001)
// ===================================================

static esp_err_t ptzHandler(httpd_req_t* req) {
  addHeaders(req);

  char query[64] = {};
  char action[12] = {};

  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "action", action, sizeof(action)) != ESP_OK) {
    return sendJson(req, "400 Bad Request", "{\"ok\":false,\"error\":\"action_required\"}");
  }

  for (char* c = action; *c; ++c) *c = (char)tolower((unsigned char)*c);

  if (!strcmp(action, "auto")) strcpy(action, "auto_on");
  if (!strcmp(action, "manual")) strcpy(action, "auto_off");

  static const char* allowed[] = {
    "left", "right", "up", "down", "center", "home", "stop", "auto_on", "auto_off"
  };
  bool valid = false;
  for (const char* a : allowed) {
    if (!strcmp(action, a)) { valid = true; break; }
  }
  if (!valid) {
    return sendJson(req, "400 Bad Request", "{\"ok\":false,\"error\":\"invalid_action\"}");
  }

  const int step = queryInt(query, "step", 0);
  if (step != 0 && (step < 1 || step > 30)) {
    return sendJson(req, "400 Bad Request", "{\"ok\":false,\"error\":\"invalid_step\"}");
  }

  if (!ptzQueue) {
    return sendJson(req, "503 Service Unavailable", "{\"ok\":false,\"error\":\"ptz_relay_unavailable\"}");
  }

  if (currentControllerIp() == 0) {
    String body = "{\"ok\":false,\"error\":\"controller_not_linked\",\"controller\":";
    body += controllerJson();
    body += "}";
    return sendJson(req, "503 Service Unavailable", body);
  }

  PtzRelayJob job = {};
  job.seq = ptzNextSeq++;
  strncpy(job.action, action, sizeof(job.action) - 1);
  job.step = step;

  if (xQueueSend(ptzQueue, &job, 0) != pdTRUE) {
    return sendJson(req, "429 Too Many Requests", "{\"ok\":false,\"error\":\"ptz_busy\"}");
  }

  const unsigned long started = millis();
  while (ptzDoneSeq != job.seq && millis() - started < PTZ_RELAY_WAIT_MS) {
    vTaskDelay(pdMS_TO_TICKS(10));
  }

  const bool finished = ptzDoneSeq == job.seq;
  const int httpStatus = finished ? ptzDoneHttp : 0;
  const bool delivered = finished && httpStatus == 200;

  String body = "{\"ok\":";
  body += boolJson(delivered || !finished);
  body += ",\"delivered\":";
  body += boolJson(delivered);
  body += ",\"queued\":";
  body += boolJson(!finished);
  body += ",\"action\":\"";
  body += action;
  body += "\",\"controller_http\":";
  body += String(httpStatus);
  body += ",\"controller\":";
  body += controllerJson();
  body += "}";

  if (delivered) return sendJson(req, nullptr, body);
  if (!finished) return sendJson(req, "202 Accepted", body);
  return sendJson(req, "502 Bad Gateway", body);
}

// ===================================================
// HTTP: STATUS
// ===================================================

static esp_err_t statusHandler(httpd_req_t* req) {
  addHeaders(req);
  httpd_resp_set_type(req, "application/json");

  const bool wifiOk = WiFi.status() == WL_CONNECTED;

  String json = "{";
  json += "\"device_id\":\"";
  json += CAMERA_DEVICE_ID;
  json += "\",\"camera_connected\":";
  json += boolJson(cameraReady);
  json += ",\"camera_enabled\":";
  json += boolJson(cameraEnabled);
  json += ",\"wifi_connected\":";
  json += boolJson(wifiOk);
  json += ",\"ip_address\":\"";
  json += WiFi.localIP().toString();
  json += "\",\"rssi\":";
  json += String(wifiOk ? WiFi.RSSI() : 0);
  json += ",\"mic_ready\":";
  json += boolJson(micReady);
  json += ",\"speaker_ready\":";
  json += boolJson(speakerReady);
  json += ",\"mic_enabled\":";
  json += boolJson(micEnabled);
  json += ",\"speaker_enabled\":";
  json += boolJson(speakerEnabled);
  json += ",\"ir_enabled\":";
  json += boolJson(irEnabled);
  json += ",\"motion_enabled\":";
  json += boolJson(motionEnabled);
  json += ",\"motion_detected\":";
  json += boolJson(motionDetected);
  json += ",\"frame_size\":";
  json += String(currentFrameSizeIndex);
  {
    sensor_t* s = esp_camera_sensor_get();
    json += ",\"jpeg_quality\":";
    json += s ? String(s->status.quality) : String("null");
    json += ",\"sharpness\":";
    json += s ? String(s->status.sharpness) : String("null");
    json += ",\"denoise\":";
    json += s ? String(s->status.denoise) : String("null");
    json += ",\"brightness\":";
    json += s ? String(s->status.brightness) : String("null");
    json += ",\"contrast\":";
    json += s ? String(s->status.contrast) : String("null");
    json += ",\"saturation\":";
    json += s ? String(s->status.saturation) : String("null");
  }
  json += ",\"free_heap\":";
  json += String((unsigned)ESP.getFreeHeap());
  json += ",\"free_psram\":";
  json += String((unsigned)ESP.getFreePsram());
  json += ",\"stream_port\":81";
  json += ",\"stream_path\":\"/stream\"";
  json += ",\"capture_path\":\"/capture\"";
  json += ",\"motion_path\":\"/motion\"";
  json += ",\"coverage\":[\"Entrance\",\"Sala\"]";
  json += ",\"ptz_mode\":\"system_auto_follow_with_manual_override\"";
  json += ",\"ptz_path\":\"/ptz\"";
  json += ",\"cloud_enabled\":";
  json += boolJson(cloudConfigured());
  json += ",\"cloud_photos_ok\":";
  json += String(cloudPhotoOk);
  json += ",\"cloud_photos_failed\":";
  json += String(cloudPhotoFailed);
  json += ",\"ptz_controller\":";
  json += controllerJson();
  json += ",\"uptime_ms\":";
  json += String(millis());
  json += "}";

  return httpd_resp_send(req, json.c_str(), HTTPD_RESP_USE_STRLEN);
}

// ===================================================
// HTTP: CAPTURE
// ===================================================

static esp_err_t captureHandler(httpd_req_t* req) {
  Serial.println("[CAPTURE] HTTP request received");
  addHeaders(req);

  if (!cameraEnabled || !cameraReady) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Camera unavailable");
  }

  camera_fb_t* frame = esp_camera_fb_get();
  if (!frame) {
    Serial.println("[CAPTURE] esp_camera_fb_get() returned null");
    return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Capture failed");
  }

  if (frame->format != PIXFORMAT_JPEG || frame->len < 4 ||
      frame->buf[0] != 0xFF || frame->buf[1] != 0xD8) {
    Serial.printf("[CAPTURE] Invalid JPEG format=%d bytes=%u\n", (int)frame->format, (unsigned)frame->len);
    esp_camera_fb_return(frame);
    return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Camera returned invalid JPEG");
  }

  queueMotionFrame(frame);

  httpd_resp_set_type(req, "image/jpeg");
  esp_err_t result = httpd_resp_send(req, (const char*)frame->buf, frame->len);
  esp_camera_fb_return(frame);

  Serial.printf("[CAPTURE] JPEG response result=%d\n", (int)result);
  return result;
}

// ===================================================
// HTTP: SAVE PHOTO
// ===================================================

static esp_err_t saveHandler(httpd_req_t* req) {
  addHeaders(req);

  if (!ENABLE_CLOUD) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Cloud upload disabled");
  }

  // ?reason=manual|fire|intrusion|motion (ESP32-001 sends fire/intrusion).
  int reason = 1;
  char query[48] = {};
  char value[16] = {};
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK &&
      httpd_query_key_value(query, "reason", value, sizeof(value)) == ESP_OK) {
    if (!strcmp(value, "fire")) reason = 3;
    else if (!strcmp(value, "intrusion")) reason = 4;
    else if (!strcmp(value, "motion")) reason = 2;
  }
  if (!cloudConfigured()) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Cloud not ready (Wi-Fi/NTP time/key)");
  }
  if (reason >= pendingPhotoReason) pendingPhotoReason = reason;   // fire/intrusion win
  httpd_resp_set_status(req, "202 Accepted");
  httpd_resp_set_type(req, "application/json");
  return httpd_resp_sendstr(req, "{\"ok\":true,\"queued\":true}");
}

// ===================================================
// HTTP: CAMERA/MOTION SWITCHES
// ===================================================

static esp_err_t cameraOnHandler(httpd_req_t* req) {
  addHeaders(req);
  cameraEnabled = true;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"camera_enabled\":true}");
}

static esp_err_t cameraOffHandler(httpd_req_t* req) {
  addHeaders(req);
  cameraEnabled = false;
  motionDetected = false;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"camera_enabled\":false}");
}

static esp_err_t motionOnHandler(httpd_req_t* req) {
  addHeaders(req);

  if (!motionReady) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Motion detector unavailable");
  }

  if (motionMutex && xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
    motionEnabled = true;
    motionBackgroundReady = false;
    motionDetected = false;
    motionCandidate = false;
    motionPositiveCount = 0;
    xSemaphoreGive(motionMutex);
  }

  return httpd_resp_sendstr(req, "{\"ok\":true,\"motion_enabled\":true}");
}

static esp_err_t motionOffHandler(httpd_req_t* req) {
  addHeaders(req);

  if (motionMutex && xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
    motionEnabled = false;
    motionDetected = false;
    motionCandidate = false;
    motionPositiveCount = 0;
    xSemaphoreGive(motionMutex);
  }

  return httpd_resp_sendstr(req, "{\"ok\":true,\"motion_enabled\":false}");
}

// ===================================================
// HTTP: CAMERA SETTINGS
// ===================================================

static esp_err_t settingsHandler(httpd_req_t* req) {
  addHeaders(req);

  char query[96] = {};
  char name[24] = {};
  char valueText[16] = {};

  if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
      httpd_query_key_value(query, "var", name, sizeof(name)) != ESP_OK ||
      httpd_query_key_value(query, "val", valueText, sizeof(valueText)) != ESP_OK) {
    return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid setting parameters");
  }

  int value = atoi(valueText);
  int result = 0;
  bool valid = true;

  sensor_t* sensor = esp_camera_sensor_get();
  if (!sensor && strcmp(name, "ir") != 0) {
    return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Camera unavailable");
  }

  if (LOCK_VIDEO_QUALITY && (!strcmp(name, "quality") || !strcmp(name, "size"))) {
    return httpd_resp_send_err(req, HTTPD_403_FORBIDDEN,
                               "Video quality is fixed (VGA 640x480, JPEG quality 10)");
  }

  if (!strcmp(name, "quality")) {
    if (value < 10 || value > 30) valid = false;
    else result = sensor->set_quality(sensor, value);

  } else if (!strcmp(name, "bright")) {
    if (value < -2 || value > 2) valid = false;
    else result = sensor->set_brightness(sensor, value);

  } else if (!strcmp(name, "contrast")) {
    if (value < -2 || value > 2) valid = false;
    else result = sensor->set_contrast(sensor, value);

  } else if (!strcmp(name, "sat")) {
    if (value < -2 || value > 2) valid = false;
    else result = sensor->set_saturation(sensor, value);

  } else if (!strcmp(name, "sharp")) {
    if (value < -3 || value > 3 || !sensor->set_sharpness) valid = false;
    else result = sensor->set_sharpness(sensor, value);

  } else if (!strcmp(name, "denoise")) {
    if (value < 0 || value > 8 || !sensor->set_denoise) valid = false;
    else result = sensor->set_denoise(sensor, value);

  } else if (!strcmp(name, "ir")) {
    if (value != 0 && value != 1) {
      valid = false;
    } else {
      irEnabled = value == 1;
      digitalWrite(IR_LED_PIN, irEnabled ? HIGH : LOW);
    }

  } else if (!strcmp(name, "size")) {
    framesize_t sizes[] = { FRAMESIZE_QVGA, FRAMESIZE_VGA, FRAMESIZE_SVGA, FRAMESIZE_HD };
    if (value < 0 || value > 3) {
      valid = false;
    } else {
      result = sensor->set_framesize(sensor, sizes[value]);
      if (result == 0 && motionMutex && xSemaphoreTake(motionMutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        currentFrameSizeIndex = value;
        motionBackgroundReady = false;
        motionDetected = false;
        motionCandidate = false;
        motionPositiveCount = 0;
        xSemaphoreGive(motionMutex);
      }
    }

  } else {
    valid = false;
  }

  if (!valid || result != 0) {
    return httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid camera setting");
  }

  return httpd_resp_sendstr(req, "OK");
}

// ===================================================
// HTTP: MJPEG STREAM
// ===================================================

static esp_err_t streamHandler(httpd_req_t* req) {
  Serial.println("[STREAM] Client connected");
  addHeaders(req);

  if (!cameraEnabled || !cameraReady) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Camera unavailable");
  }

  esp_err_t result = httpd_resp_set_type(req, "multipart/x-mixed-replace;boundary=frame");
  if (result != ESP_OK) return result;

  // TCP_NODELAY: send each frame immediately (avoids ~200 ms stutter).
  const int socketFd = httpd_req_to_sockfd(req);
  if (socketFd >= 0) {
    int noDelay = 1;
    setsockopt(socketFd, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay));
  }

  unsigned long sentFrames = 0;
  unsigned long lastFrameSent = 0;
  int captureFailures = 0;

  while (cameraEnabled && WiFi.status() == WL_CONNECTED) {
    const unsigned long sinceLast = millis() - lastFrameSent;
    if (lastFrameSent != 0 && sinceLast < STREAM_MIN_FRAME_INTERVAL_MS) {
      vTaskDelay(pdMS_TO_TICKS(STREAM_MIN_FRAME_INTERVAL_MS - sinceLast));
    }

    camera_fb_t* frame = esp_camera_fb_get();

    if (!frame) {
      if (++captureFailures >= STREAM_CAPTURE_RETRIES) {
        Serial.println("[STREAM] Frame capture failed repeatedly");
        result = ESP_FAIL;
        break;
      }
      vTaskDelay(pdMS_TO_TICKS(30));
      continue;
    }

    if (frame->format != PIXFORMAT_JPEG || frame->len < 4 ||
        frame->buf[0] != 0xFF || frame->buf[1] != 0xD8) {
      Serial.printf("[STREAM] Invalid JPEG format=%d bytes=%u (skipped)\n",
                    (int)frame->format, (unsigned)frame->len);
      esp_camera_fb_return(frame);
      if (++captureFailures >= STREAM_CAPTURE_RETRIES) {
        result = ESP_FAIL;
        break;
      }
      continue;
    }

    captureFailures = 0;
    lastStreamFrameMs = millis();
    lastFrameSent = lastStreamFrameMs;

    queueMotionFrame(frame);

    char header[128];
    int headerLength = snprintf(header, sizeof(header),
      "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n",
      (unsigned int)frame->len);

    result = httpd_resp_send_chunk(req, header, headerLength);
    if (result == ESP_OK) result = httpd_resp_send_chunk(req, (const char*)frame->buf, frame->len);
    if (result == ESP_OK) result = httpd_resp_send_chunk(req, "\r\n", 2);

    esp_camera_fb_return(frame);

    if (result != ESP_OK) {
      Serial.printf("[STREAM] Client closed/send failed err=%d after %lu frames\n", (int)result, sentFrames);
      break;
    }

    ++sentFrames;
    if (sentFrames == 1 || sentFrames % 300 == 0) {
      Serial.printf("[STREAM] Delivered %lu JPEG frames\n", sentFrames);
    }
  }

  return result;
}

// ===================================================
// AUDIO ENDPOINTS
// ===================================================

static esp_err_t micOnHandler(httpd_req_t* req) {
  addHeaders(req);
  if (!micReady) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Mic unavailable");
  }
  micEnabled = true;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"mic_enabled\":true}");
}

static esp_err_t micOffHandler(httpd_req_t* req) {
  addHeaders(req);
  micEnabled = false;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"mic_enabled\":false}");
}

static esp_err_t speakerOnHandler(httpd_req_t* req) {
  addHeaders(req);
  if (!speakerReady) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Speaker unavailable");
  }
  speakerEnabled = true;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"speaker_enabled\":true}");
}

static esp_err_t speakerOffHandler(httpd_req_t* req) {
  addHeaders(req);
  speakerEnabled = false;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"speaker_enabled\":false}");
}

static esp_err_t recordAudioHandler(httpd_req_t* req) {
  addHeaders(req);

  if (!micReady || !micEnabled) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Microphone disabled");
  }

  if (audioBusy) {
    httpd_resp_set_status(req, "409 Conflict");
    return httpd_resp_sendstr(req, "Audio busy");
  }

  // Optional ?sec=1..5 (default 1)
  int seconds = 1;
  char query[32] = {};
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
    seconds = queryInt(query, "sec", 1);
  }
  seconds = constrain(seconds, 1, MAX_RECORD_SECONDS);

  audioBusy = true;
  size_t wavSize = 0;
  uint8_t* wav = microphoneI2S.recordWAV(seconds, &wavSize);

  if (!wav || wavSize < 44) {
    if (wav) free(wav);
    audioBusy = false;
    return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Audio capture failed");
  }

  httpd_resp_set_type(req, "audio/wav");
  esp_err_t result = httpd_resp_send(req, (const char*)wav, wavSize);

  free(wav);
  audioBusy = false;
  return result;
}

static esp_err_t playAudioHandler(httpd_req_t* req) {
  addHeaders(req);

  if (!speakerReady || !speakerEnabled) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    return httpd_resp_sendstr(req, "Speaker disabled");
  }

  if (audioBusy) {
    httpd_resp_set_status(req, "409 Conflict");
    return httpd_resp_sendstr(req, "Audio busy");
  }

  if (req->content_len < 44 || req->content_len > MAX_AUDIO_UPLOAD) {
    httpd_resp_set_status(req, "413 Payload Too Large");
    return httpd_resp_sendstr(req, "Short 16kHz WAV required");
  }

  audioBusy = true;
  size_t size = (size_t)req->content_len;

  uint8_t* wav = (uint8_t*)ps_malloc(size);
  if (!wav) wav = (uint8_t*)malloc(size);

  if (!wav) {
    audioBusy = false;
    return httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Audio memory unavailable");
  }

  size_t received = 0;
  while (received < size) {
    int n = httpd_req_recv(req, (char*)wav + received, size - received);
    if (n == HTTPD_SOCK_ERR_TIMEOUT) continue;
    if (n <= 0) {
      free(wav);
      audioBusy = false;
      return ESP_FAIL;
    }
    received += n;
  }

  if (memcmp(wav, "RIFF", 4) != 0 || memcmp(wav + 8, "WAVE", 4) != 0) {
    free(wav);
    audioBusy = false;
    httpd_resp_set_status(req, "415 Unsupported Media Type");
    return httpd_resp_sendstr(req, "WAV required");
  }

  speakerI2S.playWAV(wav, size);

  free(wav);
  audioBusy = false;
  return httpd_resp_sendstr(req, "{\"ok\":true,\"played\":true}");
}

// ===================================================
// REGISTER HTTP ENDPOINT
// ===================================================

bool registerEndpoint(httpd_handle_t server, const char* path, httpd_method_t method,
                      esp_err_t (*handler)(httpd_req_t*)) {
  httpd_uri_t uri = {};
  uri.uri = path;
  uri.method = method;
  uri.handler = handler;
  uri.user_ctx = nullptr;

  esp_err_t err = httpd_register_uri_handler(server, &uri);
  if (err != ESP_OK) {
    Serial.printf("[HTTP] Registration failed: %s %d\n", path, (int)err);
    return false;
  }
  return true;
}

// ===================================================
// HTTP SERVER INITIALIZATION
// ===================================================

bool startCameraServers() {
  if (serversStarted) return true;

  Serial.println("[HTTP] Starting servers...");

  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  config.max_uri_handlers = 40;
  config.stack_size = 8192;
  config.lru_purge_enable = true;

  if (httpd_start(&webServer, &config) != ESP_OK) {
    Serial.println("[HTTP] Port 80 failed.");
    return false;
  }

  bool ok = true;
  ok &= registerEndpoint(webServer, "/", HTTP_GET, pageHandler);
  ok &= registerEndpoint(webServer, "/status", HTTP_GET, statusHandler);
  ok &= registerEndpoint(webServer, "/motion", HTTP_GET, motionHandler);
  ok &= registerEndpoint(webServer, "/capture", HTTP_GET, captureHandler);
  ok &= registerEndpoint(webServer, "/save", HTTP_POST, saveHandler);
  ok &= registerEndpoint(webServer, "/set", HTTP_GET, settingsHandler);
  ok &= registerEndpoint(webServer, "/api/camera/on", HTTP_POST, cameraOnHandler);
  ok &= registerEndpoint(webServer, "/api/camera/off", HTTP_POST, cameraOffHandler);
  ok &= registerEndpoint(webServer, "/api/motion/on", HTTP_POST, motionOnHandler);
  ok &= registerEndpoint(webServer, "/api/motion/off", HTTP_POST, motionOffHandler);
  ok &= registerEndpoint(webServer, "/api/mic/on", HTTP_POST, micOnHandler);
  ok &= registerEndpoint(webServer, "/api/mic/off", HTTP_POST, micOffHandler);
  ok &= registerEndpoint(webServer, "/api/speaker/on", HTTP_POST, speakerOnHandler);
  ok &= registerEndpoint(webServer, "/api/speaker/off", HTTP_POST, speakerOffHandler);
  ok &= registerEndpoint(webServer, "/audio/record", HTTP_GET, recordAudioHandler);
  ok &= registerEndpoint(webServer, "/audio/play", HTTP_POST, playAudioHandler);
  ok &= registerEndpoint(webServer, "/link", HTTP_GET, linkHandler);
  ok &= registerEndpoint(webServer, "/ptz", HTTP_POST, ptzHandler);

  // Flutter web preflight support.
  const char* paths[] = {
    "/status", "/motion", "/capture", "/save", "/set",
    "/api/camera/on", "/api/camera/off", "/api/motion/on", "/api/motion/off",
    "/api/mic/on", "/api/mic/off", "/api/speaker/on", "/api/speaker/off",
    "/audio/record", "/audio/play", "/ptz"
  };

  for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
    ok &= registerEndpoint(webServer, paths[i], HTTP_OPTIONS, optionsHandler);
  }

  if (!ok) {
    Serial.println("[HTTP] Endpoint registration failure.");
    httpd_stop(webServer);
    webServer = nullptr;
    return false;
  }

  httpd_config_t streamConfig = HTTPD_DEFAULT_CONFIG();
  streamConfig.server_port = 81;
  streamConfig.ctrl_port = config.ctrl_port + 1;
  streamConfig.max_uri_handlers = 4;
  streamConfig.send_wait_timeout = 4;
  streamConfig.lru_purge_enable = true;
  streamConfig.max_open_sockets = 3;

  if (httpd_start(&streamServer, &streamConfig) != ESP_OK) {
    Serial.println("[HTTP] Port 81 failed.");
    httpd_stop(webServer);
    webServer = nullptr;
    return false;
  }

  if (!registerEndpoint(streamServer, "/stream", HTTP_GET, streamHandler)) {
    httpd_stop(streamServer);
    streamServer = nullptr;
    httpd_stop(webServer);
    webServer = nullptr;
    return false;
  }

  serversStarted = true;
  Serial.println("[HTTP] SERVERS READY");
  return true;
}

// ===================================================
// MAIN SETUP
// ===================================================

void setup() {
  Serial.begin(115200);
  unsigned long usbStart = millis();
  while (!Serial && millis() - usbStart < 2500UL) {
    delay(20);
  }
  delay(300);

  Serial.println();
  Serial.println("====================================");
  Serial.println("PYROGUARD CAMERA 1");
  Serial.println("DFR1154 + BACKGROUND MOTION + MANUAL PTZ RELAY + WEB DASHBOARD");
  Serial.printf("[BOOT] Uptime=%lu ms, free heap=%u, PSRAM=%s\n",
                millis(), (unsigned)ESP.getFreeHeap(), psramFound() ? "YES" : "NO");
  Serial.println("====================================");

  pinMode(IR_LED_PIN, OUTPUT);
  digitalWrite(IR_LED_PIN, LOW);
  pinMode(STATUS_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, LOW);

  cameraReady = initializeCamera();
  if (!cameraReady) {
    Serial.println("[CAMERA] Sensor init failed; starting WiFi/HTTP diagnostics anyway.");
  } else {
    initializeMotion();
  }

  initializePtzRelay();

  if (connectWiFi()) {
    if (startCameraServers()) {
      printAddresses();
    } else {
      Serial.println("[HTTP] Could not start endpoints; will retry in loop.");
    }
  } else {
    Serial.println("[BOOT] No camera URL yet: WiFi is disconnected.");
  }

  initializeAudio();

  if (ENABLE_CLOUD) {
    configTime(0, 0, "pool.ntp.org", "time.google.com");
  }

  lastHeartbeat = millis();

  if (!cloudConfigured()) {
    Serial.println("[CLOUD] Cloud upload is off (ENABLE_CLOUD false or not configured).");
  }

  Serial.println("[BOOT] Ready");
}

// ===================================================
// MAIN LOOP
// ===================================================

void loop() {
  if (millis() - lastSerialHealth >= SERIAL_HEALTH_INTERVAL_MS) {
    lastSerialHealth = millis();
    Serial.printf("[ALIVE] %lus WiFi=%d camera=%d stream=%d motion=%d analyses=%lu heap=%u\n",
                  millis() / 1000UL, (int)WiFi.status(), (int)cameraReady,
                  (int)serversStarted, (int)motionDetected,
                  (unsigned long)motionAnalysisCount, (unsigned)ESP.getFreeHeap());
    Serial.flush();
  }

  bool wifiConnected = WiFi.status() == WL_CONNECTED;

  if (!wifiConnected) {
    digitalWrite(STATUS_LED_PIN, LOW);

    if (millis() - lastWifiAttempt >= WIFI_RETRY_MS) {
      Serial.println();
      Serial.println("[SYSTEM] WiFi reconnecting");

      if (connectWiFi()) {
        if (!serversStarted) startCameraServers();
        if (serversStarted) printAddresses();
        lastHeartbeat = millis();
      }
    }

    delay(50);
    return;
  }

  digitalWrite(STATUS_LED_PIN, HIGH);

  if (!serversStarted) {
    if (lastServerRetry == 0 || millis() - lastServerRetry >= 5000UL) {
      lastServerRetry = millis();
      Serial.println("[HTTP] Starting camera servers...");
      if (startCameraServers()) printAddresses();
    }
  }

  if (serversStarted && millis() - lastAddressPrint >= ADDRESS_INTERVAL_MS) {
    printAddresses();
  }

  if (ENABLE_CLOUD && millis() - lastHeartbeat >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeat = millis();
    if (!sendHeartbeat()) {
      Serial.println("[CLOUD] Heartbeat not sent or rejected; verify key/time/network/Edge Function.");
    }
  }

  // Cloud photos: queued requests first, then a photo when new motion starts.
  if (ENABLE_CLOUD && cloudConfigured()) {
    if (CLOUD_MOTION_PHOTOS && motionDetected && motionDetectionCount != lastPhotoMotionCount &&
        (lastMotionPhotoMs == 0 || millis() - lastMotionPhotoMs >= CLOUD_MOTION_PHOTO_GAP_MS)) {
      lastPhotoMotionCount = motionDetectionCount;
      lastMotionPhotoMs = millis();
      if (pendingPhotoReason < 2) pendingPhotoReason = 2;
    }
    const int reason = pendingPhotoReason;
    if (reason) {
      pendingPhotoReason = 0;
      if (uploadPhotoToSupabase(photoReasonName(reason))) cloudPhotoOk++;
      else cloudPhotoFailed++;
    }
  }

  // Keep motion sensing active when nobody is watching the stream.
  if (motionReady && motionEnabled && cameraEnabled && cameraReady &&
      millis() - lastStreamFrameMs > 3000UL &&
      millis() - lastMotionQueued >= MOTION_INTERVAL_MS) {
    camera_fb_t* frame = esp_camera_fb_get();
    if (frame != nullptr) {
      queueMotionFrame(frame);
      esp_camera_fb_return(frame);
    }
  }

  delay(30);
}
