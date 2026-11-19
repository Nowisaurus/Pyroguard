-- RUN IN SUPABASE SQL EDITOR: read-only ticket counts, based on actual rows.
SELECT 'support_tickets' AS entity, COUNT(*) AS stored_rows FROM public.support_tickets
UNION ALL SELECT 'support_ticket_messages', COUNT(*) FROM public.support_ticket_messages
UNION ALL SELECT 'support_ticket_events',COUNT(*) FROM public.support_ticket_events;
SELECT status,severity,COUNT(*) AS tickets FROM public.support_tickets
GROUP BY status,severity ORDER BY status,severity;
SELECT id,title,status,assigned_to,archived_at,updated_at FROM public.support_tickets
ORDER BY updated_at DESC LIMIT 25;
