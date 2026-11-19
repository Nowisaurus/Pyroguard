-- RUN IN MYSQL WORKBENCH AFTER selecting the PyroGuard database.
-- READ ONLY. Zero missing rows means the specified fields exist.
USE pyroguard_db;
WITH required AS (
 SELECT 'pyroguard_support_tickets' AS table_name,'id' AS column_name UNION ALL
 SELECT 'pyroguard_support_tickets','title' UNION ALL
 SELECT 'pyroguard_support_tickets','severity' UNION ALL
 SELECT 'pyroguard_support_tickets','status' UNION ALL
 SELECT 'pyroguard_support_tickets','assigned_to' UNION ALL
 SELECT 'pyroguard_support_tickets','archived_at' UNION ALL
 SELECT 'pyroguard_support_tickets','archived_by' UNION ALL
 SELECT 'pyroguard_support_tickets','updated_at' UNION ALL
 SELECT 'pyroguard_support_ticket_events','id' UNION ALL
 SELECT 'pyroguard_support_ticket_events','ticket_id' UNION ALL
 SELECT 'pyroguard_support_ticket_events','actor_id' UNION ALL
 SELECT 'pyroguard_support_ticket_events','changes' UNION ALL
 SELECT 'pyroguard_support_ticket_messages','id' UNION ALL
 SELECT 'pyroguard_support_ticket_messages','ticket_id' UNION ALL
 SELECT 'pyroguard_support_ticket_messages','message' UNION ALL
 SELECT 'pyroguard_admin_accounts','user_id' UNION ALL
 SELECT 'pyroguard_admin_accounts','active'
)
SELECT r.table_name,r.column_name,'MISSING IN MYSQL' AS problem FROM required r
LEFT JOIN information_schema.columns c ON c.table_schema=DATABASE()
 AND c.table_name=r.table_name AND c.column_name=r.column_name
WHERE c.column_name IS NULL ORDER BY r.table_name,r.column_name;
