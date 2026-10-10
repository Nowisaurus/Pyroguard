/*
  gps_module.h — NEO-6M (or similar) GPS
  ================================================================
  Only included when ENABLE_GPS is 1 in pyroguard_esp32s3.ino.
  Requires the "TinyGPS++" library (Arduino Library Manager).

  WIRING
    GPS TX → ESP32-S3 GPS_RX_PIN (defined in the main .ino)
    GPS RX → ESP32-S3 GPS_TX_PIN (optional on most modules)
    GPS VCC/GND → per your module's spec

  A GPS module needs a clear sky view — it will not get a fix
  indoors. gpsHasFix() correctly returns false the whole time it's
  searching; that's the honest state, not a bug.
  ================================================================
*/
#pragma once

#if ENABLE_GPS
void gpsInit() {
  gpsSerial.begin(9600, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
  Serial.println("GPS: listening (fix may take a minute or more outdoors).");
}
void gpsUpdate() {
  while (gpsSerial.available() > 0) gps.encode(gpsSerial.read());
}
bool gpsHasFix() {
  return gps.location.isValid() && gps.location.age() < 10000;
}
#endif

