-- ============================================================================
-- PYROGUARD - MYSQL FINAL SYNC FIX (MySQL Workbench / MySQL 8)   2026-11-19
-- Run AFTER PYROGUARD_ALL_QUERIES_MYSQL.sql, and AFTER 01_SUPABASE_FINAL_SYNC_FIX.sql
-- has been run in Supabase. Back up pyroguard_db first.
--
-- Replaces (do not run again): 20261101_room_sensor_groups_mysql.sql,
--   20261104b_mysql_sync_fix.sql, 20261031_mysql_ticket_archive_alignment.sql
--
-- The local sync worker copies ONLY columns that exist in MySQL, and a table
-- that is missing in MySQL makes that whole table fail. This script makes every
-- Supabase table/column the worker mirrors exist here with a matching type.
--
-- BUGS FIXED:
--  1. pyroguard_room_sensor_readings was never created by the main MySQL schema;
--     the 2026-11-04b fix only ADDED columns to it, which silently did nothing
--     when the table was missing -> room readings never reached MySQL.
--  2. pyroguard_local_source_records.payload_raw missing -> every row copy failed
--     with "Unknown column 'payload_raw'".
--  3. Ticket archive columns (archived_at / archived_by) missing in MySQL.
--  4. pyroguard_admin_accounts only allowed admin_order 1..4 (now 1..20).
--  5. New mirrored tables: door/window state, Home 1 members, incident emails,
--     and the two false-fire archive tables.
-- Safe to run more than once. Nothing is deleted.
-- ============================================================================

USE pyroguard_db;
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET time_zone = '+00:00';

DROP PROCEDURE IF EXISTS pg_fix_add_column;
DROP PROCEDURE IF EXISTS pg_fix_add_index;

DELIMITER $$

CREATE PROCEDURE pg_fix_add_column(IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_definition VARCHAR(255))
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = p_table AND column_name = p_column) THEN
        SET @ddl = CONCAT('ALTER TABLE `', p_table, '` ADD COLUMN `', p_column, '` ', p_definition);
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END IF;
END$$

CREATE PROCEDURE pg_fix_add_index(IN p_table VARCHAR(64), IN p_index VARCHAR(64), IN p_columns VARCHAR(255))
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM information_schema.statistics
                WHERE table_schema = DATABASE() AND table_name = p_table AND index_name = p_index) THEN
        SET @ddl = CONCAT('ALTER TABLE `', p_table, '` ADD INDEX `', p_index, '` (', p_columns, ')');
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END IF;
END$$

DELIMITER ;

-- ----------------------------------------------------------------------------
-- 0. Admin registry: the original CHECK allowed admin_order 1..4 only, but the
--    app recognises up to 7 admin accounts -> rows 5..7 could never be mirrored.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS pg_fix_admin_order_check;
DELIMITER $$
CREATE PROCEDURE pg_fix_admin_order_check()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE c VARCHAR(64);
    DECLARE cur CURSOR FOR
        SELECT tc.CONSTRAINT_NAME
          FROM information_schema.TABLE_CONSTRAINTS tc
          JOIN information_schema.CHECK_CONSTRAINTS cc
            ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
         WHERE tc.TABLE_SCHEMA = DATABASE() AND tc.TABLE_NAME = 'pyroguard_admin_accounts'
           AND tc.CONSTRAINT_TYPE = 'CHECK' AND cc.CHECK_CLAUSE LIKE '%admin_order%'
           AND tc.CONSTRAINT_NAME <> 'chk_admin_order_range';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO c;
        IF done THEN LEAVE read_loop; END IF;
        SET @ddl = CONCAT('ALTER TABLE pyroguard_admin_accounts DROP CHECK `', c, '`');
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END LOOP;
    CLOSE cur;
    IF NOT EXISTS (SELECT 1 FROM information_schema.TABLE_CONSTRAINTS
                    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'pyroguard_admin_accounts'
                      AND CONSTRAINT_NAME = 'chk_admin_order_range') THEN
        ALTER TABLE pyroguard_admin_accounts
            ADD CONSTRAINT chk_admin_order_range CHECK (admin_order BETWEEN 1 AND 20);
    END IF;
END$$
DELIMITER ;
CALL pg_fix_admin_order_check();
DROP PROCEDURE IF EXISTS pg_fix_admin_order_check;

