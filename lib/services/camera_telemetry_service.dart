import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';

class CameraTelemetry {
  final dynamic id;
  final String deviceId;
  final String cameraDeviceId;
  final String cameraIp;
  final String status;
  final bool motionDetected;
  final int motionPixels;
  final int panAngle;
  final int tiltAngle;
  final int wifiRssi;
  final int uptimeMs;
  final DateTime createdAt;

  const CameraTelemetry({
    this.id,
    required this.deviceId,
    required this.cameraDeviceId,
    required this.cameraIp,
    required this.status,
    required this.motionDetected,
    required this.motionPixels,
    required this.panAngle,
    required this.tiltAngle,
    required this.wifiRssi,
    required this.uptimeMs,
    required this.createdAt,
  });

  factory CameraTelemetry.fromMap(Map<String, dynamic> m) => CameraTelemetry(
        id: m['id'],
        deviceId: (m['device_id'] ?? '').toString(),
        cameraDeviceId: (m['camera_device_id'] ?? PyroGuardConfig.cameraDeviceId).toString(),
        cameraIp: (m['camera_ip'] ?? '').toString(),
        status: (m['status'] ?? 'unknown').toString(),
        motionDetected: m['motion_detected'] as bool? ?? false,
        motionPixels: (m['motion_pixels'] as num?)?.toInt() ?? 0,
        panAngle: (m['pan_angle'] as num?)?.toInt() ?? 90,
        tiltAngle: (m['tilt_angle'] as num?)?.toInt() ?? 90,
        wifiRssi: (m['wifi_rssi'] as num?)?.toInt() ?? 0,
        uptimeMs: (m['uptime_ms'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse((m['updated_at'] ?? m['created_at'] ?? '').toString()) ?? DateTime.now(),
      );

  bool get isFresh =>
      DateTime.now().difference(createdAt) <= PyroGuardConfig.cameraHeartbeatFreshness;
}

class CameraTelemetryService extends ChangeNotifier {
  CameraTelemetryService._();
  static final CameraTelemetryService instance = CameraTelemetryService._();

  CameraTelemetry? _latest;
  List<CameraTelemetry> _history = [];
  StreamSubscription? _sub;
  String? _lastError;

  CameraTelemetry? get latest => _latest;
  List<CameraTelemetry> get history => List.unmodifiable(_history);
  bool get online => _latest?.isFresh == true && _latest?.status.toLowerCase() == 'online';
  String get cameraIp => (_latest?.cameraIp.isNotEmpty == true)
      ? _latest!.cameraIp
      : PyroGuardConfig.cameraFallbackIp;
  String? get lastError => _lastError;

  void startListening() {
    _sub?.cancel();
    _sub = Supabase.instance.client
        .from(PyroGuardConfig.cameraTelemetryTable)
        .stream(primaryKey: ['id'])
        .order('updated_at', ascending: false)
        .limit(1)
        .listen(
      (rows) {
        _lastError = null;
        _history = rows.map(CameraTelemetry.fromMap).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        _latest = _history.isEmpty ? null : _history.first;
        notifyListeners();
      },
      onError: (e) {
        _lastError = '$e';
        debugPrint('CameraTelemetryService: $e');
        notifyListeners();
      },
    );
  }

  Future<void> refresh() async {
    try {
      final rows = await Supabase.instance.client
          .from(PyroGuardConfig.cameraTelemetryTable)
          .select()
          .order('updated_at', ascending: false)
          .limit(1) as List;
      _history = rows.cast<Map<String, dynamic>>().map(CameraTelemetry.fromMap).toList();
      _latest = _history.isEmpty ? null : _history.first;
      _lastError = null;
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      debugPrint('CameraTelemetryService refresh: $e');
      notifyListeners();
    }
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
  }
}
