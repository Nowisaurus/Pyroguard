/*
  PyroGuard DFR1154 — camera + two-way audio + motion + Supabase telemetry

  Board settings:
    Board: ESP32S3 Dev Module
    USB CDC On Boot: Enabled
    Flash: 16MB
    PSRAM: OPI PSRAM
    Serial: 115200

  TWO-WAY AUDIO DESIGN
    DFR1154 mic -> software:
      http://CAMERA_IP:82/mic
      Raw PCM16LE, 16 kHz, mono

    software mic -> DFR1154 speaker:
      POST http://CAMERA_IP/api/audio/play-pcm
      Body: raw PCM16LE, 16 kHz, mono

    Optional WAV helpers:
      GET  /api/audio/record?seconds=3
      POST /api/audio/play-wav
      GET  /api/audio/echo-test?seconds=5

  For security-camera use, Push-To-Talk (half duplex) is recommended to avoid
  speaker-to-microphone echo. The firmware can technically receive mic audio
  while playing speaker audio because the mic uses I2S0 PDM RX and the speaker
  uses I2S1 STD TX.
*/

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>
#include <esp_http_server.h>
#include "esp_camera.h"
#include "img_converters.h"
#include "ESP_I2S.h"

// ----------------- YOUR SETTINGS -----------------
const char *WIFI_SSID = "YOUR_WIFI_NAME";
const char *WIFI_PASSWORD = "YOUR_WIFI_PASSWORD";
const char *SUPABASE_URL = "https://torzyarstitxsreoqcig.supabase.co";
const char *SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRvcnp5YXJzdGl0eHNyZW9xY2lnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzgyNjQzODgsImV4cCI6MjA5Mzg0MDM4OH0.pCVe-vnX0Ey4_0uV1m6WIeooW6rNOIqMqCEMDgVFC_s";
const char *DEVICE_ID = "ESP32-001"; // same registered home/controller ID used by Flutter
const char *CAMERA_DEVICE_ID = "pyroguard_camera_001";
// MySQL history stays behind the Supabase Edge Function. This device key is
// revocable and is NOT a MySQL password. Configure the same value as the
// PYROGUARD_DEVICE_KEY Edge Function secret.
const char *HISTORY_FUNCTION_URL = "https://torzyarstitxsreoqcig.supabase.co/functions/v1/mysql-history";
const char *HISTORY_DEVICE_KEY = "CHANGE_ME";
bool postCameraEventToHistory(const String& telemetryJson);
bool postCameraMirrorToMysql(const String& recordType, const String& recordKey, const String& payloadJson);

// Optional CA PEM. Blank = insecure TLS for prototype only.
const char *SUPABASE_ROOT_CA = "";

// Main ESP32 sensor board. Enable only when it implements pan/tilt endpoints.
const bool ENABLE_EXTERNAL_PAN_TILT = false;
const char *SENSOR_IP = "192.168.8.107";

// ----------------- DFR1154 CAMERA PINS -----------------
#define PWDN_GPIO_NUM   -1
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM    5
#define SIOD_GPIO_NUM    8
#define SIOC_GPIO_NUM    9
#define Y9_GPIO_NUM      4
#define Y8_GPIO_NUM      6
#define Y7_GPIO_NUM      7
#define Y6_GPIO_NUM     14
#define Y5_GPIO_NUM     17
#define Y4_GPIO_NUM     21
#define Y3_GPIO_NUM     18
#define Y2_GPIO_NUM     16
#define VSYNC_GPIO_NUM   1
#define HREF_GPIO_NUM    2
#define PCLK_GPIO_NUM   15

// ----------------- DFR1154 AUDIO PINS -----------------
// Built-in PDM microphone
#define MIC_CLK_GPIO     38
#define MIC_DATA_GPIO    39

// MAX98357 speaker amplifier -> onboard SPK connector
#define SPK_BCLK_GPIO    45
#define SPK_LRCLK_GPIO   46
#define SPK_DATA_GPIO    42

constexpr uint32_t AUDIO_SAMPLE_RATE = 16000;
constexpr float SPEAKER_GAIN = 2.0f;       // proven working in your test
constexpr size_t AUDIO_CHUNK_BYTES = 1024;
constexpr size_t MAX_WAV_UPLOAD_BYTES = 320044; // about 10 sec, 16k/16-bit/mono

// PDM RX must use I2S0; use I2S1 for speaker TX.
I2SClass mic(I2S_NUM_0);
I2SClass speaker(I2S_NUM_1);

static bool micReady = false;
static bool speakerReady = false;
static volatile bool micStreamActive = false;
static volatile bool cameraEnabled = true;
static volatile bool micEnabled = true;
static volatile bool speakerEnabled = true;
static SemaphoreHandle_t speakerMutex = nullptr;

// ----------------- MOTION / TELEMETRY -----------------
constexpr int WIDTH = 320;
constexpr int HEIGHT = 240;
constexpr int SAMPLE_STEP = 8;
constexpr int GRID_W = WIDTH / SAMPLE_STEP;
constexpr int GRID_H = HEIGHT / SAMPLE_STEP;
constexpr int SAMPLE_COUNT = GRID_W * GRID_H;
constexpr int PIXEL_DELTA_THRESHOLD = 32;
constexpr int MOTION_SAMPLE_THRESHOLD = 22;
constexpr uint32_t MOTION_INTERVAL_MS = 2000;
constexpr uint32_t EVENT_MIN_INTERVAL_MS = 15000;
constexpr uint32_t HEARTBEAT_INTERVAL_MS = 60000;
constexpr int PAN_MIN = 10, PAN_MAX = 170, PAN_STEP = 12;
constexpr int TILT_MIN = 30, TILT_MAX = 150, TILT_STEP = 8;

