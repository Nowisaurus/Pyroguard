#pragma once
// Security commands are idempotent. Unsupported physical sensors are never
// acknowledged as applied. Fire/smoke sensing stays active in every arm mode.
#include <ArduinoJson.h> // ArduinoJson 6.x
String securityArmMode = "DISARMED";
bool securityMotionEnabled = true;
unsigned long lastSecurityPollMs = 0;

bool securityPost(const String &body, String &response) {
  HTTPClient http;
  http.setTimeout(5000);
  http.begin(String(SUPABASE_URL) + "/functions/v1/device-command");
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", SUPABASE_ANON_KEY);
  http.addHeader("Authorization", String("Bearer ") + SUPABASE_ANON_KEY);
  http.addHeader("x-device-key", HISTORY_DEVICE_KEY);
  int code = http.POST(body);
  response = http.getString();
  http.end();
  return code >= 200 && code < 300;
}

void securityPoll() {
  if (WiFi.status() != WL_CONNECTED || String(HISTORY_DEVICE_KEY) == "CHANGE_ME" ||
      millis() - lastSecurityPollMs < 2000) return;
  lastSecurityPollMs = millis();
  StaticJsonDocument<256> request;
  request["action"] = "sync"; request["device_id"] = DEVICE_ID;
  String body, response; serializeJson(request, body);
  if (!securityPost(body, response)) return;
  DynamicJsonDocument reply(16384);
  if (deserializeJson(reply, response) || !(reply["ok"] | false)) return;
  if (reply["state"].is<JsonObject>()) {
    String mode = reply["state"]["arm_mode"] | "";
    if (mode == "DISARMED" || mode == "ARM_HOME" || mode == "ARM_AWAY") securityArmMode = mode;
#if ENABLE_PIR
    if (reply["state"]["motion_enabled"].is<bool>()) securityMotionEnabled = reply["state"]["motion_enabled"].as<bool>();
#endif
  }
  for (JsonObject command : reply["commands"].as<JsonArray>()) {
    String kind = command["command"] | "";
    JsonObject payload = command["payload"].as<JsonObject>();
    bool applied = false;
    String message = "Unsupported command or sensor not wired in this firmware";
    if (kind == "SET_SECURITY_MODE") {
      String mode = payload["arm_mode"] | "";
      if (mode == "DISARMED" || mode == "ARM_HOME" || mode == "ARM_AWAY") {
        securityArmMode = mode;
        applied = true;
        message = "Security mode applied; this firmware gates PIR motion only. Door/window hardware is not implemented. Fire sensing remains active.";
      }
    } else if (kind == "ENABLE_MOTION" || kind == "DISABLE_MOTION") {
#if ENABLE_PIR
      securityMotionEnabled = kind == "ENABLE_MOTION";
      applied = true; message = "PIR motion protection updated";
#endif
    }
    request.clear();
    request["action"] = "ack"; request["device_id"] = DEVICE_ID;
    request["command_id"] = command["id"].as<long>();
    request["status"] = applied ? "applied" : "failed";
    // Larger acknowledgement document retains the full actual result message.
    DynamicJsonDocument acknowledgement(1024);
    acknowledgement.set(request);
    acknowledgement["message"] = message;
    body = ""; serializeJson(acknowledgement, body);
    if (!securityPost(body, response)) {
      Serial.println("Security acknowledgement pending; command will retry");
      break;
    }
  }
}
