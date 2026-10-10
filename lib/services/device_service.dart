import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'sensor_service.dart' show HeartbeatState;

/// One heartbeat row reported by the ESP32-S3 (see device_heartbeats in
/// supabase_setup_v4.sql). Every field defaults to false/null so an
/// absent or partial heartbeat never gets silently read as "ready".
class DeviceHealth {
  final bool wifiOk, supabaseOk, cameraOk, ptzOk, micOk, speakerOk;
  final bool pirOk, doorOk, windowOk, ultrasonicOk, mq2Ok, flameOk, dht22Ok, gpsOk, gsmOk, sirenOk;
  final int? uptimeSecs;
  final double? batteryPct;
  final String? localIp; // for opening the local-network live video/audio streams
  final DateTime reportedAt;

  const DeviceHealth({
    required this.wifiOk, required this.supabaseOk, required this.cameraOk,
    required this.ptzOk, required this.micOk, required this.speakerOk,
    required this.pirOk, required this.doorOk, required this.windowOk, required this.ultrasonicOk,
    required this.mq2Ok, required this.flameOk, required this.dht22Ok, required this.gpsOk, required this.gsmOk,
    required this.sirenOk, this.uptimeSecs, this.batteryPct, this.localIp,
    required this.reportedAt,
  });

  factory DeviceHealth.fromMap(Map<String, dynamic> m) => DeviceHealth(
        wifiOk: m['wifi_ok'] as bool? ?? false,
        supabaseOk: m['supabase_ok'] as bool? ?? false,
        cameraOk: m['camera_ok'] as bool? ?? false,
        ptzOk: m['ptz_ok'] as bool? ?? false,
        micOk: m['mic_ok'] as bool? ?? false,
        speakerOk: m['speaker_ok'] as bool? ?? false,
        pirOk: m['pir_ok'] as bool? ?? false,
        doorOk: m['door_ok'] as bool? ?? false,
        windowOk: m['window_ok'] as bool? ?? false,
        ultrasonicOk: m['ultrasonic_ok'] as bool? ?? false,
        mq2Ok: m['mq2_ok'] as bool? ?? false,
        flameOk: m['flame_ok'] as bool? ?? false,
        dht22Ok: m['dht22_ok'] as bool? ?? false,
        gpsOk: m['gps_ok'] as bool? ?? false,
        gsmOk: m['gsm_ok'] as bool? ?? false,
        sirenOk: m['siren_ok'] as bool? ?? false,
        uptimeSecs: (m['uptime_secs'] as num?)?.toInt(),
        batteryPct: (m['battery_pct'] as num?)?.toDouble(),
        localIp: m['local_ip'] as String?,
        reportedAt: DateTime.tryParse((m['updated_at'] ?? m['created_at'] ?? '').toString()) ?? DateTime.now(),
      );

  Duration get age => DateTime.now().difference(reportedAt.toLocal());

  HeartbeatState get heartbeatState {
    if (age <= PyroGuardConfig.deviceHeartbeatDelayedAfter) {
      return HeartbeatState.online;
    }
    if (age <= PyroGuardConfig.deviceHeartbeatFreshness) {
      return HeartbeatState.delayed;
    }
    return HeartbeatState.offline;
  }

  bool get isFresh => heartbeatState != HeartbeatState.offline;
}

/// Streams the latest device_heartbeats row for [kDefaultDeviceId].
///
/// Until real firmware is flashed and posting heartbeats, [latest] stays
/// null and [online] stays false — this is intentional: the UI should
/// show "no heartbeat yet" rather than invent a healthy-looking status.
class DeviceService extends ChangeNotifier {
  DeviceService._();
  static final DeviceService instance = DeviceService._();

  String get deviceId {
    final raw = Supabase.instance.client.auth.currentUser?.userMetadata?['device_id'];
    final id = raw?.toString().trim();
    return id == null || id.isEmpty ? PyroGuardConfig.mainDeviceId : id;
  }
  DeviceHealth? _latest;
  StreamSubscription? _sub;

  DeviceHealth? get latest => _latest;
  bool get online => _latest?.isFresh ?? false;

  void startListening() {
    _sub?.cancel();
    _sub = Supabase.instance.client
        .from(PyroGuardConfig.deviceHeartbeatTable)
        .stream(primaryKey: ['id'])
        .eq('device_id', deviceId)
        .order('updated_at', ascending: false)
        .limit(1)
        .listen((rows) {
      if (rows.isEmpty) return;
      _latest = DeviceHealth.fromMap(rows.first);
      notifyListeners();
    }, onError: (e) => debugPrint('DeviceService heartbeat stream: $e'));
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
  }
}
