/*
  gsm_module.h — SIM800L autonomous SMS + voice call
  ================================================================
  Only included when ENABLE_GSM is 1 in pyroguard_esp32s3.ino.

  WIRING
    SIM800L TX  → ESP32-S3 GSM_RX_PIN (defined in the main .ino)
    SIM800L RX  → ESP32-S3 GSM_TX_PIN
    SIM800L VCC → its own regulator, NOT the ESP32 board's rail —
                  SIM800L can spike to ~2A during transmission,
                  which most 3.3V/USB rails cannot supply. This is
                  the #1 reason these modules "don't respond."
    SIM800L GND → ESP32-S3 GND (shared ground required)
  Needs a SIM card with SMS + voice enabled, unlocked, with signal.
  ================================================================
*/
#pragma once

#if ENABLE_GSM
bool gsmWaitFor(const char* expected, unsigned long timeoutMs = 3000) {
  String resp = "";
  unsigned long start = millis();
  while (millis() - start < timeoutMs) {
    while (gsmSerial.available()) resp += (char)gsmSerial.read();
    if (resp.indexOf(expected) != -1) return true;
  }
  Serial.println("GSM: timed out waiting for \"" + String(expected) + "\". Got: " + resp);
  return false;
}

void gsmInit() {
  gsmSerial.begin(9600, SERIAL_8N1, GSM_RX_PIN, GSM_TX_PIN);
  delay(3000);
  gsmSerial.println("AT");
  gsmReady = gsmWaitFor("OK", 2000);
  if (!gsmReady) {
    Serial.println("GSM: no response — check wiring and POWER SUPPLY (SIM800L needs its own regulator, ~2A peak).");
    return;
  }
  gsmSerial.println("AT+CMGF=1");
  gsmWaitFor("OK");
  Serial.println("GSM: initialized.");
}

bool gsmSendSms(const String& number, const String& message) {
  if (!gsmReady) { Serial.println("GSM: not ready, skipping SMS."); return false; }
  gsmSerial.print("AT+CMGS=\""); gsmSerial.print(number); gsmSerial.println("\"");
  if (!gsmWaitFor(">", 3000)) return false;
  gsmSerial.print(message);
  gsmSerial.write(0x1A);
  bool ok = gsmWaitFor("+CMGS", 10000);
  Serial.println(ok ? "GSM: SMS sent to " + number : "GSM: SMS FAILED to " + number);
  return ok;
}

bool gsmCall(const String& number, int ringSeconds = 25) {
  if (!gsmReady) { Serial.println("GSM: not ready, skipping call."); return false; }
  gsmSerial.print("ATD"); gsmSerial.print(number); gsmSerial.println(";");
  bool dialed = gsmWaitFor("OK", 5000);
  if (dialed) {
    delay(ringSeconds * 1000);
    gsmSerial.println("ATH");
    gsmWaitFor("OK", 2000);
  }
  return dialed;
}
#endif

