import 'package:supabase_flutter/supabase_flutter.dart';
import 'dashboard_models.dart';
import '../../services/room_sensor_service.dart';
import '../../services/dual_sync_service.dart';

/// Read-only. Hardware writes must be made by the authenticated sensor-ingest backend.
/// Access depends on deployed Supabase RLS; membership is not a Flutter read filter.
class DashboardRepository {
  DashboardRepository(this.db);
  final SupabaseClient db;
  bool _lastSuccessfulRead = false;

  // MySQL mirror status, from the verified health check (mysql-history ->
  // local PC worker report). Cached so the dashboard's frequent refreshes do
  // not call the Edge Function every time.
  static String _mysqlLabel = 'CHECKING…';
  static DateTime? _mysqlCheckedAt;
  static const _mysqlCacheFor = Duration(seconds: 30);

  Future<String> _mysqlStatus() async {
    final checked = _mysqlCheckedAt;
    if (checked != null && DateTime.now().difference(checked) < _mysqlCacheFor) {
      return _mysqlLabel;
    }
    try {
      final h = await DualSyncService.instance.checkDatabaseCommunication();
      final ok = h['mysql'] == true;
      final parity = h['mysql_schema_parity'] == true;
      final count = h['mysql_table_count'];
      final expected = h['mysql_expected_table_count'];
      final error = '${h['error'] ?? ''}'.toLowerCase();
      if (ok && parity) {
        _mysqlLabel = 'VERIFIED';
      } else if (ok) {
        // Worker online and connected, but not every table verified yet
        // (e.g. 29/34 = some MySQL tables are missing).
        _mysqlLabel = count != null && expected != null ? 'SYNCING $count/$expected' : 'SYNCING';
      } else if (error.contains('offline') || error.contains('has not reported')) {
        _mysqlLabel = 'WORKER OFFLINE'; // npm start is not running
      } else if (error.contains('cannot connect to mysql')) {
        _mysqlLabel = 'MYSQL DISCONNECTED'; // worker running, check its .env
      } else if (error.contains('gateway') || error.contains('functionexception') || error.contains('404')) {
        _mysqlLabel = 'CHECK FAILED'; // mysql-history function missing/unreachable
      } else {
        _mysqlLabel = 'NOT VERIFIED';
      }
      if (_mysqlLabel != 'VERIFIED') {
        // ignore: avoid_print
        print('MySQL mirror status $_mysqlLabel: ${h['error'] ?? 'no error reported'}');
      }
    } catch (error) {
      // ignore: avoid_print
      print('DashboardRepository mysql health: $error');
      _mysqlLabel = 'NOT VERIFIED';
    }
    _mysqlCheckedAt = DateTime.now();
    return _mysqlLabel;
  }
  static const mainId = 'ESP32-001', secondaryId = 'ESP32-002';
  static const cam1 = 'pyroguard_camera_001'; // the only camera (two-way audio)
  static DateTime? parseTime(dynamic v) => v == null ? null : DateTime.tryParse('$v')?.toUtc();
  static Map<String,dynamic>? match(List<Map<String,dynamic>> items, String key, String id) {
    for (final item in items) { if (item[key] == id) return item; }
    return null;
  }
  // One unavailable table must not hide otherwise valid sensor data.
  Future<List<Map<String, dynamic>>> _safeRows(Future<dynamic> Function() query, String table) async {
    try {
      final result = await query() as List<dynamic>;
      _lastSuccessfulRead = true;
      return [for (final value in result) Map<String, dynamic>.from(value as Map)];
    } catch (error) {
      // Log the actual permission/table/network error; never report fake data.
      // ignore: avoid_print
      print('DashboardRepository $table: $error');
      return [];
    }
  }

