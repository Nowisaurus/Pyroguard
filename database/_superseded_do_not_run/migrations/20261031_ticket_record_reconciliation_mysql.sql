-- RUN IN MYSQL WORKBENCH: read-only mirrored ticket counts.
USE pyroguard_db;
SELECT 'support_tickets' AS entity, COUNT(*) AS stored_rows FROM pyroguard_support_tickets
UNION ALL SELECT 'support_ticket_messages',COUNT(*) FROM pyroguard_support_ticket_messages
UNION ALL SELECT 'support_ticket_events',COUNT(*) FROM pyroguard_support_ticket_events;
SELECT status,severity,COUNT(*) AS tickets FROM pyroguard_support_tickets
GROUP BY status,severity ORDER BY status,severity;
SELECT id,title,status,assigned_to,archived_at,updated_at FROM pyroguard_support_tickets
ORDER BY updated_at DESC LIMIT 25;
