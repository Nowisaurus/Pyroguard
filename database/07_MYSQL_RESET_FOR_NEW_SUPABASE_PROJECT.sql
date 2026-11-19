-- ============================================================================
-- PYROGUARD - EMPTY THE MYSQL MIRROR FOR THE NEW SUPABASE PROJECT   2026-11-19
-- The old rows belong to the deleted Supabase project (old user IDs/devices),
-- so they can never match the new accounts. This keeps every table and column
-- and only removes the rows; the sync worker then refills MySQL from the new
-- project. BACK UP FIRST:
--   mysqldump -u root -p pyroguard_db > pyroguard_db_old_project.sql
-- Run AFTER 02_MYSQL_FINAL_SYNC_FIX.sql. Stop the sync worker while it runs.
-- ============================================================================
USE pyroguard_db;
SET FOREIGN_KEY_CHECKS = 0;

DROP PROCEDURE IF EXISTS pg_reset_all;
DELIMITER $$
CREATE PROCEDURE pg_reset_all()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE t VARCHAR(64);
    DECLARE cur CURSOR FOR
        SELECT table_name FROM information_schema.tables
         WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
           AND table_name LIKE 'pyroguard\_%';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
    OPEN cur;
    reset_loop: LOOP
        FETCH cur INTO t;
        IF done THEN LEAVE reset_loop; END IF;
        SET @ddl = CONCAT('TRUNCATE TABLE `', t, '`');
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL pg_reset_all();
DROP PROCEDURE IF EXISTS pg_reset_all;

SET FOREIGN_KEY_CHECKS = 1;

-- Every count must be 0. Then start the worker (npm run once).
SELECT table_name, table_rows
  FROM information_schema.tables
 WHERE table_schema = DATABASE() AND table_name LIKE 'pyroguard\_%'
 ORDER BY table_name;
