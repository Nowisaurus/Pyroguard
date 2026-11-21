import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/coverage_config.dart';

/// A confirmed multi-sensor emergency for one physical room.
/// This is a UI threshold, not a guarantee that a fire exists or does not exist.
class VerifiedRoomFire {
  final String controller;
  final String room;
  final Map<String, dynamic> reading;
  const VerifiedRoomFire(this.controller, this.room, this.reading);
}

/// Read-only room telemetry. Devices must send a separate reading per room.
/// Missing values are never converted to zero, false, or a healthy state.
class RoomSensorService extends ChangeNotifier {
  RoomSensorService._();
  static final instance = RoomSensorService._();
  static const table = 'pyroguard_room_sensor_readings';
  static const controllerIds = ['ESP32-001', 'ESP32-002'];
  /// The four real database room keys, paired with the correct controller.
  static const rooms = {
    'entrance': 'Entrance', 'sala': 'Sala',
    'kitchen': 'Kitchen', 'bedroom': 'Bedroom',
  };
  static List<String> roomsFor(String controller) =>
      CoverageConfig.roomsForController(controller);

  /// Batch 1 (ESP32-001): Entrance & Sala. Batch 2 (ESP32-002): Kitchen & Bedroom.
  static String label(String controller, String room) =>
      CoverageConfig.roomLabel(controller, room);
  final Map<String, Map<String, dynamic>> _latest = {};
  final Map<String, List<Map<String, dynamic>>> _recent = {};
  Timer? _timer;
  RealtimeChannel? _channel;
  DateTime? lastSuccessfulRefresh;
  bool _loading = false;
  bool loaded = false;
  String? error;

  String _key(String device, String room) => '$device/$room';
  Map<String, dynamic>? reading(String device, String room) =>
      _latest[_key(device, room)];

  bool fresh(String device, String room) {
    final record = reading(device, room);
    final at = DateTime.tryParse('${record?['received_at'] ?? record?['sampled_at'] ?? ''}');
    if (at == null) return false;
    final age = DateTime.now().toUtc().difference(at.toUtc());
    return !age.isNegative && age <= const Duration(minutes: 2);
  }

  String value(String device, String room, String field, {String unit = ''}) {
    if (!fresh(device, room)) return 'NO FRESH DATA';
    final record = reading(device, room);
    final v = record?[field];
        // MQ-2 gas level: firmware v11+ sends the analog reading in mV;
    // older firmware sends only the status.
    if (field == 'smoke_raw') {
      final status = switch ('${record?['smoke_status'] ?? ''}'.toUpperCase()) {
        'ALARM' => 'GAS DETECTED',
        'CLEAR' => 'NO GAS',
        'WARMUP' => 'WARMING UP',
        'FAULT' => 'SENSOR FAULT',
        _ => 'NOT REPORTED',
      };
           // ~140 mV at the ESP32 = 0 V: the MQ-2 signal is not reaching the board.
      if (v is num && v < 250 && status == 'SENSOR FAULT') {
        return 'NO SIGNAL (0 V) • check MQ-2 wire / 5V';
      }
      return v is num ? '${v.round()} mV • $status' : status;
    }
    if (v == null) return 'NOT REPORTED';
    if (field == 'buzzer_active' && v is bool) return v ? 'ON' : 'OFF';
    if (v is bool) return v ? 'ACTIVE / DETECTED' : 'CLEAR / OFF';
    return '$v$unit';
  }

  /// BFP assistance (and the fire siren) requires two successive fresh
  /// readings from the SAME room in which the controller CONFIRMED a fire:
  /// smoke AND flame both on, sustained for 5 s, neither sensor faulty
  /// (`fire_confirmed`). Temperature alone, a lone flame, a
  /// flickering/stuck sensor (`flame_fault` / `smoke_fault`), smoke in one
  /// room with flame in another, or a stale row never qualify.
  /// Shared rule used by every screen (overview, analytics, siren, BFP card).
  static bool confirmedFire(Map<String, dynamic> row) => _qualifiesForBfp(row);

  static bool _qualifiesForBfp(Map<String, dynamic> row) {
    if (row['flame_fault'] == true || row['smoke_fault'] == true) return false;
    // Only the guarded firmware sets fire_confirmed. Readings from the old
    // firmware (null) were often electrical noise, so they never count as fire.
    return row['fire_confirmed'] == true;
  }

