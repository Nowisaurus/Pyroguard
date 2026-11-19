-- ============================================================================
-- PYROGUARD MYSQL SYNC FIX (MySQL Workbench)            2026-11-04
--
-- Why sync never finished: the worker archives every copied row in
-- pyroguard_local_source_records.payload_raw, but no script ever created that
-- column, so EVERY row copy failed with "Unknown column 'payload_raw'".
-- The updated worker also adds it automatically; running this script first is
-- the same fix done by hand.
--
-- Also adds the new room sensor safety fields (fire_confirmed, flame_fault,
-- smoke_fault) so they are copied as real columns, and an index used by the
-- worker's incremental window. Safe to run more than once. Nothing is deleted.
-- ============================================================================

USE pyroguard_db;

DROP PROCEDURE IF EXISTS pyroguard_add_column_if_missing;
DROP PROCEDURE IF EXISTS pyroguard_add_index_if_missing;

DELIMITER $$

CREATE PROCEDURE pyroguard_add_column_if_missing(
    IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_definition VARCHAR(255))
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema = DATABASE() AND table_name = p_table)
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = DATABASE() AND table_name = p_table AND column_name = p_column) THEN
        SET @ddl = CONCAT('ALTER TABLE `', p_table, '` ADD COLUMN `', p_column, '` ', p_definition);
        PREPARE stmt FROM @ddl; EXECUTE stmt; DEALLOCATE PREPARE stmt;
    END IF;
END$$

CREATE PROCEDURE pyroguard_add_index_if_missing(
    IN p_table VARCHAR(64), IN p_index VARCHAR(64), IN p_columns VARCHAR(255))
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

-- Archive table used by the local worker (created here if it does not exist yet)
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

-- THE FIX: missing archive column
CALL pyroguard_add_column_if_missing('pyroguard_local_source_records', 'payload_raw', 'LONGTEXT NULL AFTER payload');

-- Room sensor safety fields (from the new firmware via sensor-ingest)
CALL pyroguard_add_column_if_missing('pyroguard_room_sensor_readings', 'fire_confirmed', 'TINYINT(1) NULL');
CALL pyroguard_add_column_if_missing('pyroguard_room_sensor_readings', 'flame_fault', 'TINYINT(1) NULL');
CALL pyroguard_add_column_if_missing('pyroguard_room_sensor_readings', 'smoke_fault', 'TINYINT(1) NULL');
CALL pyroguard_add_index_if_missing('pyroguard_room_sensor_readings', 'idx_pg_room_received', 'received_at');

-- Incremental window indexes for the other large history tables
CALL pyroguard_add_index_if_missing('pyroguard_sensor_history', 'idx_sensor_history_created', 'created_at');
CALL pyroguard_add_index_if_missing('pyroguard_event_history', 'idx_event_history_created', 'created_at');

DROP PROCEDURE IF EXISTS pyroguard_add_column_if_missing;
DROP PROCEDURE IF EXISTS pyroguard_add_index_if_missing;

-- ----------------------------------------------------------------------------
-- VERIFY
-- ----------------------------------------------------------------------------
SELECT table_name, column_name, column_type
  FROM information_schema.columns
 WHERE table_schema = DATABASE()
   AND ((table_name = 'pyroguard_local_source_records' AND column_name = 'payload_raw')
     OR (table_name = 'pyroguard_room_sensor_readings'
         AND column_name IN ('fire_confirmed', 'flame_fault', 'smoke_fault')))
 ORDER BY table_name, column_name;

-- After the worker runs (npm run once), the newest copied readings:
SELECT controller_device_id, room_key, temperature, humidity, smoke_status,
       flame_detected, fire_confirmed, received_at
  FROM pyroguard_room_sensor_readings
 ORDER BY received_at DESC
 LIMIT 8;
