# PyroGuard persistence verification — 2026-10-31

## Changes included in this full source project
- SettingsService now reads the just-written record from Supabase and checks expected values before declaring a successful save for home, primary stakeholder, safety configuration, notification preferences, appearance, and device registration.
- Profile and BFP saves already performed read-back checks and are retained.
- Existing app, screens, camera services, onboarding and device functions are preserved.
- Existing admin ticket SQL migration in `database/migrations/20261031_admin_ticket_integrity.sql` must be applied manually in Supabase before using ignored/archive actions.

## Important operational limits
A successful Supabase save does not mean the MySQL worker has completed synchronization. MySQL mirroring is asynchronous and errors are currently logged rather than blocking the primary save. Review Database sync in the administrator console and configure the worker to run continuously.

These changes do not prove end-to-end persistence of every form, every Edge Function or every hardware event. They do not add tables or alter RLS for unrelated features. The Flutter SDK and live Supabase services are not available in the packaging environment; compilation, auth/RLS verification, and real device tests are still required.

## Test protocol
1. Back up Supabase and your current project before applying migrations.
2. Run the migration in Supabase SQL Editor and inspect its results.
3. Run `flutter pub get`, `flutter analyze`, and `flutter run -d chrome` in the project directory.
4. Save profile, home, stakeholder, BFP, safety settings, notification preferences and appearance; refresh each screen and sign out/in to verify persistence.
5. For each saved record, inspect the matching Supabase table filtered to the signed-in user's ID.
6. As an administrator, create, assign, prioritize, resolve, ignore and archive test tickets; reload to confirm results and review the ticket audit trail.
7. Verify MySQL worker completion and compare affected rows to Supabase; check pending mirror queue and errors rather than assuming successful replication.
8. Test two distinct users, both ESP32 controllers and both cameras separately. Confirm RLS denies access to unrelated households and non-admin accounts cannot modify administrative records.

Do not deploy to a safety-critical environment until failures, offline states, alert escalation and hardware control acknowledgements have been tested on physical devices.
