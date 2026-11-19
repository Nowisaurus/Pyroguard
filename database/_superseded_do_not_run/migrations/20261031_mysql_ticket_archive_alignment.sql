-- RUN IN MYSQL WORKBENCH against pyroguard_db AFTER the existing MySQL base schema.
-- Idempotent alignment for the ticket archive fields added to Supabase.
-- Does NOT truncate, replace, or delete existing data.
USE pyroguard_db;
DELIMITER $$
DROP PROCEDURE IF EXISTS pg_add_archive_columns $$
CREATE PROCEDURE pg_add_archive_columns()
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='pyroguard_support_tickets' AND column_name='archived_at') THEN
    ALTER TABLE pyroguard_support_tickets ADD COLUMN archived_at DATETIME(3) NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='pyroguard_support_tickets' AND column_name='archived_by') THEN
    ALTER TABLE pyroguard_support_tickets ADD COLUMN archived_by CHAR(36) NULL;
  END IF;
END $$
DELIMITER ;
CALL pg_add_archive_columns();
DROP PROCEDURE IF EXISTS pg_add_archive_columns;
-- Check existing records; do not alter or fake their values.
SELECT COUNT(*) AS mirrored_ticket_rows,
       SUM(archived_at IS NOT NULL) AS mirrored_archived_tickets
FROM pyroguard_support_tickets;
