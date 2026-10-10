/*
  ptz_module.h — Pan/Tilt servos, joystick commands, named presets
  ================================================================
  Only included when ENABLE_PTZ is 1 in pyroguard_esp32s3.ino.
  Requires "ESP32Servo" and "ArduinoJson" v6.x (NOT v7 — this file
  uses DynamicJsonDocument, which v7 removed).

  HOW IT WORKS: the Flutter app's joystick writes a row into
  ptz_commands in Supabase; this file polls that table every couple
  of seconds, moves the servos, and reports position back via
  ptz_state. That's polling, not push — expect 1-3s of lag, not
  instant response. Named presets (HOME/PRESET1/2/3) move to fixed
  angles you can edit in PTZ_PRESETS below.

  WIRING
    Pan servo  signal → ESP32-S3 PIN_SERVO_PAN  (main .ino)
    Tilt servo signal → ESP32-S3 PIN_SERVO_TILT
  Servos need their OWN 5V supply — don't power them from the
  ESP32's rail, it can't supply enough current.

  ⚠️ These pins collide with camera_module.h's data pins if
  ENABLE_CAMERA is also on — see the pin table in README.md.
  ================================================================
*/
#pragma once

#if ENABLE_PTZ
// Named preset positions (degrees). Adjust to whatever angles are
// actually useful for your camera's mounting.
struct Preset { const char* name; float pan; float tilt; };
const Preset PTZ_PRESETS[] = {
  {"HOME",    90, 90},
  {"PRESET1", 45, 90},
  {"PRESET2", 135, 90},
  {"PRESET3", 90, 45},
};
const int PTZ_PRESET_COUNT = 4;

void ptzInit() {
  panServo.attach(PIN_SERVO_PAN);
  tiltServo.attach(PIN_SERVO_TILT);
  panServo.write((int)ptzPanDeg);
  tiltServo.write((int)ptzTiltDeg);
}

bool ptzFetchPendingCommand(DynamicJsonDocument& doc) {
  HTTPClient http;
  String url = String(SUPABASE_URL) +
      "/rest/v1/ptz_commands?device_id=eq." + String(DEVICE_ID) +
      "&status=eq.created&order=created_at.asc&limit=1";
  http.begin(url);
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  int code = http.GET();
  if (code != 200) { http.end(); return false; }
  String payload = http.getString();
  http.end();
  DeserializationError err = deserializeJson(doc, payload);
  if (err) { Serial.println("PTZ: JSON parse failed: " + String(err.c_str())); return false; }
  return doc.size() > 0;
}

void ptzMarkStatus(long commandId, const char* status) {
  String path = "/rest/v1/ptz_commands?id=eq." + String(commandId);
  String body = String("{\"status\":\"") + status + "\"}";
  HTTPClient http;
  http.begin(String(SUPABASE_URL) + path);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("Prefer", "return=minimal");
  http.PATCH(body);
  http.end();
  postMirrorToMysql("ptz_command_status", String(commandId), body);
}

bool cachedAutoTracking = false;
unsigned long lastAutoTrackCheckMs = 0;

void ptzReportState(bool moving) {
  String body = "{";
  body += "\"device_id\":\"" + String(DEVICE_ID) + "\",";
  body += "\"pan_position\":" + String(ptzPanDeg, 1) + ",";
  body += "\"tilt_position\":" + String(ptzTiltDeg, 1) + ",";
  body += "\"moving\":" + String(moving ? "true" : "false") + ",";
  body += "\"auto_tracking\":" + String(cachedAutoTracking ? "true" : "false") + ",";
  body += "\"pan_angle\":" + String((int)ptzPanDeg) + ",";
  body += "\"tilt_angle\":" + String((int)ptzTiltDeg);
  body += "}";
  HTTPClient http;
  http.begin(String(SUPABASE_URL) + "/rest/v1/ptz_state");
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("Prefer", "resolution=merge-duplicates,return=minimal");
  http.POST(body);
  http.end();
  postMirrorToMysql("ptz_state", String(DEVICE_ID), body);
}

void ptzMoveTo(float pan, float tilt) {
  ptzPanDeg = constrain(pan, 0, 180);
  ptzTiltDeg = constrain(tilt, 0, 180);
  panServo.write((int)ptzPanDeg);
  tiltServo.write((int)ptzTiltDeg);
}

// Reads ptz_state.auto_tracking so PIR-triggered movement only
// happens when the app's "PIR Auto-Tracking" switch (Camera screen)
// is actually on. Cached for a few seconds so a burst of PIR
// triggers doesn't hammer Supabase with a GET per motion event.
bool ptzAutoTrackingEnabled() {
  if (millis() - lastAutoTrackCheckMs < 5000) return cachedAutoTracking;
  lastAutoTrackCheckMs = millis();

  HTTPClient http;
  String url = String(SUPABASE_URL) + "/rest/v1/ptz_state?device_id=eq." + String(DEVICE_ID) + "&select=auto_tracking";
  http.begin(url);
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  int code = http.GET();
  if (code == 200) {
    String payload = http.getString();
    cachedAutoTracking = payload.indexOf("\"auto_tracking\":true") != -1;
  }
  http.end();
  return cachedAutoTracking;
}

void ptzApplyCommand(JsonObject cmd) {
  const char* mode = cmd["mode"] | "manual";
  long id = cmd["id"] | 0;
  lastManualPtzMs = millis(); // any real command counts as manual activity

  if (strcmp(mode, "home") == 0) {
    ptzMoveTo(90, 90);
  } else if (strcmp(mode, "stop") == 0) {
    // no position change, just acknowledge
  } else if (strcmp(mode, "preset") == 0) {
    const char* presetName = cmd["preset_name"] | "HOME";
    bool found = false;
    for (int i = 0; i < PTZ_PRESET_COUNT; i++) {
      if (strcmp(PTZ_PRESETS[i].name, presetName) == 0) {
        ptzMoveTo(PTZ_PRESETS[i].pan, PTZ_PRESETS[i].tilt);
        found = true;
        break;
      }
    }
    if (!found) Serial.println("PTZ: unknown preset name: " + String(presetName));
  } else {
    float pan  = cmd["pan"]  | 0.0;
    float tilt = cmd["tilt"] | 0.0;
    ptzMoveTo(90 + (pan * 90.0), 90 + (tilt * 90.0));
  }

  if (id != 0) ptzMarkStatus(id, "executed");
  ptzReportState(false);
}

void ptzPoll() {
  unsigned long now = millis();
  if (now - lastPtzPoll < PTZ_POLL_INTERVAL_MS) return;
  lastPtzPoll = now;

  DynamicJsonDocument doc(1024);
  if (!ptzFetchPendingCommand(doc)) return;
  JsonArray arr = doc.as<JsonArray>();
  if (arr.size() == 0) return;
  ptzApplyCommand(arr[0].as<JsonObject>());
}
#endif

