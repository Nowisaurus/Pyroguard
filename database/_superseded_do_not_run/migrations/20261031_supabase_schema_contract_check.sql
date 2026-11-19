-- RUN IN SUPABASE SQL EDITOR. READ ONLY: returns missing required columns.
-- A zero-row result means these selected ticket fields exist; it does not confirm sync or permissions.
WITH required(table_name,column_name) AS (VALUES
 ('support_tickets','id'),('support_tickets','title'),('support_tickets','severity'),
 ('support_tickets','status'),('support_tickets','assigned_to'),('support_tickets','archived_at'),
 ('support_tickets','archived_by'),('support_tickets','updated_at'),
 ('support_ticket_events','id'),('support_ticket_events','ticket_id'),
 ('support_ticket_events','actor_id'),('support_ticket_events','changes'),
 ('support_ticket_messages','id'),('support_ticket_messages','ticket_id'),
 ('support_ticket_messages','message'),('admin_accounts','user_id'),('admin_accounts','active')
)
SELECT r.table_name,r.column_name,'MISSING IN SUPABASE' AS problem FROM required r
LEFT JOIN information_schema.columns c ON c.table_schema='public'
  AND c.table_name=r.table_name AND c.column_name=r.column_name
WHERE c.column_name IS NULL ORDER BY 1,2;
-- Check ALL applicable ticket RLS policies before enabling assignment-only visibility.
SELECT tablename,policyname,cmd,permissive,qual,with_check
FROM pg_policies WHERE schemaname='public' AND tablename IN
 ('support_tickets','support_ticket_events','support_ticket_messages')
ORDER BY tablename,policyname;