-- ----------------------------------------------------------------------------
-- 1. Worker archive table (+ the missing payload_raw column)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_local_source_records (
    source_table VARCHAR(100) NOT NULL,
    source_key VARCHAR(255) NOT NULL,
    payload JSON NOT NULL,
    payload_raw LONGTEXT NULL,
    payload_hash CHAR(64) NOT NULL,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    synced_at DATETIME(3) NOT NULL,
    PRIMARY KEY (source_table, source_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CALL pg_fix_add_column('pyroguard_local_source_records', 'payload_raw', 'LONGTEXT NULL AFTER payload');

-- ----------------------------------------------------------------------------
-- 2. Room sensor readings (mirror of public.pyroguard_room_sensor_readings)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_room_sensor_readings (
    id CHAR(36) NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    controller_device_id VARCHAR(100) NOT NULL,
    room_key VARCHAR(32) NOT NULL,
    temperature DECIMAL(12,5) NULL,
    humidity DECIMAL(12,5) NULL,
    smoke_raw DECIMAL(14,5) NULL,
    smoke_status VARCHAR(100) NULL,
    flame_detected TINYINT(1) NULL,
    buzzer_active TINYINT(1) NULL,
    fire_confirmed TINYINT(1) NULL,
    flame_fault TINYINT(1) NULL,
    smoke_fault TINYINT(1) NULL,
    sampled_at DATETIME(6) NOT NULL,
    received_at DATETIME(6) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CALL pg_fix_add_column('pyroguard_room_sensor_readings', 'fire_confirmed', 'TINYINT(1) NULL');
CALL pg_fix_add_column('pyroguard_room_sensor_readings', 'flame_fault', 'TINYINT(1) NULL');
CALL pg_fix_add_column('pyroguard_room_sensor_readings', 'smoke_fault', 'TINYINT(1) NULL');
CALL pg_fix_add_index('pyroguard_room_sensor_readings', 'idx_pg_room_device', 'controller_device_id, room_key, sampled_at');
CALL pg_fix_add_index('pyroguard_room_sensor_readings', 'idx_pg_room_user', 'user_id, sampled_at');
CALL pg_fix_add_index('pyroguard_room_sensor_readings', 'idx_pg_room_received', 'received_at');

-- ----------------------------------------------------------------------------
-- 3. Support ticket archive fields
-- ----------------------------------------------------------------------------
CALL pg_fix_add_column('pyroguard_support_tickets', 'archived_at', 'DATETIME(3) NULL');
CALL pg_fix_add_column('pyroguard_support_tickets', 'archived_by', 'CHAR(36) NULL');
CALL pg_fix_add_index('pyroguard_support_tickets', 'idx_tickets_assigned', 'assigned_to');

-- ----------------------------------------------------------------------------
-- 4. Door / window current state (mirror, keyed by the new Supabase id)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_contact_current_state (
    id CHAR(36) NOT NULL PRIMARY KEY,
    device_id VARCHAR(100) NOT NULL,
    room_key VARCHAR(32) NOT NULL,
    contact_type VARCHAR(16) NOT NULL,
    is_open TINYINT(1) NOT NULL,
    received_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NULL,
    UNIQUE KEY uq_contact_device_type (device_id, contact_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 5. Home 1 members (mirror)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_home_members (
    id BIGINT NOT NULL PRIMARY KEY,
    home_id BIGINT NOT NULL,
    user_id CHAR(36) NOT NULL,
    member_role VARCHAR(40) NULL,
    membership_status VARCHAR(40) NULL,
    created_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NULL,
    INDEX idx_home_members_user (user_id),
    INDEX idx_home_members_home (home_id, user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 6. Incident e-mail log (mirror)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_incident_emails (
    id BIGINT NOT NULL PRIMARY KEY,
    event_record_key VARCHAR(190) NOT NULL,
    device_id VARCHAR(100) NULL,
    event_type VARCHAR(120) NOT NULL,
    recipients JSON NULL,
    photo_path TEXT NULL,
    provider VARCHAR(40) NULL,
    status VARCHAR(20) NOT NULL,
    error TEXT NULL,
    created_at DATETIME(6) NOT NULL,
    sent_at DATETIME(6) NULL,
    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3) NULL,
    last_sync_error TEXT NULL,
    UNIQUE KEY uq_incident_email_event (event_record_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ----------------------------------------------------------------------------
-- 7. False-fire archive tables (same shape as the source tables + archived_at)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pyroguard_room_sensor_readings_archive LIKE pyroguard_room_sensor_readings;
CALL pg_fix_add_column('pyroguard_room_sensor_readings_archive', 'archived_at', 'DATETIME(6) NULL');
CREATE TABLE IF NOT EXISTS pyroguard_event_history_archive LIKE pyroguard_event_history;
CALL pg_fix_add_column('pyroguard_event_history_archive', 'archived_at', 'DATETIME(6) NULL');

-- ----------------------------------------------------------------------------
-- 8. Camera events: photos uploaded by camera-ingest carry the camera id
-- ----------------------------------------------------------------------------
CALL pg_fix_add_index('pyroguard_camera_events', 'idx_camera_event_created', 'created_at');

-- ----------------------------------------------------------------------------
-- 9. Incremental-window indexes for large history tables
-- ----------------------------------------------------------------------------
CALL pg_fix_add_index('pyroguard_sensor_history', 'idx_sensor_history_created', 'created_at');
CALL pg_fix_add_index('pyroguard_event_history', 'idx_event_history_created', 'created_at');

DROP PROCEDURE IF EXISTS pg_fix_add_column;
DROP PROCEDURE IF EXISTS pg_fix_add_index;

-- ----------------------------------------------------------------------------
-- VERIFY: every mirrored table exists (expect 0 rows marked MISSING)
-- ----------------------------------------------------------------------------
SELECT r.table_name,
       CASE WHEN t.table_name IS NULL THEN 'MISSING' ELSE 'OK' END AS status
FROM (
    SELECT 'pyroguard_admin_accounts' AS table_name UNION ALL SELECT 'pyroguard_profiles'
    UNION ALL SELECT 'pyroguard_account_identities' UNION ALL SELECT 'pyroguard_homes'
    UNION ALL SELECT 'pyroguard_stakeholders' UNION ALL SELECT 'pyroguard_emergency_contacts'
    UNION ALL SELECT 'pyroguard_safety_setups' UNION ALL SELECT 'pyroguard_user_preferences'
    UNION ALL SELECT 'pyroguard_devices' UNION ALL SELECT 'pyroguard_device_current_state'
    UNION ALL SELECT 'pyroguard_device_heartbeats' UNION ALL SELECT 'pyroguard_pyroguard_camera_telemetry'
    UNION ALL SELECT 'pyroguard_system_state' UNION ALL SELECT 'pyroguard_device_commands'
    UNION ALL SELECT 'pyroguard_ptz_state' UNION ALL SELECT 'pyroguard_ptz_commands'
    UNION ALL SELECT 'pyroguard_sensor_history' UNION ALL SELECT 'pyroguard_event_history'
    UNION ALL SELECT 'pyroguard_camera_history' UNION ALL SELECT 'pyroguard_camera_events'
    UNION ALL SELECT 'pyroguard_audio_sessions' UNION ALL SELECT 'pyroguard_mirror_records'
    UNION ALL SELECT 'pyroguard_dual_record_ledger' UNION ALL SELECT 'pyroguard_emergency_action_logs'
    UNION ALL SELECT 'pyroguard_sensor_readings' UNION ALL SELECT 'pyroguard_support_tickets'
    UNION ALL SELECT 'pyroguard_support_ticket_messages' UNION ALL SELECT 'pyroguard_support_ticket_events'
    UNION ALL SELECT 'pyroguard_room_sensor_readings' UNION ALL SELECT 'pyroguard_contact_current_state'
    UNION ALL SELECT 'pyroguard_home_members' UNION ALL SELECT 'pyroguard_incident_emails'
    UNION ALL SELECT 'pyroguard_room_sensor_readings_archive' UNION ALL SELECT 'pyroguard_event_history_archive'
    UNION ALL SELECT 'pyroguard_local_source_records'
) r
LEFT JOIN information_schema.tables t
       ON t.table_schema = DATABASE() AND t.table_name = r.table_name
ORDER BY status DESC, r.table_name;

SELECT table_name, column_name, column_type
  FROM information_schema.columns
 WHERE table_schema = DATABASE()
   AND ((table_name = 'pyroguard_local_source_records' AND column_name = 'payload_raw')
     OR (table_name = 'pyroguard_room_sensor_readings' AND column_name IN ('fire_confirmed','flame_fault','smoke_fault'))
     OR (table_name = 'pyroguard_support_tickets' AND column_name IN ('archived_at','archived_by')))
 ORDER BY table_name, column_name;
-- Expect 6 rows. Then restart the sync worker (npm run once) and run 04_VERIFY_MYSQL.sql.
