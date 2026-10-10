import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'historical_service.dart';
import 'notification_service.dart';

enum IncidentClass { normal, dustOrCooking, realFire }

enum HeartbeatState { online, delayed, offline }

class SensorReading {
  final String id;
  final DateTime createdAt;
  final String deviceId;
  final double smokeLevel;
  final int smokeRaw;
  final String smokeStatus;
  final bool flameStatus;
  final double temperature;
  final double humidity;
  final String incidentType;
  final int severityLevel;
  final String alertStatus;
  final String? location;
  final double? deviceLat;
  final double? deviceLng;

  // Optional home-security fields. They remain UNKNOWN until the firmware
  // starts sending them; the UI never invents CLOSED/NONE values.
  final String doorStatus;
  final String windowStatus;
  final bool? motionDetected;
  final bool? systemArmed;

  const SensorReading({
    required this.id,
    required this.createdAt,
    required this.deviceId,
    required this.smokeLevel,
    required this.smokeRaw,
    required this.smokeStatus,
    required this.flameStatus,
    required this.temperature,
    required this.humidity,
    required this.incidentType,
    required this.severityLevel,
    required this.alertStatus,
    required this.doorStatus,
    required this.windowStatus,
    required this.motionDetected,
    required this.systemArmed,
    this.location,
    this.deviceLat,
    this.deviceLng,
  });

  static bool _asBool(dynamic value) {
    if (value is bool) return value;
    final s = value?.toString().trim().toLowerCase();
    return s == 'true' || s == '1' || s == 'detected' || s == 'yes' || s == 'on';
  }

  static bool? _asNullableBool(dynamic value) {
    if (value == null) return null;
    if (value is bool) return value;
    final s = value.toString().trim().toLowerCase();
    if (['true', '1', 'detected', 'yes', 'on', 'armed', 'arm_home', 'arm_away'].contains(s)) return true;
    if (['false', '0', 'none', 'no', 'off', 'disarmed'].contains(s)) return false;
    return null;
  }

  static int _severityFrom(
    dynamic explicit,
    String alert,
    bool flame,
    double smokePct,
  ) {
    if (explicit is num) return explicit.toInt().clamp(0, 2).toInt();
    final a = alert.toUpperCase();
    if (a.contains('CRITICAL') || a.contains('FIRE') || a.contains('DANGER')) return 2;
    if (a.contains('CAUTION') || a.contains('WARN') || a.contains('ALERT')) return 1;
    if (flame && smokePct >= 60) return 2;
    if (smokePct >= 40) return 1;
    return 0;
  }

  factory SensorReading.fromMap(Map<String, dynamic> m) {
    final raw = (m['smoke_raw'] as num?)?.toInt() ??
        (m['mq2_raw'] as num?)?.toInt() ??
        0;
    final explicitPct = (m['smoke_level'] as num?)?.toDouble();
    final smokePct = explicitPct != null
        ? explicitPct.clamp(0, 100).toDouble()
        : ((raw / 4095.0) * 100.0).clamp(0, 100).toDouble();
    final flame = _asBool(m['flame_detected'] ?? m['flame_status']);
    final alert = (m['alert_status'] ?? m['alert'] ?? '').toString();
    final smokeStatus = (m['smoke_status'] ?? '').toString();
    final severity = _severityFrom(m['severity_level'], alert, flame, smokePct);
    final incident = (m['incident_type'] as String?) ??
        (severity == 2
            ? 'Fire Detected'
            : severity == 1
                ? (smokeStatus.isNotEmpty ? smokeStatus : 'Smoke Warning')
                : 'Normal');

    return SensorReading(
      id: (m['id'] ?? '').toString(),
      createdAt: DateTime.tryParse(
            (m['updated_at'] ?? m['created_at'] ?? m['recorded_at'] ?? '').toString(),
          ) ??
          DateTime.now(),
      deviceId: (m['device_id'] ?? 'pyroguard_sensor').toString(),
      smokeLevel: smokePct,
      smokeRaw: raw,
      smokeStatus: smokeStatus.isEmpty
          ? (smokePct >= 40 ? 'WARNING' : 'SAFE')
          : smokeStatus,
      flameStatus: flame,
      temperature: (m['temperature'] as num?)?.toDouble() ?? 0,
      humidity: (m['humidity'] as num?)?.toDouble() ?? 0,
      incidentType: incident,
      severityLevel: severity,
      alertStatus: alert.isEmpty
          ? (severity == 2
              ? 'CRITICAL'
              : severity == 1
                  ? 'CAUTION'
                  : 'SAFE')
          : alert,
      location: m['location'] as String?,
      deviceLat: (m['device_lat'] as num?)?.toDouble() ??
          (m['latitude'] as num?)?.toDouble(),
      deviceLng: (m['device_lng'] as num?)?.toDouble() ??
          (m['longitude'] as num?)?.toDouble(),
      doorStatus: (m['door_status'] ?? 'UNKNOWN').toString().toUpperCase(),
      windowStatus: (m['window_status'] ?? 'UNKNOWN').toString().toUpperCase(),
      motionDetected: _asNullableBool(m['motion_detected'] ?? m['motion']),
      systemArmed: _asNullableBool(m['system_armed'] ?? m['armed'] ?? m['system_mode']),
    );
  }

