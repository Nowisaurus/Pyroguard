-- ============================================================================
-- PYROGUARD - MYSQL: TABLES ADDED IN v17 / v18 (2026-11-24)
-- Run in MySQL WORKBENCH (not Supabase): open this file, Ctrl+Shift+Enter.
-- Safe to run more than once.
--   pyroguard_area_incidents        fire history (BFP / news + home)
--   pyroguard_sensor_maintenance    install / last-check dates
--   pyroguard_bfp_report_emails     incident reports e-mailed to BFP
--   pyroguard_incident_reports      issued reports (verification code, SHA-256)
--   pyroguard_home_layout           floor plan rooms, doors, exits
--   pyroguard_cost_catalog          hardware + labor prices (admin)
--   pyroguard_change_log            what users / admins changed
--   pyroguard_sensor_health_log     sensor health history
-- plus new columns: homes.evac_*, emergency_contacts.email
-- ============================================================================
USE pyroguard_db;

CREATE TABLE IF NOT EXISTS pyroguard_area_incidents (
    id BIGINT NOT NULL PRIMARY KEY,
    reported_by CHAR(36) NULL,
    latitude DOUBLE NOT NULL,
    longitude DOUBLE NOT NULL,
    occurred_on DATE NOT NULL,
    incident_type VARCHAR(120) NOT NULL,
    description TEXT NOT NULL,
    source VARCHAR(120) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    city VARCHAR(120) NULL,
    location_text TEXT NULL,
    alarm_level VARCHAR(60) NULL,
    details TEXT NULL,
    reference TEXT NULL,
    date_precision VARCHAR(20) NOT NULL,
    location_approx BOOLEAN NOT NULL,
    verified BOOLEAN NOT NULL,
    seed_key VARCHAR(120) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_sensor_maintenance (
    id BIGINT NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    device_id VARCHAR(100) NOT NULL,
    room_key VARCHAR(60) NOT NULL,
    sensor_kind VARCHAR(20) NOT NULL,
    installed_on DATE NOT NULL,
    last_checked_on DATE NULL,
    notes TEXT NOT NULL,
    updated_at DATETIME(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_bfp_report_emails (
    id BIGINT NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    report_number VARCHAR(80) NOT NULL,
    bfp_email VARCHAR(254) NOT NULL,
    bfp_station TEXT NULL,
    cc_email VARCHAR(254) NULL,
    status VARCHAR(20) NOT NULL,
    provider VARCHAR(40) NULL,
    error TEXT NULL,
    created_at DATETIME(6) NOT NULL,
    sent_at DATETIME(6) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_incident_reports (
    id BIGINT NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    report_number VARCHAR(80) NOT NULL,
    controller_id VARCHAR(100) NOT NULL,
    room_key VARCHAR(60) NOT NULL,
    incident_type VARCHAR(60) NOT NULL,
    first_detected DATETIME(6) NOT NULL,
    last_detected DATETIME(6) NOT NULL,
    reading_count INT NOT NULL,
    photo_urls JSON NOT NULL,
    data_sha256 CHAR(64) NOT NULL,
    verify_code VARCHAR(40) NOT NULL,
    area_label TEXT NULL,
    generated_at DATETIME(6) NOT NULL,
    KEY idx_incident_reports_number (report_number)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_home_layout (
    id BIGINT NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    item_key VARCHAR(80) NOT NULL,
    kind VARCHAR(20) NOT NULL,
    label VARCHAR(120) NOT NULL,
    x_m DECIMAL(10,3) NOT NULL,
    y_m DECIMAL(10,3) NOT NULL,
    w_m DECIMAL(10,3) NOT NULL,
    h_m DECIMAL(10,3) NOT NULL,
    controller_id VARCHAR(100) NULL,
    room_key VARCHAR(60) NULL,
    notes TEXT NULL,
    updated_at DATETIME(6) NOT NULL,
    door_x_m DECIMAL(10,3) NULL,
    door_y_m DECIMAL(10,3) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_cost_catalog (
    id BIGINT NOT NULL PRIMARY KEY,
    category VARCHAR(20) NOT NULL,
    item VARCHAR(160) NOT NULL,
    quantity DECIMAL(8,2) NOT NULL,
    unit VARCHAR(20) NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    supplier VARCHAR(120) NOT NULL,
    source_url TEXT NULL,
    price_checked_on DATE NOT NULL,
    notes VARCHAR(300) NULL,
    sort_order INT NOT NULL,
    updated_at DATETIME(6) NOT NULL,
    updated_by CHAR(36) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_change_log (
    id BIGINT NOT NULL PRIMARY KEY,
    table_name VARCHAR(80) NOT NULL,
    record_id VARCHAR(80) NULL,
    action VARCHAR(10) NOT NULL,
    changed_by CHAR(36) NULL,
    actor_email VARCHAR(254) NULL,
    old_data JSON NULL,
    new_data JSON NULL,
    changed_at DATETIME(6) NOT NULL,
    KEY idx_change_log_time (changed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS pyroguard_sensor_health_log (
    id BIGINT NOT NULL PRIMARY KEY,
    user_id CHAR(36) NULL,
    controller_device_id VARCHAR(100) NOT NULL,
    room_key VARCHAR(60) NOT NULL,
    sensor_kind VARCHAR(10) NOT NULL,
    status VARCHAR(20) NOT NULL,
    detail TEXT NULL,
    observed_at DATETIME(6) NOT NULL,
    admin_note VARCHAR(500) NULL,
    resolved_at DATETIME(6) NULL,
    resolved_by CHAR(36) NULL,
    KEY idx_health_log_sensor (controller_device_id, room_key, sensor_kind, observed_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- New columns on existing tables (MySQL 8 has no ADD COLUMN IF NOT EXISTS).
SET @sql := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE()
    AND table_name = 'pyroguard_homes' AND column_name = 'evac_name') = 0,
  'ALTER TABLE pyroguard_homes ADD COLUMN evac_name TEXT NULL, ADD COLUMN evac_latitude DOUBLE NULL, ADD COLUMN evac_longitude DOUBLE NULL',
  'SELECT 1');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

SET @sql := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE()
    AND table_name = 'pyroguard_emergency_contacts' AND column_name = 'email') = 0,
  'ALTER TABLE pyroguard_emergency_contacts ADD COLUMN email VARCHAR(254) NULL',
  'SELECT 1');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

-- Check: should list all 8 tables.
SELECT table_name FROM information_schema.tables
WHERE table_schema = DATABASE() AND table_name IN (
  'pyroguard_area_incidents','pyroguard_sensor_maintenance','pyroguard_bfp_report_emails',
  'pyroguard_incident_reports','pyroguard_home_layout','pyroguard_cost_catalog',
  'pyroguard_change_log','pyroguard_sensor_health_log');
