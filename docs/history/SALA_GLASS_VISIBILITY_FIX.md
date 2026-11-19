# Sala Glass Visibility Fix

This update targets the reason the phoenix was washed out behind the shared workspace cards: backdrop blur, not just fill opacity.

- GlassPanel default backdrop blur lowered from 18 to 1.5.
- Light workspace card/material opacity is 0.10; room sensor inner tiles and support surfaces use the same pale tint.
- The phoenix overlay wash is reduced and artwork visibility increased slightly.
- Solid sidebar/menu styling and safety overlays remain unchanged.
- No Supabase/MySQL migrations or device logic changes.

Check admin Overview, Devices, Support tickets, Homeowner Overview, Settings, Camera, and dialogs at multiple widths. Custom widgets with explicitly painted backgrounds may still differ and must be evaluated individually.

Run flutter pub get, flutter analyze, flutter run -d chrome on a machine with Flutter installed.