static uint8_t previousSamples[SAMPLE_COUNT];
static uint8_t *rgbWork = nullptr;
static bool previousFrameReady = false;
static bool motionAnalysisEnabled = false;
static bool cameraReady = false;
static bool serverReady = false;
static bool motionDetected = false;
static bool pendingMotionEvent = false;
static int motionSampleCount = 0;
static int virtualPan = 90, virtualTilt = 90;
static uint32_t lastMotionCheck = 0;
static uint32_t lastCloudAttempt = 0;
static uint32_t lastEventSuccess = 0;
static uint32_t lastReconnectAttempt = 0;

static httpd_handle_t pageServer = nullptr;   // port 80: UI + API
static httpd_handle_t videoServer = nullptr;  // port 81: MJPEG
static httpd_handle_t audioServer = nullptr;  // port 82: raw mic PCM

// ----------------- HELPERS -----------------
void addCors(httpd_req_t *req) {
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET,POST,OPTIONS");
}

esp_err_t sendJson(httpd_req_t *req, const String &json, const char *status = "200 OK") {
  httpd_resp_set_status(req, status);
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  addCors(req);
  return httpd_resp_send(req, json.c_str(), json.length());
}


esp_err_t sendTextError(httpd_req_t *req, const char *status, const char *message) {
  httpd_resp_set_status(req, status);
  httpd_resp_set_type(req, "text/plain; charset=utf-8");
  addCors(req);
  return httpd_resp_send(req, message, HTTPD_RESP_USE_STRLEN);
}

esp_err_t optionsHandler(httpd_req_t *req) {
  addCors(req);
  return httpd_resp_send(req, nullptr, 0);
}

void boostPcm16(uint8_t *data, size_t size, float gain) {
  if (!data || size < 2 || gain <= 0.0f) return;
  size &= ~((size_t)1); // 16-bit aligned
  int16_t *samples = reinterpret_cast<int16_t *>(data);
  size_t count = size / sizeof(int16_t);
  for (size_t i = 0; i < count; ++i) {
    int32_t v = (int32_t)(samples[i] * gain);
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    samples[i] = (int16_t)v;
  }
}

void boostWav16(uint8_t *wav, size_t size, float gain) {
  // recordWAV creates the usual 44-byte PCM WAV header.
  if (!wav || size <= 44) return;
  boostPcm16(wav + 44, size - 44, gain);
}

