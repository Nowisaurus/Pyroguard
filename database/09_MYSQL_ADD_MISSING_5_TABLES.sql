-- ============================================================================
-- PYROGUARD - MYSQL: CREATE THE 5 TABLES THE SYNC WORKER REPORTS AS MISSING
-- Run in MySQL WORKBENCH (not Supabase): open this file, Ctrl+Shift+Enter.
-- Safe to run more than once. Needs no stored procedures from other scripts.
--   pyroguard_contact_current_state, pyroguard_home_members,
--   pyroguard_incident_emails, pyroguard_room_sensor_readings_archive,
--   pyroguard_event_history_archive
-- ============================================================================
USE pyroguard_db;

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

-- Archive tables: same shape as their source tables, plus archived_at.
CREATE TABLE IF NOT EXISTS pyroguard_room_sensor_readings_archive LIKE pyroguard_room_sensor_readings;
CREATE TABLE IF NOT EXISTS pyroguard_event_history_archive LIKE pyroguard_event_history;

-- Add archived_at only if it is not there yet (MySQL 8 has no ADD COLUMN IF NOT EXISTS).
SET @sql := IF(
    (SELECT COUNT(*) FROM information_schema.columns
      WHERE table_schema = 'pyroguard_db' AND table_name = 'pyroguard_room_sensor_readings_archive'
        AND column_name = 'archived_at') = 0,
    'ALTER TABLE pyroguard_room_sensor_readings_archive ADD COLUMN archived_at DATETIME(6) NULL',
    'SELECT 1');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

SET @sql := IF(
    (SELECT COUNT(*) FROM information_schema.columns
      WHERE table_schema = 'pyroguard_db' AND table_name = 'pyroguard_event_history_archive'
        AND column_name = 'archived_at') = 0,
    'ALTER TABLE pyroguard_event_history_archive ADD COLUMN archived_at DATETIME(6) NULL',
    'SELECT 1');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

-- Check: expect 5 rows.
SELECT table_name AS created_table
  FROM information_schema.tables
 WHERE table_schema = 'pyroguard_db'
   AND table_name IN ('pyroguard_contact_current_state', 'pyroguard_home_members',
                      'pyroguard_incident_emails', 'pyroguard_room_sensor_readings_archive',
                      'pyroguard_event_history_archive')
 ORDER BY table_name;
