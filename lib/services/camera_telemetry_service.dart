
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
  final String wifiSsid;
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
    required this.wifiSsid,
    required this.uptimeMs,
    required this.createdAt,
  });

  factory CameraTelemetry.fromMap(
    Map<String, dynamic> map,
  ) {
    int readInt(dynamic value, int fallback) {
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ??
          fallback;
    }

    final timestamp = DateTime.tryParse(
      (map['updated_at'] ??
              map['created_at'] ??
              '')
          .toString(),
    );

    return CameraTelemetry(
      id: map['id'],
      deviceId: (map['device_id'] ?? '').toString(),
      cameraDeviceId:
          (map['camera_device_id'] ?? '').toString(),
      cameraIp: (map['camera_ip'] ?? '').toString(),
      status: (map['status'] ?? 'unknown').toString(),
      motionDetected:
          map['motion_detected'] as bool? ?? false,
      motionPixels:
          readInt(map['motion_pixels'], 0),
      panAngle: readInt(map['pan_angle'], 90),
      tiltAngle: readInt(map['tilt_angle'], 90),
      wifiRssi: readInt(map['wifi_rssi'], 0),
      wifiSsid: (map['wifi_ssid'] ?? map['ssid'] ?? map['wifi_name'] ?? map['network_name'] ?? '').toString(),
      uptimeMs: readInt(map['uptime_ms'], 0),
      createdAt: timestamp?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(
            0,
            isUtc: true,
          ),
    );
  }

  bool get isFresh {
    final age = DateTime.now()
        .toUtc()
        .difference(createdAt);

    return !age.isNegative &&
        age <= PyroGuardConfig.cameraHeartbeatFreshness;
  }
}

class CameraTelemetryService extends ChangeNotifier {
  CameraTelemetryService._();

  static final CameraTelemetryService instance =
      CameraTelemetryService._();

  CameraTelemetry? _latest;
  List<CameraTelemetry> _history = [];

  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  Timer? _refreshTimer;

  String? _lastError;
  bool _refreshing = false;

  CameraTelemetry? get latest => _latest;

  List<CameraTelemetry> get history =>
      List.unmodifiable(_history);

  String? get lastError => _lastError;

  bool get online {
    final current = _latest;

    return current != null &&
        current.cameraDeviceId ==
            PyroGuardConfig.cameraDeviceId &&
        current.status.trim().toLowerCase() ==
            'online' &&
        current.isFresh;
  }

  String get cameraIp {
    final ip = _latest?.cameraIp ?? '';

    return ip.isNotEmpty
        ? ip
        : PyroGuardConfig.cameraFallbackIp;
  }

  void _applyRows(
    List<Map<String, dynamic>> rows,
  ) {
    final records = rows
        .map(CameraTelemetry.fromMap)
        .where(
          (item) =>
              item.cameraDeviceId ==
              PyroGuardConfig.cameraDeviceId,
        )
        .toList()
      ..sort(
        (a, b) =>
            b.createdAt.compareTo(a.createdAt),
      );

    _history = records;
    _latest =
        records.isEmpty ? null : records.first;

    _lastError = null;

    debugPrint(
      'Camera telemetry: '
      'records=${records.length}, '
      'online=$online, '
      'device=${_latest?.cameraDeviceId}, '
      'status=${_latest?.status}, '
      'lastSeen=${_latest?.createdAt}',
    );

    notifyListeners();
  }

  void startListening() {
    _sub?.cancel();
    _refreshTimer?.cancel();

    final client = Supabase.instance.client;

    _sub = client
        .from(PyroGuardConfig.cameraTelemetryTable)
        .stream(primaryKey: ['id'])
        .eq(
          'camera_device_id',
          PyroGuardConfig.cameraDeviceId,
        )
        .order(
          'updated_at',
          ascending: false,
        )
        .limit(1)
        .listen(
      (rows) {
        _applyRows(rows);
      },
      onError: (Object error) {
        _lastError = error.toString();

        debugPrint(
          'Camera telemetry stream error: $error',
        );

        notifyListeners();
      },
    );

    // Refresh independently of Realtime events.
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => refresh(),
    );

    refresh();
  }

  Future<void> refresh() async {
    if (_refreshing) return;

    final client = Supabase.instance.client;

    if (client.auth.currentSession == null) {
      _lastError = 'User is not authenticated';
      debugPrint(_lastError);
      notifyListeners();
      return;
    }

    _refreshing = true;

    try {
      final rows = await client
          .from(PyroGuardConfig.cameraTelemetryTable)
          .select()
          .eq(
            'camera_device_id',
            PyroGuardConfig.cameraDeviceId,
          )
          .order(
            'updated_at',
            ascending: false,
          )
          .limit(1);

      _applyRows(
        List<Map<String, dynamic>>.from(rows),
      );
    } catch (error) {
      _lastError = error.toString();

      debugPrint(
        'Camera telemetry refresh error: $error',
      );

      notifyListeners();
    } finally {
      _refreshing = false;
    }
  }

  void stopListening() {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    _sub?.cancel();
    _sub = null;
  }
}
