# Real-data dashboard audit

The dashboard displays only Supabase-returned records and existing live telemetry timestamps. No hardcoded statistics or synthetic time-series data are used.

IMPORTANT: The current admin-console Edge Function limits events, devices, pending mirror records and pending ledger records to 100 returned rows per source. Therefore loaded events/alerts and trend lines are **not comprehensive historical totals**. `+` indicators mean the backend result might be incomplete. The charts deliberately show no verified data when their load fails. Ticket counts are limited by RLS permissions (head sees more; other admins only assigned work).

For complete all-time analytical totals, implement server-side aggregate RPCs/views scoped by administrator permissions, plus time-bucketed COUNT(*) queries over event_history, support_tickets and device heartbeats, and deploy them to Supabase. This ZIP does not claim complete history or successful live database integration.

Run flutter analyze and live tests after extracting. No Flutter SDK is installed in the editing environment.
