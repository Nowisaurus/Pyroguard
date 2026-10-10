class PyroGuardConfig {
  PyroGuardConfig._();

  // Local-network fallback IPs. Supabase telemetry can replace these at runtime.
  static const String mainEspFallbackIp = '192.168.8.107';
  static const String cameraFallbackIp = '192.168.8.115';
  static const String mainDeviceId = 'ESP32-001';
  static const String cameraDeviceId = 'pyroguard_camera_001';

  // SUPABASE receives auth identity plus the same persistent application state,
  // settings, commands, history, camera metadata and audit records mirrored to MySQL.
  static const String sensorTelemetryTable = 'device_current_state';
  static const String legacySensorTelemetryTable = 'sensor_readings';
  static const String cameraTelemetryTable = 'pyroguard_camera_telemetry';
  static const String deviceHeartbeatTable = 'device_heartbeats';
  static const String incidentMediaBucket = 'incident-media';

  // MYSQL receives the same persistent application data (current state mirrors,
  // configuration, commands, history, camera metadata and audits). Flutter never
  // receives MySQL credentials; this Edge Function owns the secure connection.
  // Passwords/tokens remain exclusively in Supabase Auth and are never duplicated.
  static const String mysqlHistoryFunction = 'mysql-history';

  // Tiered device-local protection. Failed attempts remain cumulative after
  // the one-minute lock; success or expiry of the 15-minute lock resets them.
  static const int maxLoginAttempts = 3;
  static const Duration loginLockDuration = Duration(minutes: 1);
  static const int extendedLoginAttempts = 10;
  static const Duration extendedLoginLockDuration = Duration(minutes: 15);

  // Realtime freshness thresholds.
  static const Duration localRequestTimeout = Duration(seconds: 5);
  static const Duration sensorHeartbeatFreshness = Duration(seconds: 30);
  static const Duration sensorHeartbeatDelayedAfter = Duration(seconds: 12);
  static const Duration deviceHeartbeatDelayedAfter = Duration(seconds: 45);
  static const Duration deviceHeartbeatFreshness = Duration(seconds: 75);
  static const Duration cameraHeartbeatFreshness = Duration(minutes: 2);

  // Shared responsive breakpoints used by the UI.
  static const double compactBreakpoint = 380;
  static const double phoneBreakpoint = 600;
  static const double tabletBreakpoint = 900;
  static const double desktopBreakpoint = 1180;
}
