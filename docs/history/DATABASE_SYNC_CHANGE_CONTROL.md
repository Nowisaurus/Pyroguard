# PyroGuard database change-control and verification

## Source of truth
Supabase PostgreSQL stores primary application records. The local MySQL worker mirrors records only while reachable and running. A successful Flutter save does **not** establish that the MySQL copy has updated.

## Apply this package safely
1. Back up Supabase and local MySQL. DO NOT rerun whole base schema scripts on live environments without reviewing all operations.
2. Review prior Supabase migrations in `database/migrations/` and apply any not yet deployed in dependency order (ticket integrity, assignment visibility, ticket analytics, verified metrics). Do not assume they were deployed just because they are in the ZIP.
3. Apply `20261031_mysql_ticket_archive_alignment.sql` in MySQL Workbench with the correct database selected. This adds two nullable ticket archive columns without deleting existing data.
4. Run `20261031_supabase_schema_contract_check.sql` in Supabase and `20261031_mysql_schema_contract_check.sql` in MySQL; investigate any missing rows. Supabase RLS policies are listed for manual review.
5. Ensure your existing local MySQL synchronization worker is running and configured, then run the two `ticket_record_reconciliation` scripts; compare counts and corresponding IDs after a completed worker cycle. Counts are NOT proof of matching rows; compare record IDs and timestamps, and inspect worker failures.
6. Deploy updated Edge Functions only if their code has changed. Verify the deployed versions and test under real admin and homeowner accounts.
7. Run `flutter pub get`, `flutter analyze` and functional save/reload tests on your workstation.

## For EVERY future Flutter field or feature
- Define Supabase PostgreSQL migration (columns, constraints, indexes, RLS policies, functions/trigger, backfills if necessary).
- Define corresponding MySQL migration with compatible type and null semantics.
- Update the local mirror worker table config and transformations if the table/key or data shape changes.
- Update Edge Function request/response and authorization; keep secrets server-side.
- Update Flutter reads/writes and errors; test save -> read-back -> admin visibility -> successful MySQL copy.
- Never invent 0 or online/healthy when a query fails; display unavailable/unverified.
- Add a record-level reconciliation check, especially for tickets, archived state, events, sensor data, and user settings.

## Critical observations from the supplied project
- The existing `support_tickets` PostgreSQL base schema has `title`, **not** `subject`.
- Supabase ticket archive migration adds `archived_at` and `archived_by`. Previously the MySQL base table omitted both; this package aligns them.
- Current worker `mirrorRow` skips absent nullable source columns. A schema consistency audit is therefore important to prevent silent loss of newly added fields.
- The current schema check covers ticket-related fields only, NOT a complete live audit of every database table, sensor record, or application form.
- The project includes an administrator visibility migration, but existing permissive RLS policies still require review in your deployed database.
- Do not assume that the MySQL worker is online or synchronized until the reconciliation scripts and worker logs confirm it.
