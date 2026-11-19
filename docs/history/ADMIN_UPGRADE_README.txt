PYROGUARD — FULL FLUTTER PROJECT WITH ADMIN UPGRADE

This archive is the complete original PyroGuard Flutter project from sureba.zip,
with the Oct 31 admin upgrade already merged into these files:

  lib/screens/admin/admin_screen.dart
  lib/screens/support/support_tickets_page.dart
  lib/screens/dashboard/device_screen.dart

Plus migration:
  database/migrations/20261031_admin_ticket_integrity.sql

TO INSTALL
1. Back up the existing project and Supabase database.
2. Extract this archive. Open the PyroGuard folder in VS Code.
3. Apply database/migrations/20261031_admin_ticket_integrity.sql using
   Supabase SQL Editor after reviewing the migration for your schema.
4. In the PyroGuard folder execute:
      flutter pub get
      flutter analyze
      flutter run -d chrome
5. Verify head-admin ticket assignment, priority, status, archive, history,
   user permissions, and dashboard after refreshing and signing in again.

IMPORTANT LIMITATIONS
- The Flutter SDK is not available in the packaging environment. This merged
  application has NOT been compiled or tested against your live Supabase.
- The archive INCLUDES full application source, not an APK or compiled binary.
- MySQL mirror schema/worker and every Settings form persistence have not been
  verified; those need separate implementation and testing.
- Ticket archive is designed to preserve audit history rather than permanently
  destroying data.
- Existing unaffected project files were preserved from the user-provided ZIP.
