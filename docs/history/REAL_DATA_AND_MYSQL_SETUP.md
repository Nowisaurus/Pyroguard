# PyroGuard verified records & MySQL setup

## Source of truth
Supabase is the primary store. The admin-console Edge Function now returns **exact** counts for event_history, devices, and unsynced mirror_records / dual_record_ledger / account_identities. Query errors become null/Unavailable rather than zero. Visible charts still plot loaded preview rows only, not every historical row. Support ticket visibility follows RLS; ticket numbers/graphs are subject to the currently authorized ticket set.

## Deploy changes
1. Back up Supabase and local MySQL.
2. Run `database/migrations/20261031_verified_admin_record_metrics.sql` in Supabase SQL Editor (and previous migrations if not applied).
3. Deploy `supabase/functions/admin-console/index.ts`: `supabase functions deploy admin-console` from project root after logging in/linking the correct Supabase project.
4. Ensure `sync-outbox` is deployed and `SYNC_WORKER_SECRET` configured only in server/worker secrets, never Flutter. To deploy: `supabase functions deploy sync-outbox`.
5. If MySQL lives only on a laptop, start the existing local MySQL sync worker on that laptop with the required connectivity and credentials. Supabase cloud cannot directly connect to local-only MySQL without a secured accessible endpoint or local worker. The dashboard cannot itself guarantee MySQL mirroring.
6. Trigger the existing sync action on the Database Sync admin screen, inspect the outbox result/worker logs, and verify MySQL rows. Do NOT clear outstanding queues until durable MySQL writes are confirmed.

## Verification queries
Supabase SQL Editor (full administrative visibility; admin screen honors authorized access):
```sql
select count(*) from public.event_history;
select count(*) from public.devices;
select count(*) from public.mirror_records where mysql_synced=false;
select count(*) from public.dual_record_ledger where mysql_synced=false;
select count(*) from public.account_identities where mysql_synced=false;
select * from public.pyroguard_ticket_daily_actual(14);
```

On MySQL check `pyroguard_mirror_records`, `pyroguard_dual_record_ledger`, and `pyroguard_source_records` and confirm counts/keys against Supabase. `mysql_synced=true` is an acknowledgement set by existing workers after successful writes; verify worker health and retry failures, especially after outages.

## Not yet verified
No live network access to your database, no Flutter SDK in this runtime, and no running laptop MySQL worker. This update does not prove successful replication, exact device uptime, or complete historical charts. Device health is still based on fresh available heartbeat records; unavailable means unverified, not offline.
