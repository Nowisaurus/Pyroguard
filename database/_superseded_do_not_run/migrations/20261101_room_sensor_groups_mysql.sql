-- Run in MySQL Workbench after backing up pyroguard_db.
USE pyroguard_db;
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
 sampled_at DATETIME(6) NOT NULL,
 received_at DATETIME(6) NULL,
 INDEX idx_pg_room_device (controller_device_id, room_key, sampled_at),
 INDEX idx_pg_room_user (user_id, sampled_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
