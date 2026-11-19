# PyroGuard complete-project assembly — 2026-10-30

This archive combines the latest supplied clean dual-controller Flutter source package with the platform folders and `pubspec.lock` from the user's original PyroGuard(7).zip. `pubspec.yaml` is byte-for-byte identical between the two sources.

Included: lib, assets, tests, original web/android/ios/linux/macos/windows runners, pubspec.yaml, original pubspec.lock, and other non-generated project configuration/source files.

Excluded: .git, .dart_tool, build, Gradle caches, browser profile data, generated binaries, and potential secrets/keystores. If your local build uses excluded secrets or signing configuration, retain them securely on your machine.

This is a complete SOURCE package (not a prebuilt APK). `flutter pub get`, `flutter analyze`, `flutter test`, and actual platform builds have NOT been run because Flutter/Dart are unavailable in this execution environment. The previous source edits, database ingestion, and live hardware remain unverified.

To validate on your Windows PC (project root):
  flutter doctor -v
  flutter pub get
  flutter analyze
  flutter test
  flutter build web --release
  flutter build apk --debug

The existing Supabase sensor tables were empty for ESP32-001/ESP32-002 in the last user verification; this Flutter package cannot change that. Check firmware plus deployed sensor-ingest Edge Function and record persistence separately. Do not insert fake data into safety monitoring.

IMPORTANT: Compare against local working project before replacing source, especially if you edited it since the uploaded archives.