// ----------------- WEB PAGE -----------------
static const char INDEX_HTML[] = R"PYROHTML(
<!doctype html><html lang="en"><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>PyroGuard — Camera + Audio</title>
<style>
body{font:16px system-ui,Arial;background:#101b28;color:#eef3f8;margin:0;padding:22px;text-align:center}
h1{color:#ff7655;margin-bottom:4px}main{max-width:850px;margin:auto}
img{display:block;width:100%;background:#000;border-radius:12px;min-height:180px}
button{padding:12px 18px;margin:5px;border:0;border-radius:8px;background:#ff7655;color:#111;cursor:pointer;font-weight:bold}
small{color:#b6c6d6}.info{line-height:1.9}#state{color:#84edab}.group{margin:14px 0}
</style></head><body><main><h1>PYROGUARD</h1>
<p>DFR1154 camera + two-way audio</p><img id="video" alt="Live camera stream">
<p id="state">Connecting...</p>
<div class="group"><button onclick="startVideo()">Camera ON</button><button onclick="stopVideo()">Camera OFF</button></div>
<div class="group"><button onclick="listen3()">Listen 3 sec</button><button onclick="echo5()">Mic→Speaker Test</button></div>
<audio id="audio" controls></audio>
<div class="info" id="stats">Loading device status...</div>
<small>Live mic PCM: port 82 /mic. Software-to-speaker: POST PCM16LE to /api/audio/play-pcm.<br>
Push-to-talk is recommended to avoid acoustic echo.</small>
</main><script>
const video=document.getElementById('video'),audio=document.getElementById('audio');
async function api(path){const r=await fetch(path,{method:'POST'});return r.json();}
async function startVideo(){await api('/api/camera/on');video.src='http://'+location.hostname+':81/stream?t='+Date.now();document.getElementById('state').textContent='Camera requested';}
async function stopVideo(){video.removeAttribute('src');await api('/api/camera/off');document.getElementById('state').textContent='Camera stopped';}
async function listen3(){const r=await fetch('/api/audio/record?seconds=3');if(!r.ok){alert(await r.text());return;}const b=await r.blob();audio.src=URL.createObjectURL(b);audio.play();}
async function echo5(){const r=await fetch('/api/audio/echo-test?seconds=5');const t=await r.text();alert(t);}
async function status(){try{const r=await fetch('/status');const s=await r.json();document.getElementById('stats').textContent=`Wi-Fi: ${s.wifi} | Camera: ${s.camera_enabled?'ON':'OFF'} | Mic: ${s.mic_ready?'ready':'not ready'} | Speaker: ${s.speaker_ready?'ready':'not ready'} | Motion: ${s.motion?'DETECTED':'none'} | Pan: ${s.pan}° | Tilt: ${s.tilt}°`; }catch(e){document.getElementById('stats').textContent='Status unavailable';}}
startVideo();status();setInterval(status,3000);
</script></body></html>
)PYROHTML";

// ----------------- STATUS / CONTROL -----------------
static esp_err_t indexHandler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html; charset=utf-8");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  return httpd_resp_send(req, INDEX_HTML, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t statusHandler(httpd_req_t *req) {
  String json = "{\"wifi\":\"";
  json += WiFi.status() == WL_CONNECTED ? "connected" : "disconnected";
  json += "\",\"camera_ready\":" + String(cameraReady ? "true" : "false");
  json += ",\"camera_enabled\":" + String(cameraEnabled ? "true" : "false");
  json += ",\"mic_ready\":" + String(micReady ? "true" : "false");
  json += ",\"mic_enabled\":" + String(micEnabled ? "true" : "false");
  json += ",\"speaker_ready\":" + String(speakerReady ? "true" : "false");
  json += ",\"speaker_enabled\":" + String(speakerEnabled ? "true" : "false");
  json += ",\"mic_streaming\":" + String(micStreamActive ? "true" : "false");
  json += ",\"motion\":" + String(motionDetected ? "true" : "false");
  json += ",\"motion_samples\":" + String(motionSampleCount);
  json += ",\"pan\":" + String(virtualPan);
  json += ",\"tilt\":" + String(virtualTilt);
  json += ",\"uptime_ms\":" + String(millis());
  json += ",\"video_url\":\"http://" + WiFi.localIP().toString() + ":81/stream\"";
  json += ",\"mic_pcm_url\":\"http://" + WiFi.localIP().toString() + ":82/mic\"";
  json += "}";
  return sendJson(req, json);
}

static esp_err_t cameraOnHandler(httpd_req_t *req) {
  cameraEnabled = true;
  return sendJson(req, "{\"ok\":true,\"camera_enabled\":true}");
}

static esp_err_t cameraOffHandler(httpd_req_t *req) {
  cameraEnabled = false;
  motionDetected = false;
  return sendJson(req, "{\"ok\":true,\"camera_enabled\":false}");
}

static esp_err_t micOnHandler(httpd_req_t *req) {
  micEnabled = true;
  return sendJson(req, "{\"ok\":true,\"mic_enabled\":true}");
}

static esp_err_t micOffHandler(httpd_req_t *req) {
  micEnabled = false;
  return sendJson(req, "{\"ok\":true,\"mic_enabled\":false}");
}

static esp_err_t speakerOnHandler(httpd_req_t *req) {
  speakerEnabled = true;
  return sendJson(req, "{\"ok\":true,\"speaker_enabled\":true}");
}

static esp_err_t speakerOffHandler(httpd_req_t *req) {
  speakerEnabled = false;
  return sendJson(req, "{\"ok\":true,\"speaker_enabled\":false}");
}

// ----------------- VIDEO -----------------
static esp_err_t streamHandler(httpd_req_t *req) {
  if (!cameraReady || !cameraEnabled) {
    sendTextError(req, "503 Service Unavailable", "Camera disabled or unavailable");
    return ESP_FAIL;
  }
  static const char *TYPE = "multipart/x-mixed-replace;boundary=frame";
  static const char *BOUNDARY = "\r\n--frame\r\n";
  static const char *PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";
  esp_err_t result = httpd_resp_set_type(req, TYPE);
  if (result != ESP_OK) return result;
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  addCors(req);
  char header[96];
  Serial.println("[STREAM] Video client connected");

  while (cameraEnabled) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) { result = ESP_FAIL; break; }
    if (fb->format != PIXFORMAT_JPEG) {
      esp_camera_fb_return(fb);
      result = ESP_FAIL;
      break;
    }
    const int len = snprintf(header, sizeof(header), PART, (unsigned int)fb->len);
    result = httpd_resp_send_chunk(req, BOUNDARY, strlen(BOUNDARY));
    if (result == ESP_OK) result = httpd_resp_send_chunk(req, header, len);
    if (result == ESP_OK) result = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    if (result != ESP_OK) break;
    vTaskDelay(pdMS_TO_TICKS(1));
  }
  Serial.println("[STREAM] Video client disconnected");
  return result;
}

static esp_err_t snapshotHandler(httpd_req_t *req) {
  if (!cameraReady || !cameraEnabled) {
    sendTextError(req, "503 Service Unavailable", "Camera disabled or unavailable");
    return ESP_FAIL;
  }
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb || fb->format != PIXFORMAT_JPEG) {
    if (fb) esp_camera_fb_return(fb);
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Snapshot failed");
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  addCors(req);
  esp_err_t r = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return r;
}

// ----------------- MICROPHONE -> SOFTWARE -----------------
static esp_err_t micStreamHandler(httpd_req_t *req) {
  if (!micReady || !micEnabled) {
    sendTextError(req, "503 Service Unavailable", "Microphone disabled or unavailable");
    return ESP_FAIL;
  }
  if (micStreamActive) {
    sendTextError(req, "409 Conflict", "Microphone stream already in use");
    return ESP_FAIL;
  }

  micStreamActive = true;
  httpd_resp_set_type(req, "application/octet-stream");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  httpd_resp_set_hdr(req, "X-Audio-Format", "PCM16LE");
  httpd_resp_set_hdr(req, "X-Sample-Rate", "16000");
  httpd_resp_set_hdr(req, "X-Channels", "1");
  addCors(req);

  uint8_t buffer[AUDIO_CHUNK_BYTES];
  esp_err_t result = ESP_OK;
  Serial.println("[AUDIO] Live mic client connected");

  while (micEnabled && WiFi.status() == WL_CONNECTED) {
    size_t got = mic.readBytes((char *)buffer, sizeof(buffer));
    if (got == 0) {
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    result = httpd_resp_send_chunk(req, (const char *)buffer, got);
    if (result != ESP_OK) break;
  }

  micStreamActive = false;
  Serial.println("[AUDIO] Live mic client disconnected");
  return result;
}

static int getRecordSeconds(httpd_req_t *req, int defaultSeconds) {
  char query[64] = {0};
  char value[16] = {0};
  int seconds = defaultSeconds;
  if (httpd_req_get_url_query_len(req) > 0 &&
      httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK &&
      httpd_query_key_value(query, "seconds", value, sizeof(value)) == ESP_OK) {
    seconds = atoi(value);
  }
  return constrain(seconds, 1, 5);
}

static esp_err_t recordWavHandler(httpd_req_t *req) {
  if (!micReady || !micEnabled) {
    sendTextError(req, "503 Service Unavailable", "Microphone disabled or unavailable");
    return ESP_FAIL;
  }
  if (micStreamActive) {
    sendTextError(req, "409 Conflict", "Stop live mic stream before WAV recording");
    return ESP_FAIL;
  }

  int seconds = getRecordSeconds(req, 3);
  size_t wavSize = 0;
  Serial.printf("[AUDIO] Recording %d second WAV\n", seconds);
  uint8_t *wav = mic.recordWAV(seconds, &wavSize);
  if (!wav || wavSize == 0) {
    if (wav) free(wav);
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Recording failed");
    return ESP_FAIL;
  }

  httpd_resp_set_type(req, "audio/wav");
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  httpd_resp_set_hdr(req, "Content-Disposition", "inline; filename=pyroguard_mic.wav");
  addCors(req);
  esp_err_t r = httpd_resp_send(req, (const char *)wav, wavSize);
  free(wav); // recordWAV buffer belongs to us.
  return r;
}

// ----------------- SOFTWARE -> SPEAKER -----------------
static esp_err_t playPcmHandler(httpd_req_t *req) {
  if (!speakerReady || !speakerEnabled) {
    sendTextError(req, "503 Service Unavailable", "Speaker disabled or unavailable");
    return ESP_FAIL;
  }
  if (req->content_len <= 0) {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Send PCM16LE audio in request body");
    return ESP_FAIL;
  }
  if (xSemaphoreTake(speakerMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    sendTextError(req, "409 Conflict", "Speaker busy");
    return ESP_FAIL;
  }

  uint8_t buffer[AUDIO_CHUNK_BYTES];
  int remaining = req->content_len;
  bool ok = true;
  while (remaining > 0) {
    int want = min((int)sizeof(buffer), remaining);
    int got = httpd_req_recv(req, (char *)buffer, want);
    if (got == HTTPD_SOCK_ERR_TIMEOUT) continue;
    if (got <= 0) { ok = false; break; }
    size_t aligned = ((size_t)got) & ~((size_t)1);
    boostPcm16(buffer, aligned, SPEAKER_GAIN);
    if (aligned && speaker.write(buffer, aligned) != aligned) {
      ok = false;
      break;
    }
    remaining -= got;
  }

  xSemaphoreGive(speakerMutex);
  if (!ok) {
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "PCM playback failed");
    return ESP_FAIL;
  }
  return sendJson(req, "{\"ok\":true,\"played\":\"pcm16le\",\"sample_rate\":16000}");
}

static esp_err_t playWavHandler(httpd_req_t *req) {
  if (!speakerReady || !speakerEnabled) {
    sendTextError(req, "503 Service Unavailable", "Speaker disabled or unavailable");
    return ESP_FAIL;
  }
  const size_t len = req->content_len;
  if (len <= 44 || len > MAX_WAV_UPLOAD_BYTES) {
    httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "WAV must be PCM 16kHz mono and <= about 10 seconds");
    return ESP_FAIL;
  }
  if (xSemaphoreTake(speakerMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    sendTextError(req, "409 Conflict", "Speaker busy");
    return ESP_FAIL;
  }

  uint8_t *wav = (uint8_t *)ps_malloc(len);
  if (!wav) {
    xSemaphoreGive(speakerMutex);
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Not enough PSRAM for WAV");
    return ESP_FAIL;
  }

  size_t received = 0;
  bool ok = true;
  while (received < len) {
    int got = httpd_req_recv(req, (char *)wav + received, len - received);
    if (got == HTTPD_SOCK_ERR_TIMEOUT) continue;
    if (got <= 0) { ok = false; break; }
    received += (size_t)got;
  }

  if (ok) {
    boostWav16(wav, len, SPEAKER_GAIN);
    speaker.playWAV(wav, len);
  }
  free(wav);
  xSemaphoreGive(speakerMutex);

  if (!ok) {
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "WAV upload/playback failed");
    return ESP_FAIL;
  }
  return sendJson(req, "{\"ok\":true,\"played\":\"wav\"}");
}

static esp_err_t echoTestHandler(httpd_req_t *req) {
  if (!micReady || !speakerReady || !micEnabled || !speakerEnabled) {
    sendTextError(req, "503 Service Unavailable", "Mic or speaker unavailable/disabled");
    return ESP_FAIL;
  }
  if (micStreamActive) {
    sendTextError(req, "409 Conflict", "Stop live mic stream before echo test");
    return ESP_FAIL;
  }
  if (xSemaphoreTake(speakerMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    sendTextError(req, "409 Conflict", "Speaker busy");
    return ESP_FAIL;
  }

  int seconds = getRecordSeconds(req, 5);
  size_t wavSize = 0;
  Serial.printf("[AUDIO] Echo test: recording %d seconds\n", seconds);
  uint8_t *wav = mic.recordWAV(seconds, &wavSize);
  if (!wav || wavSize == 0) {
    if (wav) free(wav);
    xSemaphoreGive(speakerMutex);
    httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Echo recording failed");
    return ESP_FAIL;
  }

  boostWav16(wav, wavSize, SPEAKER_GAIN);
  Serial.printf("[AUDIO] Echo test: playing %u bytes\n", (unsigned int)wavSize);
  speaker.playWAV(wav, wavSize);
  free(wav);
  xSemaphoreGive(speakerMutex);
  return sendJson(req, "{\"ok\":true,\"echo_test\":true}");
}

// ----------------- CAMERA / AUDIO INITIALIZATION -----------------
bool initializeCamera() {
  if (!psramFound()) {
    Serial.println("[CAMERA] PSRAM not detected; set Tools > PSRAM > OPI PSRAM");
    return false;
  }
  camera_config_t cfg = {};
  cfg.ledc_channel = LEDC_CHANNEL_0;
  cfg.ledc_timer = LEDC_TIMER_0;
  cfg.pin_d0 = Y2_GPIO_NUM; cfg.pin_d1 = Y3_GPIO_NUM;
  cfg.pin_d2 = Y4_GPIO_NUM; cfg.pin_d3 = Y5_GPIO_NUM;
  cfg.pin_d4 = Y6_GPIO_NUM; cfg.pin_d5 = Y7_GPIO_NUM;
  cfg.pin_d6 = Y8_GPIO_NUM; cfg.pin_d7 = Y9_GPIO_NUM;
  cfg.pin_xclk = XCLK_GPIO_NUM;
  cfg.pin_pclk = PCLK_GPIO_NUM;
  cfg.pin_vsync = VSYNC_GPIO_NUM;
  cfg.pin_href = HREF_GPIO_NUM;
  cfg.pin_sccb_sda = SIOD_GPIO_NUM;
  cfg.pin_sccb_scl = SIOC_GPIO_NUM;
  cfg.pin_pwdn = PWDN_GPIO_NUM;
  cfg.pin_reset = RESET_GPIO_NUM;
  cfg.xclk_freq_hz = 20000000;
  cfg.pixel_format = PIXFORMAT_JPEG;
  cfg.frame_size = FRAMESIZE_QVGA;
  cfg.jpeg_quality = 12;
  cfg.fb_count = 2;
  cfg.fb_location = CAMERA_FB_IN_PSRAM;
  cfg.grab_mode = CAMERA_GRAB_LATEST;

  esp_err_t err = esp_camera_init(&cfg);
  if (err != ESP_OK) {
    Serial.printf("[CAMERA] Initialization failed: 0x%X\n", (unsigned int)err);
    return false;
  }
  sensor_t *sensor = esp_camera_sensor_get();
  Serial.printf("[CAMERA] Ready; sensor PID: 0x%X\n", sensor ? sensor->id.PID : 0);
  rgbWork = (uint8_t *)ps_malloc((size_t)WIDTH * HEIGHT * 3);
  motionAnalysisEnabled = rgbWork != nullptr;
  Serial.println(motionAnalysisEnabled ? "[MOTION] Analysis enabled" : "[MOTION] No RGB buffer; streaming still available");
  return true;
}

void initializeAudio() {
  speakerMutex = xSemaphoreCreateMutex();

  mic.setPinsPdmRx(MIC_CLK_GPIO, MIC_DATA_GPIO);
  micReady = mic.begin(I2S_MODE_PDM_RX,
                       AUDIO_SAMPLE_RATE,
                       I2S_DATA_BIT_WIDTH_16BIT,
                       I2S_SLOT_MODE_MONO);
  Serial.println(micReady ? "[AUDIO] Microphone ready" : "[AUDIO] Microphone initialization FAILED");

  speaker.setPins(SPK_BCLK_GPIO, SPK_LRCLK_GPIO, SPK_DATA_GPIO);
  speakerReady = speaker.begin(I2S_MODE_STD,
                               AUDIO_SAMPLE_RATE,
                               I2S_DATA_BIT_WIDTH_16BIT,
                               I2S_SLOT_MODE_MONO);
  Serial.println(speakerReady ? "[AUDIO] Speaker ready" : "[AUDIO] Speaker initialization FAILED");
}

// ----------------- SERVERS -----------------
bool startServers() {
  // Main page/API server on port 80
  httpd_config_t pageCfg = HTTPD_DEFAULT_CONFIG();
  pageCfg.server_port = 80;
  pageCfg.ctrl_port = 32768;
  pageCfg.stack_size = 10240;
  pageCfg.max_uri_handlers = 16;
  if (httpd_start(&pageServer, &pageCfg) != ESP_OK) return false;

  httpd_uri_t routes[] = {
    { .uri = "/",                    .method = HTTP_GET,     .handler = indexHandler,      .user_ctx = nullptr },
    { .uri = "/status",              .method = HTTP_GET,     .handler = statusHandler,     .user_ctx = nullptr },
    { .uri = "/snapshot",            .method = HTTP_GET,     .handler = snapshotHandler,   .user_ctx = nullptr },
    { .uri = "/api/camera/on",       .method = HTTP_POST,    .handler = cameraOnHandler,   .user_ctx = nullptr },
    { .uri = "/api/camera/off",      .method = HTTP_POST,    .handler = cameraOffHandler,  .user_ctx = nullptr },
    { .uri = "/api/mic/on",          .method = HTTP_POST,    .handler = micOnHandler,      .user_ctx = nullptr },
    { .uri = "/api/mic/off",         .method = HTTP_POST,    .handler = micOffHandler,     .user_ctx = nullptr },
    { .uri = "/api/speaker/on",      .method = HTTP_POST,    .handler = speakerOnHandler,  .user_ctx = nullptr },
    { .uri = "/api/speaker/off",     .method = HTTP_POST,    .handler = speakerOffHandler, .user_ctx = nullptr },
    { .uri = "/api/audio/record",    .method = HTTP_GET,     .handler = recordWavHandler,  .user_ctx = nullptr },
    { .uri = "/api/audio/play-pcm",  .method = HTTP_POST,    .handler = playPcmHandler,    .user_ctx = nullptr },
    { .uri = "/api/audio/play-wav",  .method = HTTP_POST,    .handler = playWavHandler,    .user_ctx = nullptr },
    { .uri = "/api/audio/echo-test", .method = HTTP_GET,     .handler = echoTestHandler,   .user_ctx = nullptr },
    { .uri = "/api/audio/play-pcm",  .method = HTTP_OPTIONS, .handler = optionsHandler,    .user_ctx = nullptr },
    { .uri = "/api/audio/play-wav",  .method = HTTP_OPTIONS, .handler = optionsHandler,    .user_ctx = nullptr }
  };
  for (auto &route : routes) {
    if (httpd_register_uri_handler(pageServer, &route) != ESP_OK) {
      Serial.printf("[HTTP] Failed registering %s\n", route.uri);
      return false;
    }
  }

  // Video server on port 81
  httpd_config_t videoCfg = HTTPD_DEFAULT_CONFIG();
  videoCfg.server_port = 81;
  videoCfg.ctrl_port = 32769;
  videoCfg.stack_size = 8192;
  if (httpd_start(&videoServer, &videoCfg) != ESP_OK) return false;
  httpd_uri_t streamUri = {};
  streamUri.uri = "/stream";
  streamUri.method = HTTP_GET;
  streamUri.handler = streamHandler;
  if (httpd_register_uri_handler(videoServer, &streamUri) != ESP_OK) return false;

  // Live microphone server on port 82
  httpd_config_t audioCfg = HTTPD_DEFAULT_CONFIG();
  audioCfg.server_port = 82;
  audioCfg.ctrl_port = 32770;
  audioCfg.stack_size = 8192;
  if (httpd_start(&audioServer, &audioCfg) != ESP_OK) return false;
  httpd_uri_t micUri = {};
  micUri.uri = "/mic";
  micUri.method = HTTP_GET;
  micUri.handler = micStreamHandler;
  if (httpd_register_uri_handler(audioServer, &micUri) != ESP_OK) return false;

  String ip = WiFi.localIP().toString();
  Serial.println("[HTTP] Control/UI: http://" + ip);
  Serial.println("[VIDEO] Stream:   http://" + ip + ":81/stream");
  Serial.println("[AUDIO] Mic PCM:  http://" + ip + ":82/mic");
  Serial.println("[AUDIO] Speaker:  POST http://" + ip + "/api/audio/play-pcm");
  return true;
}

// ----------------- PAN/TILT / MOTION -----------------
void externalServoCommand(const char *axis, int angle) {
  if (!ENABLE_EXTERNAL_PAN_TILT || WiFi.status() != WL_CONNECTED) return;
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + String(SENSOR_IP) + "/" + axis + "?angle=" + String(angle);
  if (!http.begin(client, url)) return;
  http.setTimeout(700);
  int status = http.GET();
  Serial.printf("[PAN/TILT] %s %d -> HTTP %d\n", axis, angle, status);
  http.end();
}

void analyzeMotion() {
  if (!motionAnalysisEnabled || !cameraEnabled) return;
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) return;
  if (fb->format != PIXFORMAT_JPEG || fb->width != WIDTH || fb->height != HEIGHT) {
    esp_camera_fb_return(fb);
    return;
  }
  bool decoded = fmt2rgb888(fb->buf, fb->len, fb->format, rgbWork);
  esp_camera_fb_return(fb);
  if (!decoded) return;

  int left = 0, center = 0, right = 0, top = 0, middle = 0, bottom = 0;
  int total = 0, sample = 0;
  for (int y = 0; y < HEIGHT; y += SAMPLE_STEP) {
    for (int x = 0; x < WIDTH; x += SAMPLE_STEP) {
      size_t p = ((size_t)y * WIDTH + x) * 3;
      uint8_t lum = (uint8_t)(((uint16_t)rgbWork[p] + rgbWork[p + 1] + rgbWork[p + 2]) / 3);
      if (previousFrameReady && abs((int)lum - (int)previousSamples[sample]) > PIXEL_DELTA_THRESHOLD) {
        total++;
        if (x < WIDTH / 3) left++; else if (x < 2 * WIDTH / 3) center++; else right++;
        if (y < HEIGHT / 3) top++; else if (y < 2 * HEIGHT / 3) middle++; else bottom++;
      }
      previousSamples[sample++] = lum;
    }
  }
  if (!previousFrameReady) { previousFrameReady = true; return; }
  motionSampleCount = total;
  motionDetected = total >= MOTION_SAMPLE_THRESHOLD;
  if (!motionDetected) return;
  pendingMotionEvent = true;

  if (left > center && left > right) {
    virtualPan = max(PAN_MIN, virtualPan - PAN_STEP);
    externalServoCommand("pan", virtualPan);
  } else if (right > center && right > left) {
    virtualPan = min(PAN_MAX, virtualPan + PAN_STEP);
    externalServoCommand("pan", virtualPan);
  }
  if (top > middle && top > bottom) {
    virtualTilt = max(TILT_MIN, virtualTilt - TILT_STEP);
    externalServoCommand("tilt", virtualTilt);
  } else if (bottom > middle && bottom > top) {
    virtualTilt = min(TILT_MAX, virtualTilt + TILT_STEP);
    externalServoCommand("tilt", virtualTilt);
  }
}

// ----------------- SUPABASE -----------------
bool postTelemetry(bool event) {
  if (WiFi.status() != WL_CONNECTED) return false;
  if (!strlen(SUPABASE_ANON_KEY)) return false;

  WiFiClientSecure secure;
  if (strlen(SUPABASE_ROOT_CA)) secure.setCACert(SUPABASE_ROOT_CA);
  else secure.setInsecure(); // prototype only

  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/pyroguard_camera_telemetry?on_conflict=camera_device_id";
  if (!http.begin(secure, url)) return false;
  http.setConnectTimeout(4000);
  http.setTimeout(5000);
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Prefer", "resolution=merge-duplicates,return=minimal");

  // Keep the existing schema fields so this remains compatible with your table.
  String json = "{\"device_id\":\"" + String(DEVICE_ID) + "\"";
  json += ",\"camera_device_id\":\"" + String(CAMERA_DEVICE_ID) + "\"";
  json += ",\"camera_ip\":\"" + WiFi.localIP().toString() + "\"";
  json += ",\"status\":\"online\"";
  json += ",\"motion_detected\":" + String(event ? "true" : "false");
  json += ",\"motion_pixels\":" + String(motionSampleCount);
  json += ",\"pan_angle\":" + String(virtualPan);
  json += ",\"tilt_angle\":" + String(virtualTilt);
  json += ",\"wifi_rssi\":" + String(WiFi.RSSI());
  json += ",\"uptime_ms\":" + String(millis());
  json += "}";

  int status = http.POST(json);
  bool ok = (status == 200 || status == 201 || status == 204);
  Serial.printf("[SUPABASE] %s HTTP %d\n", event ? "motion event" : "heartbeat", status);
  if (!ok) {
    String error = http.getString();
    if (error.length() > 240) error = error.substring(0, 240);
    if (error.length()) Serial.println("[SUPABASE] " + error);
  }
  http.end();

  // Camera telemetry is current application data too, so retain the same
  // latest camera state in MySQL instead of treating MySQL as history-only.
  postCameraMirrorToMysql("pyroguard_camera_telemetry", String(CAMERA_DEVICE_ID), json);

  // Motion events are additionally retained as permanent history in both DBs.
  if (ok && event) postCameraEventToHistory(json);
  return ok;
}

bool postCameraEventToHistory(const String& telemetryJson) {
  if (WiFi.status() != WL_CONNECTED) return false;
  if (String(HISTORY_DEVICE_KEY) == "CHANGE_ME") return false;

  WiFiClientSecure secure;
  if (strlen(SUPABASE_ROOT_CA)) secure.setCACert(SUPABASE_ROOT_CA);
  else secure.setInsecure(); // prototype only

  String record = "{\"device_id\":\"" + String(DEVICE_ID) +
                  "\",\"event_type\":\"motion_detected\",\"telemetry\":" +
                  telemetryJson + "}";

  // 1) Mirror to MySQL through the secure Edge Function.
  HTTPClient mysqlHttp;
  if (!mysqlHttp.begin(secure, HISTORY_FUNCTION_URL)) return false;
  mysqlHttp.setConnectTimeout(4000);
  mysqlHttp.setTimeout(5000);
  mysqlHttp.addHeader("apikey", SUPABASE_ANON_KEY);
  mysqlHttp.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  mysqlHttp.addHeader("Content-Type", "application/json");
  mysqlHttp.addHeader("x-device-key", HISTORY_DEVICE_KEY);

  String payload = "{\"action\":\"write_camera\",\"device_id\":\"" +
                   String(DEVICE_ID) + "\",\"record\":" + record + "}";
  int mysqlStatus = mysqlHttp.POST(payload);
  bool mysqlOk = (mysqlStatus >= 200 && mysqlStatus < 300);
  if (!mysqlOk) Serial.printf("[MYSQL MIRROR] camera event HTTP %d\n", mysqlStatus);
  mysqlHttp.end();

  // 2) Keep the same event in Supabase camera_history.
  HTTPClient supaHttp;
  String supaUrl = String(SUPABASE_URL) + "/rest/v1/camera_history";
  if (!supaHttp.begin(secure, supaUrl)) return mysqlOk;
  supaHttp.setConnectTimeout(4000);
  supaHttp.setTimeout(5000);
  supaHttp.addHeader("apikey", SUPABASE_ANON_KEY);
  supaHttp.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  supaHttp.addHeader("Content-Type", "application/json");
  supaHttp.addHeader("Prefer", "return=minimal");

  String supaBody = "{\"device_id\":\"" + String(DEVICE_ID) +
                    "\",\"event_type\":\"motion_detected\",\"metadata_json\":" +
                    record + ",\"mysql_synced\":" +
                    String(mysqlOk ? "true" : "false") + "}";
  int supaStatus = supaHttp.POST(supaBody);
  bool supaOk = (supaStatus >= 200 && supaStatus < 300);
  if (!supaOk) Serial.printf("[SUPABASE HISTORY] camera event HTTP %d\n", supaStatus);
  supaHttp.end();

  return mysqlOk && supaOk;
}


// Generic MySQL mirror for the current camera telemetry/state. The actual
// video/image media remains in Supabase Storage; MySQL receives the same
// metadata, URL/reference and state records so application data is dual-kept.
bool postCameraMirrorToMysql(const String& recordType, const String& recordKey, const String& payloadJson) {
  if (WiFi.status() != WL_CONNECTED) return false;
  if (String(HISTORY_DEVICE_KEY) == "CHANGE_ME") return false;

  WiFiClientSecure secure;
  if (strlen(SUPABASE_ROOT_CA)) secure.setCACert(SUPABASE_ROOT_CA);
  else secure.setInsecure(); // prototype only

  HTTPClient http;
  if (!http.begin(secure, HISTORY_FUNCTION_URL)) return false;
  http.setConnectTimeout(4000);
  http.setTimeout(5000);
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("x-device-key", HISTORY_DEVICE_KEY);

  String body = "{\"action\":\"write_mirror\",\"device_id\":\"" +
                String(DEVICE_ID) + "\",\"record\":{" +
                "\"record_type\":\"" + recordType + "\"," +
                "\"record_key\":\"" + recordKey + "\"," +
                "\"device_id\":\"" + String(DEVICE_ID) + "\"," +
                "\"payload\":" + payloadJson + "}}";
  int status = http.POST(body);
  bool ok = (status >= 200 && status < 300);
  if (!ok) Serial.printf("[MYSQL MIRROR] %s HTTP %d\n", recordType.c_str(), status);
  http.end();
  return ok;
}


// ----------------- SETUP / LOOP -----------------
void setup() {
  Serial.begin(115200);
  delay(2500);
  Serial.println("\n===== PYROGUARD DFR1154 CAMERA + TWO-WAY AUDIO + SUPABASE =====");

  cameraReady = initializeCamera();
  initializeAudio();

  if (!cameraReady) {
    Serial.println("[SYSTEM] Camera unavailable; Wi-Fi/audio setup will still continue");
  }

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.print("[WIFI] Connecting");
  uint32_t started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < 15000) {
    delay(300);
    Serial.print(".");
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println("[WIFI] IP: " + WiFi.localIP().toString());
    if (strlen(SUPABASE_ROOT_CA)) {
      configTime(0, 0, "pool.ntp.org", "time.google.com");
      struct tm timeInfo;
      if (!getLocalTime(&timeInfo, 5000))
        Serial.println("[SUPABASE] Clock sync pending");
    }
    serverReady = startServers();
    if (!serverReady) Serial.println("[HTTP] Server start failed");
  } else {
    Serial.println("[WIFI] Not connected; will retry");
  }

  Serial.printf("[SYSTEM] Camera=%s Mic=%s Speaker=%s\n",
                cameraReady ? "READY" : "FAIL",
                micReady ? "READY" : "FAIL",
                speakerReady ? "READY" : "FAIL");
}