  bool get isCriticalFire => severityLevel == 2;
  bool get isWarning => severityLevel == 1;
  bool get isNormal => severityLevel == 0;

  Duration get age => DateTime.now().difference(createdAt.toLocal());

  HeartbeatState get heartbeatState {
    if (age <= PyroGuardConfig.sensorHeartbeatDelayedAfter) {
      return HeartbeatState.online;
    }
    if (age <= PyroGuardConfig.sensorHeartbeatFreshness) {
      return HeartbeatState.delayed;
    }
    return HeartbeatState.offline;
  }

  IncidentClass get classification {
    if (isCriticalFire) return IncidentClass.realFire;
    if (isWarning) return IncidentClass.dustOrCooking;
    return IncidentClass.normal;
  }

  String get classLabel {
    switch (classification) {
      case IncidentClass.realFire:
        return 'REAL FIRE';
      case IncidentClass.dustOrCooking:
        return incidentType;
      case IncidentClass.normal:
        return 'Normal';
    }
  }
}

class SensorService extends ChangeNotifier {
  SensorService._();
  static final SensorService instance = SensorService._();

  SensorReading? _latest;
  List<SensorReading> _history = [];
  StreamSubscription? _sub;
  bool _alarmActive = false;
  bool _warningActive = false;
  String? _activeTable;
  String? _lastError;
  String? _historyError;
  bool _starting = false;
  bool _historyLoading = false;

  SensorReading? get latest => _latest;
  List<SensorReading> get history => List.unmodifiable(_history);
  bool get alarmActive => _alarmActive;
  bool get warningActive => _warningActive;
  String? get activeTable => _activeTable;
  String? get lastError => _lastError;
  String? get historyError => _historyError;
  bool get historyLoading => _historyLoading;
  bool get historyApiConfigured => HistoricalService.instance.isConfigured;

  HeartbeatState get realtimeHeartbeat =>
      _latest?.heartbeatState ?? HeartbeatState.offline;

  String get _deviceId {
    final raw = Supabase.instance.client.auth.currentUser?.userMetadata?['device_id'];
    final id = raw?.toString().trim();
    return id == null || id.isEmpty ? PyroGuardConfig.mainDeviceId : id;
  }

  void startListening() {
    if (_starting) return;
    _starting = true;
    _start().whenComplete(() => _starting = false);
  }