  Future<DashboardSnapshot> load() async {
    _lastSuccessfulRead = false;
    final ids = [mainId, secondaryId];
    final mysqlLabelFuture = _mysqlStatus();
    final results = await Future.wait([
      _safeRows(() => db.from('device_current_state').select().inFilter('device_id', ids), 'device_current_state'),
      _safeRows(() => db.from('device_heartbeats').select().inFilter('device_id', ids), 'device_heartbeats'),
      _safeRows(() => db.from('pyroguard_camera_telemetry').select().eq('camera_device_id', cam1).order('created_at',ascending:false).limit(100), 'pyroguard_camera_telemetry'),
      // A separate query per room avoids one busy sensor masking another.
      for (final group in [
        (id: mainId, room: 'entrance'), (id: mainId, room: 'sala'),
        (id: secondaryId, room: 'kitchen'), (id: secondaryId, room: 'bedroom'),
      ])
        _safeRows(() => db.from('pyroguard_room_sensor_readings')
            .select('controller_device_id,room_key,temperature,humidity,smoke_status,flame_detected,buzzer_active,sampled_at,received_at')
            .eq('controller_device_id', group.id).eq('room_key', group.room)
            .order('received_at', ascending:false).limit(1), '${group.id}/${group.room}'),
    ]);
    final states = results[0], beats = results[1], cameras = results[2];
    ControllerSnapshot controller(String id) {
      final state = match(states, 'device_id', id);
      final beat = match(beats, 'device_id', id);
      final keys = id == mainId ? const ['entrance','sala'] : const ['kitchen','bedroom'];
      final latest = <String, Map<String, dynamic>>{};
      for (var i = 0; i < keys.length; i++) {
        final rows = results[3 + (id == secondaryId ? 2 : 0) + i];
        if (rows.isNotEmpty) latest[keys[i]] = rows.first;
      }
      return ControllerSnapshot(id, state, beat,
          parseTime(state?['updated_at']), parseTime(beat?['updated_at']),
          roomReadings: latest);
    }
    CameraSnapshot camera(String id) {
      final c=match(cameras,'camera_device_id',id);
      return CameraSnapshot(id,parseTime(c?['updated_at'] ?? c?['created_at']),c?['status']?.toString(),null);
    }
    // Supabase returned to the app, but source-specific failures are logged.
    return DashboardSnapshot(controller(mainId),controller(secondaryId),camera(cam1),_lastSuccessfulRead,await mysqlLabelFuture);
  }
  Future<AnalyticsSummary> analytics() async {
    // This sample is from real persisted room sensor records, not an empty
    // legacy sensor_history table. Total is capped at 1000 latest samples.
    final rows = await _safeRows(() => db.from('pyroguard_room_sensor_readings')
        .select('*')
        .inFilter('controller_device_id', [mainId, secondaryId])
        // Only readings from the false-fire-guarded firmware; older rows
        // (fire_confirmed NULL) contained noise and are left out.
        .not('fire_confirmed', 'is', null)
        .order('received_at', ascending:false).limit(1000), 'sensor analytics');
    var fire = 0, warning = 0, normal = 0;
    final byDevice = {mainId: 0, secondaryId: 0};
    final history = <Map<String,dynamic>>[];
    for (final item in rows) {
      final id = '${item['controller_device_id']}';
      byDevice[id] = (byDevice[id] ?? 0) + 1;
      final smoke = '${item['smoke_status'] ?? ''}'.toUpperCase();
      final flame = item['flame_detected'] == true;
      final smokeAlarm = ['ALARM', 'FIRE', 'DANGER', 'CRITICAL'].contains(smoke);
      final hot = item['temperature'] is num && (item['temperature'] as num) >= 50.0;
      final faulty = item['flame_fault'] == true || item['smoke_fault'] == true;
      if (RoomSensorService.confirmedFire(Map<String, dynamic>.from(item))) {
        fire++;
      } else if ((!faulty && (flame || smokeAlarm)) || hot || smoke.contains('WARN')) {
        warning++;
      } else if (smoke == 'CLEAR' && item['flame_detected'] == false) {
        normal++;
      } else {
        warning++; // unknown/partial readings are not classified safe
      }
      history.add({...item, 'device_id': id, 'created_at': item['received_at']});
    }
    return AnalyticsSummary(rows.length, fire, warning, normal, byDevice, history);
  }
}