  VerifiedRoomFire? get verifiedFireEmergency {
    for (final device in controllerIds) {
      for (final room in roomsFor(device)) {
        final rows = _recent[_key(device, room)];
        if (rows == null || rows.length < 2) continue;
        final first = rows[0], second = rows[1];
        final latestAt = DateTime.tryParse('${first['received_at'] ?? ''}')?.toUtc();
        final priorAt = DateTime.tryParse('${second['received_at'] ?? ''}')?.toUtc();
        if (latestAt == null || priorAt == null) continue;
        final age = DateTime.now().toUtc().difference(latestAt);
        final sampleGap = latestAt.difference(priorAt);
        if (age.isNegative || age > const Duration(seconds: 30) ||
            sampleGap < const Duration(seconds: 2) || sampleGap > const Duration(seconds: 30)) {
          continue;
        }
        if (_qualifiesForBfp(first) && _qualifiesForBfp(second)) {
          return VerifiedRoomFire(device, room, first);
        }
      }
    }
    return null;
  }

  bool alert(String device, String room) {
    if (!fresh(device, room)) return false;
    final record = reading(device, room);
    final smoke = '${record?['smoke_status'] ?? ''}'.toUpperCase();
    // The buzzer is an OUTPUT (door chimes also sound it), so it is not a
    // hazard signal. A faulty sensor is shown as "check sensor", not alert.
    if (record?['flame_fault'] == true && record?['smoke_fault'] == true) return false;
    return (record?['flame_detected'] == true && record?['flame_fault'] != true) ||
        (record?['smoke_fault'] != true && ['ALARM', 'FIRE', 'DANGER', 'CRITICAL'].contains(smoke));
  }

  /// True when the controller marked a room sensor as stuck or flickering.
  bool sensorFault(String device, String room) {
    if (!fresh(device, room)) return false;
    final record = reading(device, room);
    return record?['flame_fault'] == true || record?['smoke_fault'] == true;
  }

  void start() {
    if (_timer != null) return;
    refresh();
    // Realtime reduces update latency; polling still handles reconnects and
    // deployments where the table is not in the Realtime publication.
    _channel = Supabase.instance.client
        .channel('pyroguard-room-sensor-latest')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: table,
          callback: (_) => refresh(),
        )
        .subscribe();
    // 3 s backup refresh (realtime normally updates immediately).
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_channel != null) {
      Supabase.instance.client.removeChannel(_channel!);
      _channel = null;
    }
  }

  /// Pages history without a fixed overall record cap. The UI fetches a
  /// bounded page, then requests further pages as the user scrolls.
  Future<List<Map<String, dynamic>>> historyPage({
    required String controller,
    required String room,
    DateTime? before,
    int pageSize = 100,
  }) async {
    if (!controllerIds.contains(controller) || !roomsFor(controller).contains(room)) {
      throw ArgumentError('Unknown controller or room');
    }
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) {
      throw StateError('Sign in to read room sensor history');
    }
    final count = pageSize.clamp(1, 250).toInt();
    var query = client.from(table).select()
        .eq('controller_device_id', controller)
        .eq('room_key', room);
    if (before != null) {
      query = query.lt('sampled_at', before.toUtc().toIso8601String());
    }
    final rows = await query.order('sampled_at', ascending: false)
        .limit(count);
    return [for (final row in rows) Map<String, dynamic>.from(row)];
  }

  Duration? readingAge(String device, String room) {
    final record = reading(device, room);
    final at = DateTime.tryParse('${record?['received_at'] ?? record?['sampled_at'] ?? ''}');
    if (at == null) return null;
    return DateTime.now().toUtc().difference(at.toUtc());
  }

  List<String> missingFields(String device, String room) {
    final row = reading(device, room);
    // Smoke may be digital-only; a missing analog ADC is not a fault.
    const fields = ['temperature', 'humidity', 'smoke_status',
      'flame_detected'];
    return [for (final field in fields) if (row?[field] == null) field];
  }

  Future<void> refresh() async {
    if (_loading) return;
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) {
      _latest.clear();
      _recent.clear();
      loaded = false;
      error = 'Sign in to view room telemetry';
      notifyListeners();
      return;
    }
    _loading = true;
    try {
      // Fetch each room separately: a noisy controller cannot crowd out
      // a quieter room in a shared LIMIT query.
      final groups = [
        for (final device in controllerIds)
          for (final room in roomsFor(device)) (device: device, room: room),
      ];
      final results = await Future.wait(groups.map((group) => client
          .from(table)
          .select()
          .eq('controller_device_id', group.device)
          .eq('room_key', group.room)
          .order('received_at', ascending: false)
          .limit(2)));
      _latest.clear();
      _recent.clear();
      for (var i = 0; i < groups.length; i++) {
        if (results[i].isNotEmpty) {
          final roomKey = _key(groups[i].device, groups[i].room);
          final values = [for (final row in results[i]) Map<String, dynamic>.from(row)];
          _latest[roomKey] = values.first;
          _recent[roomKey] = values;
        }
      }
      error = null;
      loaded = true;
      lastSuccessfulRefresh = DateTime.now().toUtc();
    } catch (e) {
      error = e.toString();
      loaded = false;
      _latest.clear();
      _recent.clear();
      debugPrint('Room telemetry read failed: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
