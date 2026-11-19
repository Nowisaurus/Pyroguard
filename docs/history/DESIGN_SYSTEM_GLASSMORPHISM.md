# PyroGuard unified glass design

## Design tokens
- Light backgrounds: warm ivory / cream; panels are frosted warm-white with soft orange outlines.
- Dark backgrounds: near-black and maroon-tinted glass; cream-white foreground text.
- Brand accents: existing maroon, red, burnt orange. Red is reserved for critical/fire alerts; amber is reserved for warning/stale; green for verified healthy.
- Common cards: `GlassPanel` and `GlassStyle.card` in `lib/theme.dart`.
- Material cards, input fields, and dialogs inherit the updated shared theme.
- Keep indicators based on actual Supabase telemetry, never demo readings.

## Scope and limits
This is a cross-application shared styling update; it does **not** rewrite custom feature-specific layouts that bypass shared components. Do not replace safety-related colors with generic glass accents.
Existing backend, camera, login, tutorials, navigation, MySQL sync worker and migrations are preserved. No database migration is needed for styling.

## Validate
Run `flutter analyze`, `flutter run -d chrome`, and manually inspect Admin, Homeowner, Rooms, Cameras, Tickets, Alerts, Settings, login/onboarding at desktop and mobile widths.
