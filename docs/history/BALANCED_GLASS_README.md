# Balanced, readable PyroGuard glassmorphism

The shared workspace now uses approximately 35% translucent tint and a backdrop blur of 1.5. Nested room metrics use a slightly lighter peach tint to avoid stacking too many opaque surfaces. Solid navigation/sidebar styling and emergency contrast colors are preserved. No database schema or synchronization logic was changed.

Test from the PyroGuard root:

    flutter pub get
    dart format lib/theme.dart lib/screens/dashboard/room_sensor_panel.dart
    flutter analyze
    flutter run -d chrome

A visual check of custom screens and a live Flutter build remain necessary; this archive was not compiled here.
