/*
  pir_module.h — 3-sensor coarse LEFT/CENTER/RIGHT tracking
  ================================================================
  Only included when ENABLE_PIR is 1 in pyroguard_esp32s3.ino.

  Honest scope note, please read before wiring this up: a single PIR
  sensor can only tell you THAT something moved, never WHERE — there
  is no direction information in one digital motion pin. True visual
  tracking (the camera following a specific moving subject smoothly)
  needs a real computer-vision pipeline analyzing the video frame,
  which is a substantially bigger, separate project from this
  firmware. What IS built here, and is a genuinely real technique
  (not a stand-in): three separate PIR sensors mounted to the left,
  center, and right of the camera. Whichever one fires tells the
  firmware roughly which direction the motion is on, and — only if
  ENABLE_PTZ is also on AND auto_tracking is turned on for this
  device (the "PIR Auto-Tracking" switch in the app's Camera screen)
  — it pans a fixed step toward that side. This is coarse 3-zone
  following, not smooth per-pixel tracking of a subject.

  Respects manual override: if the joystick was used in the last 10
  seconds, PIR-triggered movement is skipped so a human's manual
  control always wins.

  WIRING
    Left/Center/Right sensor OUT → PIN_PIR_LEFT/CENTER/RIGHT (main .ino)
  ⚠️ GPIO 35-37 (the defaults) may be reserved for PSRAM on "octal
  PSRAM" ESP32-S3 boards — common on N8R8/N16R8 dev boards. Check
  your board's datasheet before enabling this alongside the camera.
  ================================================================
*/
#pragma once

#if ENABLE_PIR
void pirCheck() {
  bool left   = digitalRead(PIN_PIR_LEFT)   == HIGH;
  bool center = digitalRead(PIN_PIR_CENTER) == HIGH;
  bool right  = digitalRead(PIN_PIR_RIGHT)  == HIGH;
  bool motionNow = left || center || right;

  if (motionNow && !pirLastState && securityMotionEnabled && securityArmMode == "ARM_AWAY") {
    Serial.printf("PIR: motion detected (L=%d C=%d R=%d)\n", left, center, right);
#if ENABLE_CAMERA
    cameraCaptureAndUpload("motion");
#endif
#if ENABLE_PTZ
    bool manualRecently = (millis() - lastManualPtzMs) < 10000;
    if (!manualRecently && ptzAutoTrackingEnabled()) {
      const float STEP_DEG = 25.0;
      if (left && !center) {
        ptzMoveTo(constrain(ptzPanDeg - STEP_DEG, 0, 180), ptzTiltDeg);
        ptzReportState(false);
      } else if (right && !center) {
        ptzMoveTo(constrain(ptzPanDeg + STEP_DEG, 0, 180), ptzTiltDeg);
        ptzReportState(false);
      }
      // center-only: subject is already roughly framed, no move needed
    }
#endif
  }
  pirLastState = motionNow;
}
#endif

