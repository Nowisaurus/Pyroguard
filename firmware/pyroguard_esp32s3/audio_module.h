/*
  audio_module.h — Live one-way audio stream + recorded evidence clip
  ================================================================
  Only included when ENABLE_AUDIO is 1 in pyroguard_esp32s3.ino.
  No extra library needed — driver/i2s.h and esp_http_server.h ship
  with the ESP32 core.

  TWO THINGS THIS FILE DOES:
  1. audioRecordAndUpload() — records a short clip and uploads it as
     evidence on a confirmed fire.
  2. A live audio stream at http://<device-ip>:82/audio — real,
     one-direction (device mic → listener), local Wi-Fi network only.

  ⚠️ Talking BACK to the device (app mic → device speaker) is NOT
  built — that direction needs the Flutter app to continuously
  capture and upload audio, separate and larger work. The live
  stream here is also more experimental than the video one — WAV
  wasn't designed for unknown-length streaming; if a player is
  flaky, try a browser or VLC first.

  WIRING (I2S microphone — INMP441)
    SD  → ESP32-S3 I2S_MIC_SD  (main .ino)
    WS  → ESP32-S3 I2S_MIC_WS
    SCK → ESP32-S3 I2S_MIC_SCK
    L/R → GND (selects left channel)
    VDD → 3.3V, GND → GND
  ================================================================
*/
#pragma once

#if ENABLE_AUDIO
bool audioInit() {
  i2s_config_t cfg = {
    .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = AUDIO_SAMPLE_RATE,
    .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = I2S_COMM_FORMAT_STAND_I2S,
    .intr_alloc_flags = 0,
    .dma_buf_count = 4,
    .dma_buf_len = 1024,
    .use_apll = false,
  };
  i2s_pin_config_t pins = {
    .bck_io_num = I2S_MIC_SCK, .ws_io_num = I2S_MIC_WS,
    .data_out_num = I2S_PIN_NO_CHANGE, .data_in_num = I2S_MIC_SD,
  };
  if (i2s_driver_install(I2S_PORT, &cfg, 0, NULL) != ESP_OK) { Serial.println("Audio: driver install failed."); return false; }
  if (i2s_set_pin(I2S_PORT, &pins) != ESP_OK) { Serial.println("Audio: set_pin failed."); return false; }
  audioReady = true;
  Serial.println("Audio: I2S mic ready.");
  return true;
}

void writeWavHeader(uint8_t* buf, size_t dataSize, int sampleRate, int channels, int bitsPerSample) {
  size_t fileSize = dataSize + 36;
  int byteRate = sampleRate * channels * bitsPerSample / 8;
  int blockAlign = channels * bitsPerSample / 8;
  memcpy(buf, "RIFF", 4);
  *(uint32_t*)(buf + 4) = fileSize;
  memcpy(buf + 8, "WAVEfmt ", 8);
  *(uint32_t*)(buf + 16) = 16;
  *(uint16_t*)(buf + 20) = 1;
  *(uint16_t*)(buf + 22) = channels;
  *(uint32_t*)(buf + 24) = sampleRate;
  *(uint32_t*)(buf + 28) = byteRate;
  *(uint16_t*)(buf + 32) = blockAlign;
  *(uint16_t*)(buf + 34) = bitsPerSample;
  memcpy(buf + 36, "data", 4);
  *(uint32_t*)(buf + 40) = dataSize;
}

