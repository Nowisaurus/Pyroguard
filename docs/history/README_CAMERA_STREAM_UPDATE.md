# PyroGuard Flutter camera streaming update

This source update is intended to be merged into the existing PyroGuard Flutter project.
Copy `lib/` into the existing project, preserving the rest of the project, then run
`flutter pub get`, `flutter analyze`, and test on the actual target platform.

## What changed

- Camera dashboard previews and individual camera pages prefer the continuous
  `http://CAMERA_IP:81/stream` MJPEG feed instead of a 3-second JPEG slideshow.
- `/capture` polling remains as a fallback for a camera without the MJPEG endpoint.
- Each displayed camera uses its own stream client, frame buffer, IP candidates,
  disconnect recovery, and lifecycle cleanup.
- Only the newest completed JPEG is displayed, with a modest repaint throttle.
- UI labels use `Microservo` instead of `MG996R`; physical GPIO
  assignments have not been changed.
- PTZ services now use the actual `ptz_state` and `ptz_commands` tables,
  checking `last_device_at` and `hardware_ready` before allowing movement.

## Camera configuration

- Camera 1 fallback: `192.168.8.99`, device `pyroguard_camera_001`.
- Camera 2: independent IP required; device `pyroguard_camera_002`.
- Camera stream: port `81`, endpoint `/stream`.
- Camera status and JPEG fallback: port `80`, `/status` and `/capture`.

## Supabase verification (requires a signed-in environment)

Source references checked: `pyroguard_camera_registry`,
`pyroguard_camera_telemetry`, `device_heartbeats`,
`ptz_commands`, and `ptz_state`.

These APIs and policies must exist in the deployed Supabase project and allow
the correct authenticated owner to access their own records. This source-only
update does not deploy database migrations or Edge Functions. It also does not
prove a physical device successfully posts heartbeats or acknowledges commands.

**Check device ID mapping:** registered controllers are `ESP32-001` and
`ESP32-002`, and `ptz_state.device_id` uses a camera ID. PTZ command requests
therefore target `pyroguard_camera_001` or `pyroguard_camera_002`. Verify that
each controller's actual firmware/worker consumes the appropriate camera-scoped
`ptz_commands` rows and writes acknowledgments. A database row alone does not
prove physical motion.

## Tests to perform

1. Run `flutter analyze` and resolve any environment-specific package issues.
2. Open both dashboard previews and verify frames change continuously.
3. Open each camera's detail screen and verify smooth movement and overlays.
4. Disconnect/reconnect Camera 1 Wi-Fi and observe stream recovery.
5. Test Camera 2 without a stream endpoint: snapshot fallback should work.
6. Verify PTZ commands reach the intended controller and get hardware ACKs.
7. Check Supabase camera registry and heartbeat timestamps after hardware boots.

No existing tutorials, onboarding, screens, navigation, or unrelated data were removed.
