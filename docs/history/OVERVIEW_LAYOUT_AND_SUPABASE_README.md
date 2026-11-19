# PyroGuard Overview layout + Supabase ticket schema correction

## Flutter
- Recorded trends chart occupies a full row.
- Active support tickets is displayed directly beside the Ticket Status donut at desktop width.
- Registered device/system health cards appear beside Device Analytics at desktop width.
- Recent incidents occupy a compact full-width panel below these rows.
- Existing admin tabs, assignments, permissions, device screens and services remain unchanged.
- The ticket query no longer selects `support_tickets.subject`: the existing ticket UI uses `support_tickets.title`.
- Database unavailability is displayed honestly; no fabricated chart data.

## Supabase
The Flutter `subject` column error is fixed client-side; you do NOT need to add a duplicate `subject` column.
Optional SQL migration: `database/migrations/20261031_ticket_analytics_actual_schema.sql` defines a read-only RPC for exact per-user ticket totals under existing RLS. The current dashboard still reads authorized ticket rows directly; the new RPC is a future backend hook, not silently used without testing. Back up database before applying.

To fix ticket visibility, ensure the previously supplied `20261031_admin_assignment_visibility.sql` migration has been reviewed and applied, and no older permissive policies remain. Verify as head developer and regular administrator separately.

## Checks
Run `flutter pub get`, `dart format lib/screens/admin/admin_screen.dart`, `flutter analyze`, `flutter run -d chrome`.
Live Supabase / MySQL and hardware checks were not possible here.