  Future<void> _start() async {
    await _sub?.cancel();
    _sub = null;

    // Historical records are retained in BOTH Supabase and MySQL. The history
    // service reads Supabase first and can fall back to the MySQL mirror.
    await refreshHistory();

    // Supabase Realtime is the live transport used by Flutter. Important
    // sensor snapshots are also written to both Supabase and MySQL by firmware.
    final candidates = <String>[
      PyroGuardConfig.sensorTelemetryTable,
      PyroGuardConfig.legacySensorTelemetryTable,
    ];

    for (final table in candidates) {
      try {
        final timeColumn = table == PyroGuardConfig.sensorTelemetryTable
            ? 'updated_at'
            : 'created_at';
        final initial = await Supabase.instance.client
            .from(table)
            .select()
            .eq('device_id', _deviceId)
            .order(timeColumn, ascending: false)
            .limit(1) as List;
        _activeTable = table;
        _lastError = null;
        _applyRealtimeRows(initial.cast<Map<String, dynamic>>());

        _sub = Supabase.instance.client
            .from(table)
            .stream(primaryKey: ['id'])
            .eq('device_id', _deviceId)
            .order(timeColumn, ascending: false)
            .limit(1)
            .listen(
          _applyRealtimeRows,
          onError: (e) {
            _lastError = '$e';
            debugPrint('SensorService realtime ($table): $e');
            notifyListeners();
          },
        );
        return;
      } catch (e) {
        debugPrint('SensorService realtime table $table unavailable: $e');
        _lastError = '$e';
      }
    }
    notifyListeners();
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
  }

  void _applyRealtimeRows(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      notifyListeners();
      return;
    }

    final readings = rows.map(SensorReading.fromMap).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final reading = readings.first;
    final wasAlarm = _alarmActive;
    final wasWarning = _warningActive;
    _latest = reading;

    // A stale database row is historical context, not live sensing. This is
    // especially important before the physical ESP32 is connected: the app
    // may be online while hardware telemetry is still unavailable.
    if (reading.heartbeatState == HeartbeatState.offline) {
      _alarmActive = false;
      _warningActive = false;
      NotificationService.cancelAlarm();
      notifyListeners();
      return;
    }

    if (reading.isCriticalFire) {
      _warningActive = false;
      if (!wasAlarm) {
        _alarmActive = true;
        NotificationService.triggerFireAlarm(reading);
      }
    } else if (reading.isWarning) {
      _alarmActive = false;
      if (!wasWarning) {
        _warningActive = true;
        NotificationService.triggerWarning(reading);
      }
      NotificationService.cancelAlarm();
    } else {
      if (_alarmActive || _warningActive) {
        _alarmActive = false;
        _warningActive = false;
        NotificationService.cancelAlarm();
      }
    }

    notifyListeners();
  }

  void manualResetAlarm() {
    _alarmActive = false;
    _warningActive = false;
    NotificationService.cancelAlarm();
    notifyListeners();
  }

  Future<void> refreshHistory({int limit = 300}) async {
    _historyLoading = true;
    notifyListeners();
    try {
      final rows = await HistoricalService.instance.fetchSensorHistory(limit: limit);
      _history = rows.map(SensorReading.fromMap).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _historyError = null;
    } catch (e) {
      _historyError = '$e';
      debugPrint('Dual-backend history load failed: $e');
    } finally {
      _historyLoading = false;
      notifyListeners();
    }
  }

  Future<List<SensorReading>> fetchHistory({int limit = 300}) async {
    try {
      final rows = await HistoricalService.instance.fetchSensorHistory(limit: limit);
      final parsed = rows.map(SensorReading.fromMap).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _history = parsed;
      _historyError = null;
      notifyListeners();
      return parsed;
    } catch (e) {
      _historyError = '$e';
      notifyListeners();
      rethrow;
    }
  }

  Map<String, int> get incidentCounts {
    final counts = <String, int>{
      'Fire Detected': 0,
      'Dust/Smoke': 0,
      'Cooking Smoke': 0,
      'Normal': 0,
    };
    for (final reading in _history) {
      counts[reading.incidentType] = (counts[reading.incidentType] ?? 0) + 1;
    }
    return counts;
  }

  double get avgSmoke => _history.isEmpty
      ? 0
      : _history.map((r) => r.smokeLevel).reduce((a, b) => a + b) /
          _history.length;

  double get avgTemp => _history.isEmpty
      ? 0
      : _history.map((r) => r.temperature).reduce((a, b) => a + b) /
          _history.length;

  double get maxSmoke => _history.isEmpty
      ? 0
      : _history
          .map((r) => r.smokeLevel)
          .reduce((a, b) => a > b ? a : b);
}
