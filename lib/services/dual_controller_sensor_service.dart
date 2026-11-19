import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'sensor_service.dart';

/// Each controller has its own telemetry + heartbeat. Never use one
/// controller's sensor values or heartbeat for the other controller.
class DualControllerSensorService extends ChangeNotifier {
  DualControllerSensorService._();
  static final instance = DualControllerSensorService._();

  final Map<String, SensorReading> _readings = {};
  final Map<String, Map<String, dynamic>> _raw = {};
  final Map<String, DateTime> _heartbeats = {};
  Timer? _timer;
  bool _busy = false;
  String? lastError;
  static const ids = <String>[
    PyroGuardConfig.mainDeviceId,
    PyroGuardConfig.secondaryControllerDeviceId,
  ];

  SensorReading? latest(String deviceId) => _readings[deviceId];
  /// Original database values: null means no measurement was reported.
  /// Avoid SensorReading.fromMap numeric defaults being shown as measured zero.
  Map<String, dynamic>? raw(String deviceId) => _raw[deviceId];
  bool hasValue(String deviceId, String field) =>
      _raw[deviceId]?[field] != null;
  String display(String deviceId, String field, {String suffix = ''}) {
    if (!isFresh(deviceId)) return 'NO FRESH DATA';
    final value = _raw[deviceId]?[field];
    if (value == null || value.toString().trim().isEmpty) return 'NOT REPORTED';
    if (value is bool) return value ? 'DETECTED / ON' : 'CLEAR / OFF';
    return '$value$suffix';
  }
  String get overallStatus {
    final fresh = ids.where(isFresh).toList();
    if (fresh.length != ids.length) return 'PARTIAL COVERAGE / CHECK CONTROLLERS';
    for (final id in ids) {
      final raw = _raw[id] ?? const <String,dynamic>{};
      // The buzzer is an output (door chimes use it) and a lone flame/smoke
      // signal is only a warning, so only the server's alert level counts.
      final alert = (raw['alert_status'] ?? '').toString().toUpperCase();
      if (alert == 'CRITICAL' || alert == 'WARNING' || alert == 'INTRUSION') {
        return 'ALERT — CHECK ${id == ids.first ? 'MAIN' : 'SECONDARY'}';
      }
    }
    return 'BOTH CONTROLLERS REPORTING';
  }
  DateTime? lastHeartbeat(String deviceId) => _heartbeats[deviceId];
  bool isFresh(String deviceId) {
    final reading = _readings[deviceId];
    if (reading == null || reading.heartbeatState == HeartbeatState.offline) return false;
    final beat = _heartbeats[deviceId];
    // Telemetry freshness must be genuine. Heartbeat is an additional check
    // when available; absence is not proof of a running board.
    return beat == null ||
        (DateTime.now().difference(beat.toLocal()).inSeconds >= 0 &&
         DateTime.now().difference(beat.toLocal()) <= PyroGuardConfig.deviceHeartbeatFreshness);
  }

  void start() {
    if (_timer != null) return;
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
  }

  void stop() { _timer?.cancel(); _timer = null; }

  Future<void> refresh() async {
    if (_busy || Supabase.instance.client.auth.currentUser == null) return;
    _busy = true;
    try {
      final db = Supabase.instance.client;
      for (final id in ids) {
        // RLS ensures the current account may only read authorized home devices.
        final state = await db.from(PyroGuardConfig.sensorTelemetryTable)
            .select().eq('device_id', id)
            .order('updated_at', ascending: false).limit(1);
        if (state.isEmpty) {
          _readings.remove(id);
          _raw.remove(id);
        } else {
          _raw[id] = Map<String, dynamic>.from(state.first);
          _readings[id] = SensorReading.fromMap(_raw[id]!);
        }
        final heartbeats = await db.from(PyroGuardConfig.deviceHeartbeatTable)
            .select('updated_at').eq('device_id', id)
            .order('updated_at', ascending: false).limit(1);
        if (heartbeats.isEmpty) {
          _heartbeats.remove(id);
        } else {
          final time = DateTime.tryParse((heartbeats.first['updated_at'] ?? '').toString());
          if (time == null) { _heartbeats.remove(id); } else { _heartbeats[id] = time; }
        }
      }
      lastError = null;
    } catch (e) {
      lastError = e.toString();
      debugPrint('Dual-controller telemetry: $e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
