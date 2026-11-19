# PyroGuard Admin Dashboard: real-record and heartbeat update

Updated Flutter: `lib/screens/admin/admin_screen.dart`.
Updated Supabase Edge Function: `supabase/functions/admin-console/index.ts`.

## Deployment
1. Back up existing Flutter project and database.
2. Deploy updated admin-console: `supabase functions deploy admin-console` from project root after CLI login/link.
3. Run `flutter pub get`, `dart format lib/screens/admin/admin_screen.dart`, `flutter analyze`, and `flutter run -d chrome`.
4. On local Windows MySQL worker computer, preserve private `.env` in `deployment/local-mysql-sync`; install Node 22+; run `npm ci`, `npm test`, `npm run once`.
5. Compare ticket IDs and new device events across Supabase and MySQL and monitor local worker logs.

## Device Analytics
Uses registered devices (`devices`) AND actual `device_heartbeats` rows, matched by `device_id`. A heartbeat's `updated_at`/`created_at` must be within five minutes of the local clock to be fresh. Registry timestamp alone never establishes online status. If heartbeat data cannot be retrieved or the registered device list is truncated, the donut is unavailable rather than inventing a percentage. This is a *heartbeat freshness indicator*, not proof that MJPEG streaming or sensors work. It does not measure historical uptime.

## Trends
Daily counts are from returned event and ticket records, never generated examples. Lines are straight between samples and are flat at zero when all 14 daily counts are zero and the preview is complete. The event query is capped at 100 and ticket data are RLS scoped; incomplete coverage is called out. Complete historical event analytics requires server-side date aggregation, which is not implemented in this update.

## Sync backlog
Displayed from exact counts returned by the admin-console backend, independently of unrelated admin feed read failures. Unavailable is preferable to a false zero. MySQL correctness still requires running the local worker and matching saved records.

## Limits
No live Flutter SDK, Supabase credentials, MySQL server, or ESP32 hardware was available in this environment. Live deployment, analyzer results, realtime correctness, RLS, and MySQL reconciliation must be verified on your computer. No new schema migration is required for these read-only backend/UI changes.
