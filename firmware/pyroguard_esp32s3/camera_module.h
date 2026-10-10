/*
  camera_module.h — Live MJPEG video stream + snapshot-on-event
  ================================================================
  Only included when ENABLE_CAMERA is 1 in pyroguard_esp32s3.ino.
  No extra library needed — esp_camera.h and esp_http_server.h ship
  with the ESP32 core. Needs PSRAM enabled + "Huge APP" partition
  scheme (Arduino IDE Tools menu).

  TWO THINGS THIS FILE DOES:
  1. cameraCaptureAndUpload() — takes ONE snapshot and uploads it to
     Supabase Storage (used on a confirmed fire, and on PIR motion).
  2. A live MJPEG stream at http://<device-ip>:81/stream — genuinely
     real live video, but only over the same local Wi-Fi network as
     the device (Supabase cannot relay video).

  HARDWARE NOTE: camera pin mapping is THE most board-specific part
  of any ESP32 camera project — the CAM_PIN_* values below assume a
  common ESP32-S3-CAM layout; check your board's actual datasheet.
  Wrong pins won't damage anything, the camera just won't init
  (logged to Serial with the reason).

  ⚠️ This uses GPIO 4-13 and 15-18 almost entirely by itself — see
  the pin-conflict warning in README.md before also enabling GPS,
  PTZ, or PIR.
  ================================================================
*/
#pragma once

#if ENABLE_CAMERA
// Common ESP32-S3-CAM pin mapping — VERIFY against your actual board.
#define CAM_PIN_PWDN    -1
#define CAM_PIN_RESET   -1
#define CAM_PIN_XCLK    15
#define CAM_PIN_SIOD    4
#define CAM_PIN_SIOC    5
#define CAM_PIN_D7      16
#define CAM_PIN_D6      17
#define CAM_PIN_D5      18
#define CAM_PIN_D4      12
#define CAM_PIN_D3      10
#define CAM_PIN_D2      8
#define CAM_PIN_D1      9
#define CAM_PIN_D0      11
#define CAM_PIN_VSYNC   6
#define CAM_PIN_HREF    7
#define CAM_PIN_PCLK    13

bool cameraInit() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0 = CAM_PIN_D0; config.pin_d1 = CAM_PIN_D1;
  config.pin_d2 = CAM_PIN_D2; config.pin_d3 = CAM_PIN_D3;
  config.pin_d4 = CAM_PIN_D4; config.pin_d5 = CAM_PIN_D5;
  config.pin_d6 = CAM_PIN_D6; config.pin_d7 = CAM_PIN_D7;
  config.pin_xclk = CAM_PIN_XCLK;
  config.pin_pclk = CAM_PIN_PCLK;
  config.pin_vsync = CAM_PIN_VSYNC;
  config.pin_href = CAM_PIN_HREF;
  config.pin_sccb_sda = CAM_PIN_SIOD;
  config.pin_sccb_scl = CAM_PIN_SIOC;
  config.pin_pwdn = CAM_PIN_PWDN;
  config.pin_reset = CAM_PIN_RESET;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = FRAMESIZE_SVGA;
  config.jpeg_quality = 12;
  config.fb_count = 1;

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init FAILED (0x%x) — check pin mapping and PSRAM setting.\n", err);
    cameraReady = false;
    return false;
  }
  cameraReady = true;
  Serial.println("Camera initialized.");
  return true;
}

String cameraCaptureAndUpload(const char* eventType) {
  if (!cameraReady) { Serial.println("Camera: not initialized, skipping capture."); return ""; }

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) { Serial.println("Camera: capture failed (no frame buffer)."); return ""; }

  String filename = String(DEVICE_ID) + "_" + String((long)millis()) + ".jpg";
  String uploadPath = "/storage/v1/object/incident-media/" + filename;

  HTTPClient http;
  http.begin(String(SUPABASE_URL) + uploadPath);
  http.addHeader("Content-Type", "image/jpeg");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  int code = http.POST(fb->buf, fb->len);
  esp_camera_fb_return(fb);

  if (code < 200 || code >= 300) {
    Serial.printf("Camera: upload failed, HTTP %d\n", code);
    http.end();
    return "";
  }
  http.end();

  String publicUrl = String(SUPABASE_URL) + "/storage/v1/object/public/incident-media/" + filename;

  String eventBody = "{";
  eventBody += "\"device_id\":\"" + String(DEVICE_ID) + "\",";
  eventBody += "\"record_key\":\"" + filename + "\",";
  eventBody += "\"event_type\":\"" + String(eventType) + "\",";
  eventBody += "\"snapshot_url\":\"" + publicUrl + "\"";
#if ENABLE_PTZ
  eventBody += ",\"pan_at_capture\":" + String(ptzPanDeg, 1) + ",\"tilt_at_capture\":" + String(ptzTiltDeg, 1);
#endif
  eventBody += "}";
  bool supabaseCameraEventOk = postToSupabase("/rest/v1/camera_events", eventBody);
#if ENABLE_MYSQL_HISTORY
  bool mysqlCameraEventOk = postMirrorToMysql("camera_events", filename, eventBody);
  if (!supabaseCameraEventOk || !mysqlCameraEventOk) {
    Serial.printf("Camera event dual-save pending: Supabase=%d MySQL=%d\n", supabaseCameraEventOk, mysqlCameraEventOk);
  }
#endif

  Serial.println("Camera: uploaded snapshot — " + publicUrl);
  return publicUrl;
}

// ── Live MJPEG video stream, served directly by the device ────────
// This is REAL live video — unlike the snapshot function above, a
// client that opens http://<device-ip>:81/stream sees a continuously
// updating image. It only works over the local Wi-Fi network the
// device is on (Supabase has no role here at all — this bypasses it
// entirely, which is the only way genuine live video works with this
// architecture). Browsers, VLC, and most camera-viewer apps handle
// multipart/x-mixed-replace MJPEG natively.
httpd_handle_t streamServer = NULL;

static esp_err_t stream_handler(httpd_req_t *req) {
  camera_fb_t *fb = NULL;
  esp_err_t res = ESP_OK;
  char part_buf[64];
  static const char *STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=frame";
  static const char *STREAM_BOUNDARY = "\r\n--frame\r\n";
  static const char *STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

  res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;

  while (true) {
    fb = esp_camera_fb_get();
    if (!fb) {
      res = ESP_FAIL;
    } else {
      size_t hlen = snprintf(part_buf, 64, STREAM_PART, fb->len);
      res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
      if (res == ESP_OK) res = httpd_resp_send_chunk(req, part_buf, hlen);
      if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
      esp_camera_fb_return(fb);
    }
    if (res != ESP_OK) break; // client disconnected — stop this stream
  }
  return res;
}

void startCameraStreamServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 81;
  config.ctrl_port = 32768; // avoid clashing with the audio server's control port below

  httpd_uri_t stream_uri = {
    .uri = "/stream", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL
  };

  if (httpd_start(&streamServer, &config) == ESP_OK) {
    httpd_register_uri_handler(streamServer, &stream_uri);
    Serial.println("Camera: live stream at http://" + WiFi.localIP().toString() + ":81/stream");
  } else {
    Serial.println("Camera: failed to start stream server.");
  }
}
#endif

