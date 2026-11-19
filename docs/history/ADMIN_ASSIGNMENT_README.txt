PYROGUARD ADMIN ASSIGNMENT + ANALYTICS

1. Back up the project and database.
2. SQL Editor: run the earlier 20261031_admin_ticket_integrity.sql first.
3. Then run database/migrations/20261031_admin_assignment_visibility.sql.
4. Confirm no other permissive SELECT policies for support_tickets, support_ticket_messages, support_ticket_events bypass these restrictions. In Supabase: Database > Policies.
5. flutter pub get; flutter analyze; flutter run -d chrome.
6. Test head developer assigns an unassigned ticket to each of the active administrator accounts.
7. Log in as admin A: verify only tickets assigned to A appear. Log in as admin B: verify A's tickets cannot be accessed by querying ID; check messages/events too.
8. Homeowner still sees tickets they submitted; internal messages must remain hidden from them.
9. Confirm ticket saved status/priority and events after reload. Verify the head's totals versus admin's own queue.
10. Verify graphs reflect actual backend data, not device health unless explicitly measured. Device registration is not device uptime.

LIMITATIONS: Existing admin-console Edge Function may independently return users/devices/events to all admins; review its server permissions separately. Graphs summarize currently loaded rows and can be incomplete if the function paginates. The migration must be executed against live Supabase. The project has not been compiled in this environment.
