import '../../services/room_sensor_service.dart';

class ControllerSnapshot {
  final String id;
  /// Latest stored reading per physical room; never fabricate missing rooms.
  final Map<String, Map<String, dynamic>> roomReadings;
  final Map<String, dynamic>? data;
  final Map<String, dynamic>? health;
  final DateTime? sampledAt;
  final DateTime? heartbeatAt;
  const ControllerSnapshot(this.id, this.data, this.health, this.sampledAt, this.heartbeatAt, {this.roomReadings = const {}});
  static const freshness = Duration(minutes: 2);
  bool _recent(DateTime? dt) => dt != null && !dt.isAfter(DateTime.now().toUtc().add(const Duration(seconds: 10))) && DateTime.now().toUtc().difference(dt) <= freshness;
  bool get sensorFeedFresh => roomReadings.values.any((row) => _recent(
      DateTime.tryParse('${row['received_at'] ?? row['sampled_at'] ?? ''}')?.toUtc()));
  bool get readingFresh => sensorFeedFresh || (data != null && _recent(sampledAt));
  bool get heartbeatFresh => health != null && _recent(heartbeatAt);
  bool get connected => sensorFeedFresh || heartbeatFresh || readingFresh;
  String get connectionText => sensorFeedFresh && heartbeatFresh
      ? 'SENSORS + HEARTBEAT LIVE'
      : sensorFeedFresh ? 'SENSOR FEED LIVE'
      : heartbeatFresh ? 'HEARTBEAT LIVE / SENSOR STALE'
      : readingFresh ? 'STATE READING LIVE' : 'OFFLINE / NO DATA';
  dynamic field(String key) => data != null && _recent(sampledAt) ? data![key] : null;
  bool roomFresh(Map<String, dynamic> row) => _recent(
      DateTime.tryParse('${row['received_at'] ?? row['sampled_at'] ?? ''}')?.toUtc());
  String display(String key, {String suffix = ''}) {
    if (const ['temperature', 'humidity', 'smoke_status', 'flame_detected', 'buzzer_active'].contains(key)) {
      final values = <String>[];
      for (final entry in roomReadings.entries) {
        if (!roomFresh(entry.value)) continue;
        final v = entry.value[key];
        if (v == null) continue;
        final displayed = v is bool
            ? (key == 'buzzer_active' ? (v ? 'ON' : 'OFF') : (v ? 'DETECTED' : 'CLEAR'))
            : '$v$suffix';
        values.add('${entry.key.toUpperCase()}: $displayed');
      }
      if (values.isNotEmpty) return values.join(' | ');
    }
    final v = field(key);
    if (v == null) return 'NO FRESH DATA';
    if (v is bool) {
      if (key == 'buzzer_active' || key == 'siren_active') return v ? 'ON' : 'OFF';
      return v ? 'ON / DETECTED' : 'OFF / CLEAR';
    }
    return '$v$suffix';
  }
  // "Critical" here means multiple independent sensor thresholds;
  // an isolated flame contact remains a visible warning, not proof of fire.
  // Same rule as the siren / BFP card: the controller confirmed smoke AND
  // flame in that room (fire_confirmed), no faulty sensor. Temperature alone
  // or flame + heat never counts as a fire.
  bool get critical => roomReadings.values.any((row) =>
      roomFresh(row) && RoomSensorService.confirmedFire(row));
}
class CameraSnapshot {
  final String id;
  final DateTime? lastSeen;
  final String? status;
  final double? temperature;
  const CameraSnapshot(this.id, this.lastSeen, this.status, this.temperature);
  bool get online => status?.toLowerCase() == 'online' && lastSeen != null &&
      DateTime.now().toUtc().difference(lastSeen!) >= Duration.zero &&
      DateTime.now().toUtc().difference(lastSeen!) <= const Duration(minutes: 2);
}
class DashboardSnapshot {
  final ControllerSnapshot main;
  final ControllerSnapshot secondary;
  final CameraSnapshot camera1;
  final bool supabaseReachable;
  final String mysqlLabel;
  const DashboardSnapshot(this.main,this.secondary,this.camera1,this.supabaseReachable,this.mysqlLabel);
  int get connectedControllers => [main,secondary].where((e)=>e.connected).length;
  String get coverage => connectedControllers == 2 ? 'BOTH CONTROLLERS REPORTING' : connectedControllers == 1 ? 'PARTIAL COVERAGE — ONE CONTROLLER REPORTING' : 'NO FRESH CONTROLLER TELEMETRY';
}
class AnalyticsSummary {
  final int total, fire, warning, normal;
  final Map<String, int> byDevice;
  final List<Map<String,dynamic>> history;
  const AnalyticsSummary(this.total,this.fire,this.warning,this.normal,this.byDevice,this.history);
}