String audioRecordAndUpload() {
  if (!audioReady) { Serial.println("Audio: not initialized, skipping."); return ""; }

  const int bytesPerSample = 4;
  const size_t pcmBytes = (size_t)AUDIO_BUFFER_SAMPLES * bytesPerSample;
  int32_t* pcmBuf = (int32_t*)malloc(pcmBytes);
  if (!pcmBuf) { Serial.println("Audio: OOM (record buffer)."); return ""; }

  size_t bytesRead = 0;
  i2s_read(I2S_PORT, pcmBuf, pcmBytes, &bytesRead, portMAX_DELAY);

  int16_t* pcm16 = (int16_t*)malloc(AUDIO_BUFFER_SAMPLES * 2);
  if (!pcm16) { free(pcmBuf); Serial.println("Audio: OOM (downconvert buffer)."); return ""; }
  for (int i = 0; i < AUDIO_BUFFER_SAMPLES; i++) pcm16[i] = (int16_t)(pcmBuf[i] >> 14);
  free(pcmBuf);

  size_t dataSize = AUDIO_BUFFER_SAMPLES * 2;
  size_t wavSize = 44 + dataSize;
  uint8_t* wav = (uint8_t*)malloc(wavSize);
  if (!wav) { free(pcm16); Serial.println("Audio: OOM (WAV buffer)."); return ""; }

  writeWavHeader(wav, dataSize, AUDIO_SAMPLE_RATE, 1, 16);
  memcpy(wav + 44, pcm16, dataSize);
  free(pcm16);

  String filename = String(DEVICE_ID) + "_" + String((long)millis()) + ".wav";
  String uploadPath = "/storage/v1/object/ptt-audio/" + filename;

  HTTPClient http;
  http.begin(String(SUPABASE_URL) + uploadPath);
  http.addHeader("Content-Type", "audio/wav");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  int code = http.POST(wav, wavSize);
  free(wav);

  if (code < 200 || code >= 300) { Serial.printf("Audio: upload failed, HTTP %d\n", code); http.end(); return ""; }
  http.end();

  String publicUrl = String(SUPABASE_URL) + "/storage/v1/object/public/ptt-audio/" + filename;
  String body = "{\"device_id\":\"" + String(DEVICE_ID) + "\",\"record_key\":\"" + filename + "\",\"direction\":\"from_device\",\"clip_url\":\"" + publicUrl + "\"}";
  bool supabaseAudioOk = postToSupabase("/rest/v1/audio_sessions", body);
#if ENABLE_MYSQL_HISTORY
  bool mysqlAudioOk = postMirrorToMysql("audio_sessions", filename, body);
  if (!supabaseAudioOk || !mysqlAudioOk) {
    Serial.printf("Audio metadata dual-save pending: Supabase=%d MySQL=%d\n", supabaseAudioOk, mysqlAudioOk);
  }
#endif

  Serial.println("Audio: uploaded clip — " + publicUrl);
  return publicUrl;
}

// ── Live audio stream, served directly by the device ───────────────
// Genuinely real-time, one direction (device → listener), over the
// local Wi-Fi network only — same "bypasses Supabase entirely"
// architecture as the video stream above. Streams raw 16-bit PCM
// wrapped in a WAV header with a deliberately oversized data-length
// field (a common trick for "unknown length" streaming WAV), so a
// player just keeps consuming audio as it arrives instead of waiting
// for a file to finish. This is more experimental than the video
// stream — WAV wasn't designed for infinite streams, and not every
// player handles it gracefully. If it's flaky in your player of
// choice, opening the URL directly in a browser's <audio> tag or in
// VLC are the most likely to work.
// Talking BACK to the device (app → speaker) is still NOT built —
// see the top-of-file notes; that direction still needs the
// app to continuously capture and upload audio, which is a separate,
// larger piece of Flutter-side work.
httpd_handle_t audioServer = NULL;

static esp_err_t audio_stream_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "audio/wav");

  uint8_t header[44];
  writeWavHeader(header, 0x7FFFFFFF, AUDIO_SAMPLE_RATE, 1, 16); // oversized "unknown length"
  esp_err_t res = httpd_resp_send_chunk(req, (const char *)header, 44);

  const int CHUNK_SAMPLES = 1024;
  int32_t raw[CHUNK_SAMPLES];
  int16_t pcm[CHUNK_SAMPLES];

  while (res == ESP_OK) {
    size_t bytesRead = 0;
    i2s_read(I2S_PORT, raw, sizeof(raw), &bytesRead, portMAX_DELAY);
    int n = bytesRead / 4;
    for (int i = 0; i < n; i++) pcm[i] = (int16_t)(raw[i] >> 14);
    res = httpd_resp_send_chunk(req, (const char *)pcm, n * 2);
    if (res != ESP_OK) break; // client disconnected
  }
  return res;
}

void startAudioStreamServer() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 82;
  config.ctrl_port = 32769;

  httpd_uri_t audio_uri = {
    .uri = "/audio", .method = HTTP_GET, .handler = audio_stream_handler, .user_ctx = NULL
  };

  if (httpd_start(&audioServer, &config) == ESP_OK) {
    httpd_register_uri_handler(audioServer, &audio_uri);
    Serial.println("Audio: live stream at http://" + WiFi.localIP().toString() + ":82/audio");
  } else {
    Serial.println("Audio: failed to start stream server.");
  }
}
#endif

