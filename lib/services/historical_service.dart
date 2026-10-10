import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'dual_sync_service.dart';

/// Historical records are mirrored to BOTH Supabase and MySQL.
///
/// Reads query BOTH Supabase and MySQL and merge/deduplicate the results.
/// Neither backend is treated as a history-only or secondary-only source; the
/// application can surface records retained by either side while dual-write
/// retry catches up a temporarily unavailable mirror.
class HistoricalService {
  HistoricalService._();
  static final HistoricalService instance = HistoricalService._();

  SupabaseClient get _db => Supabase.instance.client;
  bool get isConfigured => _db.auth.currentSession != null;

  String? get _deviceId {
    final raw = _db.auth.currentUser?.userMetadata?['device_id'];
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  Future<Map<String, dynamic>> _invoke(
    String action, {
    Map<String, dynamic>? payload,
  }) async {
    final session = _db.auth.currentSession;
    if (session == null) throw StateError('Sign in before loading history.');
    final response = await _db.functions.invoke(
      PyroGuardConfig.mysqlHistoryFunction,
      body: {
        'action': action,
        if (_deviceId != null) 'device_id': _deviceId,
        if (payload != null) ...payload,
      },
    );
    final data = response.data;
    if (data is Map) {
      final mapped = Map<String, dynamic>.from(data);
      if (mapped['ok'] == false) {
        throw Exception(mapped['error'] ?? 'MySQL history request failed.');
      }
      return mapped;
    }
    throw Exception('Unexpected response from MySQL history function.');
  }

  Map<String, dynamic> _decodeNestedJson(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _normalizeRows(dynamic rawRows) {
    if (rawRows is! List) return const [];
    return rawRows.whereType<Map>().map((raw) {
      final row = Map<String, dynamic>.from(raw);
      final payload = _decodeNestedJson(row['payload_json']);
      final metadata = _decodeNestedJson(row['metadata_json']);
      final merged = <String, dynamic>{...payload, ...metadata, ...row};
      merged['alert_type'] ??= merged['event_type'];
      merged['severity_level'] ??= merged['severity'];
      merged['snapshot_url'] ??= merged['image_url'] ?? merged['photo_url'];
      merged['created_at'] ??= merged['recorded_at'];
      return merged;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _supabaseRows(
    String table, {
    required int limit,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return const [];
    var query = _db.from(table).select().eq('user_id', user.id);
    if (_deviceId != null) query = query.eq('device_id', _deviceId!);
    final rows = await query.order('created_at', ascending: false).limit(limit);
    return _normalizeRows(rows);
  }

  String _rowKey(Map<String, dynamic> row) {
    final created = (row['created_at'] ?? row['recorded_at'] ?? '').toString();
    final device = (row['device_id'] ?? '').toString();
    final event = (row['event_type'] ?? row['incident_type'] ?? '').toString();
    final message = (row['message'] ?? '').toString();
    final image = (row['image_url'] ?? row['snapshot_url'] ?? '').toString();
    final smoke = (row['smoke_raw'] ?? '').toString();
    final temp = (row['temperature'] ?? '').toString();
    return '$created|$device|$event|$message|$image|$smoke|$temp';
  }

  List<Map<String, dynamic>> _mergeBoth(
    List<Map<String, dynamic>> supabaseRows,
    List<Map<String, dynamic>> mysqlRows,
    int limit,
  ) {
    final merged = <String, Map<String, dynamic>>{};
    // MySQL first, then Supabase so Supabase sync metadata can enrich the
    // equivalent row without hiding a record that exists only in MySQL.
    for (final row in [...mysqlRows, ...supabaseRows]) {
      final key = _rowKey(row);
      final previous = merged[key];
      merged[key] = previous == null ? row : <String, dynamic>{...previous, ...row};
    }
    final values = merged.values.toList()
      ..sort((a, b) {
        final ad = DateTime.tryParse((a['created_at'] ?? a['recorded_at'] ?? '').toString());
        final bd = DateTime.tryParse((b['created_at'] ?? b['recorded_at'] ?? '').toString());
        return (bd ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(ad ?? DateTime.fromMillisecondsSinceEpoch(0));
      });
    return values.take(limit).toList();
  }

  Future<List<Map<String, dynamic>>> _mysqlRows(
    String action, {
    required int limit,
  }) async {
    try {
      final response = await _invoke(action, payload: {'limit': limit});
      return _normalizeRows(response['data'] ?? response['rows']);
    } catch (e) {
      debugPrint('MySQL $action read unavailable: $e');
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchSensorHistory({int limit = 300}) async {
    List<Map<String, dynamic>> supabaseRows = const [];
    try {
      supabaseRows = await _supabaseRows('sensor_history', limit: limit);
    } catch (e) {
      debugPrint('Supabase sensor history read unavailable: $e');
    }
    final mysqlRows = await _mysqlRows('list_sensor', limit: limit);
    return _mergeBoth(supabaseRows, mysqlRows, limit);
  }

  Future<List<Map<String, dynamic>>> fetchIncidentHistory({int limit = 100}) async {
    List<Map<String, dynamic>> supabaseRows = const [];
    try {
      supabaseRows = await _supabaseRows('event_history', limit: limit);
    } catch (e) {
      debugPrint('Supabase event history read unavailable: $e');
    }
    final mysqlRows = await _mysqlRows('list_incident', limit: limit);
    return _mergeBoth(supabaseRows, mysqlRows, limit);
  }

  Future<List<Map<String, dynamic>>> fetchCameraEvents({int limit = 100}) async {
    List<Map<String, dynamic>> supabaseRows = const [];
    try {
      supabaseRows = await _supabaseRows('camera_history', limit: limit);
    } catch (e) {
      debugPrint('Supabase camera history read unavailable: $e');
    }
    final mysqlRows = await _mysqlRows('list_camera', limit: limit);
    return _mergeBoth(supabaseRows, mysqlRows, limit);
  }

  Future<bool> logEvent(Map<String, dynamic> data) =>
      DualSyncService.instance.writeEvent(data);

  Future<bool> logIncident(Map<String, dynamic> data) =>
      DualSyncService.instance.writeEvent(data);

  Future<bool> logCameraEvent(Map<String, dynamic> data) =>
      DualSyncService.instance.writeCamera(data);

  Future<bool> logSensor(Map<String, dynamic> data) =>
      DualSyncService.instance.writeSensor(data);

  Future<void> retryPendingSync() => DualSyncService.instance.retryPending();
}