void loop() {
  uint32_t now = millis();

  if (WiFi.status() != WL_CONNECTED) {
    if (now - lastReconnectAttempt >= 10000) {
      lastReconnectAttempt = now;
      Serial.println("[WIFI] Retrying connection...");
      WiFi.reconnect();
    }
  } else if (!serverReady) {
    serverReady = startServers();
  }

  if (cameraReady && motionAnalysisEnabled && now - lastMotionCheck >= MOTION_INTERVAL_MS) {
    lastMotionCheck = now;
    analyzeMotion();
  }

  if (WiFi.status() == WL_CONNECTED) {
    bool eventDue = pendingMotionEvent &&
      (lastCloudAttempt == 0 || now - lastCloudAttempt >= EVENT_MIN_INTERVAL_MS) &&
      (lastEventSuccess == 0 || now - lastEventSuccess >= EVENT_MIN_INTERVAL_MS);
    bool heartbeatDue = lastCloudAttempt == 0 || now - lastCloudAttempt >= HEARTBEAT_INTERVAL_MS;
    if (eventDue || heartbeatDue) {
      lastCloudAttempt = now;
      bool sendEvent = eventDue;
      if (postTelemetry(sendEvent)) {
        if (sendEvent) {
          lastEventSuccess = millis();
          pendingMotionEvent = false;
        }
      }
    }
  }

  delay(10);
}
