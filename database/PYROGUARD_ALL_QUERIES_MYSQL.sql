-- ============================================================================
-- PYROGUARD APPLICATION SYSTEM
-- COMPLETE MYSQL 8 DATABASE SCHEMA AND ADDITIVE UPDATES
-- Updated: 2026-10-22
-- ============================================================================

CREATE DATABASE IF NOT EXISTS pyroguard_db
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

USE pyroguard_db;

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;
SET time_zone = '+00:00';


-- ============================================================================
-- SECTION 1: ADMINISTRATOR ACCOUNTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_admin_accounts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    admin_order SMALLINT NOT NULL,
    user_id CHAR(36),
    email VARCHAR(255) NOT NULL,
    display_name VARCHAR(180) NOT NULL,
    admin_role VARCHAR(40) NOT NULL,
    admin_reference_code VARCHAR(40) NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_order (admin_order),
    UNIQUE KEY uq_email (email),
    UNIQUE KEY uq_ref (admin_reference_code),
    UNIQUE KEY uq_user (user_id),

    CHECK (admin_order BETWEEN 1 AND 4),
    CHECK (admin_role IN ('head_developer', 'administrator'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 2: USER PROFILES
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_profiles (
    id CHAR(36) NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,
    full_name TEXT,
    email VARCHAR(255),
    phone VARCHAR(80),
    account_role VARCHAR(40) NOT NULL DEFAULT 'homeowner',
    account_status VARCHAR(30) NOT NULL DEFAULT 'active',

    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_user (user_id),

    CHECK (account_role IN (
        'homeowner',
        'administrator',
        'head_developer'
    )),

    CHECK (account_status IN (
        'active',
        'disabled',
        'locked'
    ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 3: ACCOUNT IDENTITIES
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_account_identities (
    user_id CHAR(36) NOT NULL PRIMARY KEY,
    email VARCHAR(255),
    display_name VARCHAR(255),
    phone VARCHAR(80),

    account_role VARCHAR(40) NOT NULL DEFAULT 'homeowner',
    auth_provider VARCHAR(60) NOT NULL DEFAULT 'email',
    email_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    account_status VARCHAR(30) NOT NULL DEFAULT 'active',

    last_login_at DATETIME(3),
    last_logout_at DATETIME(3),

    event VARCHAR(40),
    logged_in_at DATETIME(3),
    logged_out_at DATETIME(3),

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_account_email (email),
    INDEX idx_account_role (account_role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 4: HOME INFORMATION
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_homes (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    home_name VARCHAR(255) NOT NULL DEFAULT 'My Home',
    address TEXT,
    barangay VARCHAR(255),
    city VARCHAR(255),

    latitude DOUBLE,
    longitude DOUBLE,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 5: STAKEHOLDERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_stakeholders (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    full_name VARCHAR(255) NOT NULL,
    relationship VARCHAR(100),
    phone VARCHAR(80),
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    INDEX idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 6: EMERGENCY CONTACTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_emergency_contacts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    contact_type VARCHAR(80) NOT NULL DEFAULT 'BFP',
    name VARCHAR(255),
    station_name VARCHAR(255),
    personnel_name VARCHAR(255),
    rank_position VARCHAR(255),
    phone VARCHAR(80),
    address TEXT,

    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    INDEX idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 7: SAFETY SETTINGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_safety_setups (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    safety_acknowledged BOOLEAN NOT NULL DEFAULT FALSE,
    entry_delay_seconds INT NOT NULL DEFAULT 30,
    siren_duration_seconds INT NOT NULL DEFAULT 120,
    ai_assist_enabled BOOLEAN NOT NULL DEFAULT TRUE,

    notes TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_user (user_id),

    CHECK (entry_delay_seconds BETWEEN 0 AND 600),
    CHECK (siren_duration_seconds BETWEEN 10 AND 3600)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 8: USER PREFERENCES
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_user_preferences (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    push_notifications BOOLEAN NOT NULL DEFAULT TRUE,
    email_alerts BOOLEAN NOT NULL DEFAULT TRUE,
    sms_alerts BOOLEAN NOT NULL DEFAULT FALSE,
    dark_mode BOOLEAN NOT NULL DEFAULT FALSE,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 9: REGISTERED DEVICES
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_devices (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    device_id VARCHAR(100) NOT NULL,
    device_name VARCHAR(255) NOT NULL
        DEFAULT 'Main PyroGuard Controller',

    device_type VARCHAR(100) NOT NULL DEFAULT 'ESP32_MAIN',
    status VARCHAR(60) NOT NULL DEFAULT 'registered',

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_device (device_id),
    INDEX idx_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 10: CURRENT DEVICE STATE
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_device_current_state (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(100) NOT NULL,

    temperature DECIMAL(12,4),
    humidity DECIMAL(12,4),

    smoke_raw INT,
    smoke_level DECIMAL(12,4),
    smoke_status VARCHAR(60),

    flame_detected BOOLEAN DEFAULT FALSE,
    alert_status VARCHAR(80),
    incident_type VARCHAR(120),
    severity_level INT DEFAULT 0,

    location TEXT,
    device_lat DECIMAL(12,8),
    device_lng DECIMAL(12,8),

    door_status VARCHAR(60),
    window_status VARCHAR(60),
    motion_detected BOOLEAN,

    system_armed BOOLEAN DEFAULT FALSE,
    system_mode VARCHAR(40) DEFAULT 'DISARMED',
    siren_active BOOLEAN NOT NULL DEFAULT FALSE,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 11: DEVICE HEARTBEATS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_device_heartbeats (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(100) NOT NULL,

    wifi_ok BOOLEAN DEFAULT FALSE,
    supabase_ok BOOLEAN DEFAULT FALSE,
    camera_ok BOOLEAN DEFAULT FALSE,
    ptz_ok BOOLEAN DEFAULT FALSE,
    mic_ok BOOLEAN DEFAULT FALSE,
    speaker_ok BOOLEAN DEFAULT FALSE,
    pir_ok BOOLEAN DEFAULT FALSE,
    door_ok BOOLEAN DEFAULT FALSE,
    window_ok BOOLEAN DEFAULT FALSE,
    ultrasonic_ok BOOLEAN DEFAULT FALSE,
    mq2_ok BOOLEAN DEFAULT FALSE,
    flame_ok BOOLEAN DEFAULT FALSE,
    dht22_ok BOOLEAN DEFAULT FALSE,
    gps_ok BOOLEAN DEFAULT FALSE,
    gsm_ok BOOLEAN DEFAULT FALSE,
    siren_ok BOOLEAN DEFAULT FALSE,

    uptime_secs BIGINT,
    battery_pct DECIMAL(6,2),
    local_ip VARCHAR(64),

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 12: CAMERA TELEMETRY
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_pyroguard_camera_telemetry (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    device_id VARCHAR(100) NOT NULL,
    camera_device_id VARCHAR(100) NOT NULL
        DEFAULT 'pyroguard_camera_001',

    camera_ip VARCHAR(64),
    status VARCHAR(60) NOT NULL DEFAULT 'offline',

    motion_detected BOOLEAN DEFAULT FALSE,
    motion_pixels INT DEFAULT 0,

    pan_angle INT DEFAULT 90,
    tilt_angle INT DEFAULT 90,

    wifi_rssi INT,
    uptime_ms BIGINT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_camera (camera_device_id),
    INDEX idx_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 13: SYSTEM SECURITY STATE
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_system_state (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36) NOT NULL,
    device_id VARCHAR(100) NOT NULL,

    arm_mode VARCHAR(20) NOT NULL DEFAULT 'DISARMED',

    door_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    window_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    motion_enabled BOOLEAN NOT NULL DEFAULT TRUE,

    acting_user CHAR(36),

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_device (device_id),

    CHECK (arm_mode IN (
        'DISARMED',
        'ARM_HOME',
        'ARM_AWAY'
    ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 14: DEVICE COMMANDS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_device_commands (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36) NOT NULL,
    target_device_id VARCHAR(100) NOT NULL,

    command VARCHAR(120) NOT NULL,
    payload JSON,
    requested_by CHAR(36),

    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    result_message TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    applied_at DATETIME(3),

    INDEX idx_pending (
        target_device_id,
        status,
        created_at
    ),

    CHECK (status IN (
        'pending',
        'processing',
        'applied',
        'failed',
        'expired'
    ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 15: PTZ STATE
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_ptz_state (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    device_id VARCHAR(100) NOT NULL,

    pan_position DECIMAL(9,3) NOT NULL DEFAULT 90,
    tilt_position DECIMAL(9,3) NOT NULL DEFAULT 90,

    moving BOOLEAN NOT NULL DEFAULT FALSE,
    auto_tracking BOOLEAN NOT NULL DEFAULT FALSE,

    pan_angle INT NOT NULL DEFAULT 90,
    tilt_angle INT NOT NULL DEFAULT 90,

    last_device_at DATETIME(3),

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_device (device_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 16: PTZ COMMANDS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_ptz_commands (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100) NOT NULL,

    pan DECIMAL(9,3) NOT NULL DEFAULT 0,
    tilt DECIMAL(9,3) NOT NULL DEFAULT 0,
    speed DECIMAL(9,3) NOT NULL DEFAULT 0,

    mode VARCHAR(40) NOT NULL DEFAULT 'manual',
    preset_name VARCHAR(150),

    command VARCHAR(120),
    value INT,

    status VARCHAR(30) NOT NULL DEFAULT 'created',

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    applied_at DATETIME(3),

    INDEX idx_device_time (device_id, created_at),

    CHECK (status IN (
        'created',
        'processing',
        'executed',
        'failed',
        'expired'
    ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 17: SENSOR HISTORY
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_sensor_history (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100) NOT NULL,

    temperature DECIMAL(12,4),
    humidity DECIMAL(12,4),

    smoke_raw INT,
    smoke_level DECIMAL(12,4),
    smoke_status VARCHAR(60),

    flame_detected BOOLEAN,
    door_status VARCHAR(60),
    window_status VARCHAR(60),
    motion_detected BOOLEAN,

    system_armed BOOLEAN,
    system_mode VARCHAR(40),
    siren_active BOOLEAN,

    incident_type VARCHAR(120),
    severity_level INT DEFAULT 0,
    alert_status VARCHAR(80),

    location TEXT,
    device_lat DECIMAL(12,8),
    device_lng DECIMAL(12,8),

    payload_json JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),

    INDEX idx_user_time (user_id, created_at),
    INDEX idx_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 18: EVENT HISTORY
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_event_history (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100),

    record_key VARCHAR(190),
    event_type VARCHAR(120) NOT NULL,
    sensor_name VARCHAR(120),

    location TEXT,
    event_status VARCHAR(60),

    image_url TEXT,
    acting_user_name VARCHAR(180),

    message TEXT,
    severity INT DEFAULT 0,

    payload_json JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_event_record_key (record_key),

    INDEX idx_user_time (user_id, created_at),
    INDEX idx_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 19: CAMERA HISTORY
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_camera_history (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100),

    event_type VARCHAR(120) NOT NULL,
    image_url TEXT,
    metadata_json JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),

    INDEX idx_user_time (user_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 20: CAMERA EVENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_camera_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100) NOT NULL,
    record_key VARCHAR(190) NOT NULL,

    event_type VARCHAR(120) NOT NULL DEFAULT 'camera_event',

    snapshot_url TEXT,
    pan_at_capture DECIMAL(12,4),
    tilt_at_capture DECIMAL(12,4),

    payload_json JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_camera_record_key (record_key),
    INDEX idx_camera_event_user_time (user_id, created_at),
    INDEX idx_camera_event_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 21: AUDIO SESSIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_audio_sessions (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100) NOT NULL,
    record_key VARCHAR(190) NOT NULL,

    direction VARCHAR(40) NOT NULL DEFAULT 'from_device',
    clip_url TEXT,
    metadata_json JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_audio_record_key (record_key),
    INDEX idx_audio_user_time (user_id, created_at),
    INDEX idx_audio_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 22: MIRROR RECORDS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_mirror_records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36) NOT NULL,
    device_id VARCHAR(100),

    record_type VARCHAR(100) NOT NULL,
    record_key VARCHAR(190) NOT NULL,

    payload JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),
    updated_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3)
        ON UPDATE CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_user_type_key (
        user_id,
        record_type,
        record_key
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 23: DUAL RECORD LEDGER
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_dual_record_ledger (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    record_id CHAR(36) NOT NULL,
    user_id CHAR(36),
    device_id VARCHAR(100),

    record_type VARCHAR(100) NOT NULL,
    record_key VARCHAR(190) NOT NULL,

    operation VARCHAR(20) NOT NULL DEFAULT 'UPSERT',
    source VARCHAR(60) NOT NULL DEFAULT 'flutter',

    payload JSON,

    mysql_synced BOOLEAN NOT NULL DEFAULT TRUE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    UNIQUE KEY uq_dual_record_id (record_id),

    INDEX idx_dual_user_time (user_id, created_at),
    INDEX idx_dual_type_time (record_type, created_at),
    INDEX idx_dual_device_time (device_id, created_at),

    CHECK (operation IN (
        'INSERT',
        'UPDATE',
        'UPSERT',
        'DELETE',
        'ACTION',
        'SNAPSHOT'
    ))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 24: EMERGENCY ACTION LOGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_emergency_action_logs (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    user_id CHAR(36),
    device_id VARCHAR(100),

    event_type VARCHAR(120) NOT NULL,
    severity VARCHAR(80),
    message TEXT,

    bfp_station VARCHAR(255),
    bfp_personnel VARCHAR(255),
    bfp_phone VARCHAR(80),

    occurred_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    INDEX idx_user_time (user_id, created_at),
    INDEX idx_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 25: SENSOR READINGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_sensor_readings (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

    device_id VARCHAR(100) NOT NULL,

    temperature DECIMAL(12,4),
    humidity DECIMAL(12,4),

    smoke_raw INT,
    smoke_level DECIMAL(12,4),
    smoke_status VARCHAR(60),

    flame_detected BOOLEAN DEFAULT FALSE,

    alert_status VARCHAR(80),
    incident_type VARCHAR(120),
    severity_level INT DEFAULT 0,

    location TEXT,
    device_lat DECIMAL(12,8),
    device_lng DECIMAL(12,8),

    door_status VARCHAR(60),
    window_status VARCHAR(60),
    motion_detected BOOLEAN,
    system_armed BOOLEAN,

    created_at DATETIME(3) DEFAULT CURRENT_TIMESTAMP(3),

    INDEX idx_device_time (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 26: SUPPORT TICKETS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_support_tickets (
    id CHAR(36) NOT NULL PRIMARY KEY,
    user_id CHAR(36) NOT NULL,

    title VARCHAR(160) NOT NULL,
    description TEXT NOT NULL,
    category VARCHAR(32) NOT NULL,

    severity VARCHAR(16) NOT NULL,
    status VARCHAR(24) NOT NULL,

    assigned_to CHAR(36),
    resolution_notes TEXT,

    created_at DATETIME(3) NOT NULL,
    updated_at DATETIME(3) NOT NULL,
    resolved_at DATETIME(3),

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    INDEX idx_tickets_user (user_id, created_at),
    INDEX idx_tickets_queue (
        status,
        severity,
        created_at
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 27: SUPPORT TICKET MESSAGES
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_support_ticket_messages (
    id CHAR(36) NOT NULL PRIMARY KEY,

    ticket_id CHAR(36) NOT NULL,
    author_id CHAR(36) NOT NULL,

    message TEXT NOT NULL,
    internal BOOLEAN NOT NULL DEFAULT FALSE,

    created_at DATETIME(3) NOT NULL,

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    INDEX idx_messages_ticket (
        ticket_id,
        created_at
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 28: SUPPORT TICKET EVENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_support_ticket_events (
    id CHAR(36) NOT NULL PRIMARY KEY,

    ticket_id CHAR(36) NOT NULL,
    actor_id CHAR(36),

    action VARCHAR(48) NOT NULL,
    changes JSON NOT NULL,

    created_at DATETIME(3) NOT NULL,

    mysql_synced BOOLEAN NOT NULL DEFAULT FALSE,
    mysql_synced_at DATETIME(3),
    last_sync_error TEXT,

    INDEX idx_events_ticket (
        ticket_id,
        created_at
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 29: SOURCE RECORD ARCHIVE
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_source_records (
    source_table VARCHAR(100) NOT NULL,
    source_key VARCHAR(255) NOT NULL,

    payload JSON NOT NULL,

    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    source_record_id CHAR(36) NOT NULL,
    last_operation VARCHAR(12) NOT NULL,

    synced_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),

    PRIMARY KEY (source_table, source_key),

    KEY ix_source_record_id (source_record_id),
    KEY ix_source_synced_at (synced_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 30: LOCAL SOURCE RECORD ARCHIVE
-- ============================================================================

CREATE TABLE IF NOT EXISTS pyroguard_local_source_records (
    source_table VARCHAR(100) NOT NULL,
    source_key VARCHAR(255) NOT NULL,

    payload JSON NOT NULL,
    payload_hash CHAR(64) NOT NULL,

    is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    synced_at DATETIME(3) NOT NULL,

    PRIMARY KEY (source_table, source_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;


-- ============================================================================
-- SECTION 31: SAFE ADDITIVE COLUMN UPDATES
-- ============================================================================

DROP PROCEDURE IF EXISTS pyroguard_add_column;
DROP PROCEDURE IF EXISTS pyroguard_add_unique;

DELIMITER $$

CREATE PROCEDURE pyroguard_add_column(
    IN p_table VARCHAR(64),
    IN p_column VARCHAR(64),
    IN p_definition VARCHAR(255)
)
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
          AND table_name = p_table
          AND column_name = p_column
    ) THEN

        SET @pyroguard_ddl = CONCAT(
            'ALTER TABLE `',
            p_table,
            '` ADD COLUMN `',
            p_column,
            '` ',
            p_definition
        );

        PREPARE pyroguard_stmt FROM @pyroguard_ddl;
        EXECUTE pyroguard_stmt;
        DEALLOCATE PREPARE pyroguard_stmt;

    END IF;
END$$


CREATE PROCEDURE pyroguard_add_unique(
    IN p_table VARCHAR(64),
    IN p_index VARCHAR(64),
    IN p_columns VARCHAR(255)
)
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.statistics
        WHERE table_schema = DATABASE()
          AND table_name = p_table
          AND index_name = p_index
    ) THEN

        SET @pyroguard_ddl = CONCAT(
            'ALTER TABLE `',
            p_table,
            '` ADD UNIQUE KEY `',
            p_index,
            '` (',
            p_columns,
            ')'
        );

        PREPARE pyroguard_stmt FROM @pyroguard_ddl;
        EXECUTE pyroguard_stmt;
        DEALLOCATE PREPARE pyroguard_stmt;

    END IF;
END$$

DELIMITER ;


-- Account identity compatibility

CALL pyroguard_add_column(
    'pyroguard_account_identities',
    'event',
    'VARCHAR(40) NULL AFTER last_logout_at'
);

CALL pyroguard_add_column(
    'pyroguard_account_identities',
    'logged_in_at',
    'DATETIME(3) NULL AFTER event'
);

CALL pyroguard_add_column(
    'pyroguard_account_identities',
    'logged_out_at',
    'DATETIME(3) NULL AFTER logged_in_at'
);


-- Incident record key

CALL pyroguard_add_column(
    'pyroguard_event_history',
    'record_key',
    'VARCHAR(190) NULL AFTER device_id'
);

CALL pyroguard_add_unique(
    'pyroguard_event_history',
    'uq_event_record_key',
    '`record_key`'
);


-- Alarm/buzzer state compatibility
-- Column remains named siren_active for existing application compatibility.

CALL pyroguard_add_column(
    'pyroguard_device_current_state',
    'siren_active',
    'BOOLEAN NOT NULL DEFAULT FALSE AFTER system_mode'
);

CALL pyroguard_add_column(
    'pyroguard_sensor_history',
    'siren_active',
    'BOOLEAN NULL AFTER system_mode'
);


-- PTZ gateway freshness

CALL pyroguard_add_column(
    'pyroguard_ptz_state',
    'last_device_at',
    'DATETIME(3) NULL AFTER tilt_angle'
);


-- Remove only temporary migration helpers

DROP PROCEDURE IF EXISTS pyroguard_add_column;
DROP PROCEDURE IF EXISTS pyroguard_add_unique;


-- ============================================================================
-- SECTION 32: DATABASE VERIFICATION
-- ============================================================================

SELECT DATABASE() AS active_database;

SELECT VERSION() AS mysql_version;


-- Count application mirror tables.
-- Target: 28, assuming all listed tables were successfully created.

SELECT COUNT(*) AS application_mirror_tables
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_type = 'BASE TABLE'
  AND table_name IN (
      'pyroguard_admin_accounts',
      'pyroguard_profiles',
      'pyroguard_account_identities',
      'pyroguard_homes',
      'pyroguard_stakeholders',
      'pyroguard_emergency_contacts',
      'pyroguard_safety_setups',
      'pyroguard_user_preferences',
      'pyroguard_devices',
      'pyroguard_device_current_state',
      'pyroguard_device_heartbeats',
      'pyroguard_pyroguard_camera_telemetry',
      'pyroguard_system_state',
      'pyroguard_device_commands',
      'pyroguard_ptz_state',
      'pyroguard_ptz_commands',
      'pyroguard_sensor_history',
      'pyroguard_event_history',
      'pyroguard_camera_history',
      'pyroguard_camera_events',
      'pyroguard_audio_sessions',
      'pyroguard_mirror_records',
      'pyroguard_dual_record_ledger',
      'pyroguard_emergency_action_logs',
      'pyroguard_sensor_readings',
      'pyroguard_support_tickets',
      'pyroguard_support_ticket_messages',
      'pyroguard_support_ticket_events'
  );


-- Total PyroGuard-prefixed tables, including archives and other existing tables.

SELECT COUNT(*) AS total_pyroguard_tables
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_type = 'BASE TABLE'
  AND table_name LIKE 'pyroguard\_%';


-- List all installed tables.

SHOW TABLES;

-- ============================================================================
-- SECTION 33: ADMINISTRATOR VERIFICATION
-- ============================================================================

SELECT
    COUNT(*) AS total_admin_accounts
FROM pyroguard_admin_accounts;


SELECT
    admin_order,
    user_id,
    email,
    display_name,
    admin_role,
    active
FROM pyroguard_admin_accounts
ORDER BY admin_order;


-- ============================================================================
-- SECTION 34: HOMEOWNER ACCOUNTS
-- ============================================================================

SELECT
    COUNT(*) AS total_profiles
FROM pyroguard_profiles;


SELECT
    user_id,
    full_name,
    email,
    phone,
    account_role,
    account_status,
    created_at
FROM pyroguard_profiles
ORDER BY created_at DESC
LIMIT 100;


-- ============================================================================
-- SECTION 35: ACCOUNT IDENTITIES
-- ============================================================================

SELECT
    COUNT(*) AS total_account_identities
FROM pyroguard_account_identities;


SELECT
    user_id,
    email,
    display_name,
    account_role,
    email_confirmed,
    account_status,
    created_at
FROM pyroguard_account_identities
ORDER BY created_at DESC
LIMIT 100;


-- ============================================================================
-- SECTION 36: SUPPORT TICKET VERIFICATION
-- ============================================================================

SELECT
    'support_tickets' AS entity,
    COUNT(*) AS mirrored_rows
FROM pyroguard_support_tickets

UNION ALL

SELECT
    'support_ticket_messages',
    COUNT(*)
FROM pyroguard_support_ticket_messages

UNION ALL

SELECT
    'support_ticket_events',
    COUNT(*)
FROM pyroguard_support_ticket_events;


-- ============================================================================
-- SECTION 37: ALARM STATE VERIFICATION
-- ============================================================================

SELECT
    table_name,
    column_name,
    column_type
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND table_name IN (
      'pyroguard_device_current_state',
      'pyroguard_sensor_history'
  )
  AND column_name = 'siren_active';


-- ============================================================================
-- SECTION 38: ALARM AND SECURITY HISTORY
-- ============================================================================

SELECT
    event_type,
    message,
    severity,
    created_at
FROM pyroguard_event_history
WHERE event_type IN (
    'ARMED',
    'DISARMED',
    'SIREN_ON',
    'SIREN_OFF',
    'DOOR_OPEN'
)
ORDER BY created_at DESC
LIMIT 20;


-- ============================================================================
-- SECTION 39: DEVICE COMMANDS
-- ============================================================================

SELECT
    id,
    command,
    status,
    result_message,
    created_at,
    applied_at
FROM pyroguard_device_commands
ORDER BY created_at DESC
LIMIT 10;


-- ============================================================================
-- SECTION 40: DATABASE RECORD COUNTS
-- ============================================================================

SELECT
    'admin_accounts' AS table_name,
    COUNT(*) AS total_records
FROM pyroguard_admin_accounts

UNION ALL

SELECT
    'profiles',
    COUNT(*)
FROM pyroguard_profiles

UNION ALL

SELECT
    'account_identities',
    COUNT(*)
FROM pyroguard_account_identities

UNION ALL

SELECT
    'devices',
    COUNT(*)
FROM pyroguard_devices

UNION ALL

SELECT
    'device_commands',
    COUNT(*)
FROM pyroguard_device_commands

UNION ALL

SELECT
    'sensor_readings',
    COUNT(*)
FROM pyroguard_sensor_readings

UNION ALL

SELECT
    'sensor_history',
    COUNT(*)
FROM pyroguard_sensor_history

UNION ALL

SELECT
    'event_history',
    COUNT(*)
FROM pyroguard_event_history

UNION ALL

SELECT
    'support_tickets',
    COUNT(*)
FROM pyroguard_support_tickets

UNION ALL

SELECT
    'support_ticket_messages',
    COUNT(*)
FROM pyroguard_support_ticket_messages

UNION ALL

SELECT
    'support_ticket_events',
    COUNT(*)
FROM pyroguard_support_ticket_events;


-- ============================================================================
-- SECTION 41: ARCHIVE STATUS
-- ============================================================================

SELECT
    source_table,
    COUNT(*) AS archived_rows,
    SUM(CASE WHEN is_deleted = TRUE THEN 1 ELSE 0 END)
        AS deletion_tombstones
FROM pyroguard_local_source_records
GROUP BY source_table
ORDER BY source_table;


-- ============================================================================
-- SECTION 42: LEGACY TABLE CHECK
-- Detect historical unprefixed tables.
-- These are not used as replacements for the worker's prefixed mirror tables.
-- No existing records are modified.
-- ============================================================================

SELECT
    table_name AS legacy_table
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN (
      'admin_accounts',
      'profiles',
      'account_identities'
  )
ORDER BY table_name;


-- ============================================================================
-- SECTION 43: REQUIRED TABLE PRESENCE
-- ============================================================================

SELECT
    required.table_name,
    CASE
        WHEN installed.table_name IS NOT NULL THEN 'EXISTS'
        ELSE 'MISSING'
    END AS status
FROM (
    SELECT 'pyroguard_admin_accounts' AS table_name
    UNION ALL SELECT 'pyroguard_profiles'
    UNION ALL SELECT 'pyroguard_account_identities'
    UNION ALL SELECT 'pyroguard_device_current_state'
    UNION ALL SELECT 'pyroguard_device_commands'
    UNION ALL SELECT 'pyroguard_support_tickets'
    UNION ALL SELECT 'pyroguard_support_ticket_messages'
    UNION ALL SELECT 'pyroguard_support_ticket_events'
    UNION ALL SELECT 'pyroguard_local_source_records'
) AS required
LEFT JOIN information_schema.tables AS installed
    ON installed.table_schema = DATABASE()
   AND installed.table_name = required.table_name
ORDER BY required.table_name;


SELECT
    'MYSQL SCHEMA SCRIPT COMPLETED' AS execution_status,
    DATABASE() AS database_name,
    CURRENT_TIMESTAMP(3) AS checked_at;


-- ============================================================================
-- >>> 2026-11-04b MYSQL SYNC FIX
-- (same as migrations/20261104b_mysql_sync_fix.sql)
-- ============================================================================

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
