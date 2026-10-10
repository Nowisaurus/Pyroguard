import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config/pyroguard_config.dart';

/// Central dual-database persistence layer.
///
/// PyroGuard does not intentionally split persistent application data between
/// Supabase and MySQL. A normal write stores the typed/current record in
/// Supabase and synchronously mirrors the same payload to MySQL through the
/// mysql-history Edge Function. Every application write also receives an
/// immutable dual_record_ledger entry in both databases.
///
/// Two independent databases cannot participate in one true atomic transaction.
/// Therefore the successful side is never rolled back just because the other
/// side is temporarily unavailable. Instead, Supabase marks mysql_synced=false
/// and retryPending() catches MySQL up without losing the original record.
///
/// Security exception: passwords, refresh tokens and other authentication
/// secrets remain exclusively in Supabase Auth. Identity/profile/session audit
/// records are dual-kept, but secrets are never copied into MySQL.
class DualSyncService {
  DualSyncService._();
  static final DualSyncService instance = DualSyncService._();
  static const _uuid = Uuid();

  SupabaseClient get _db => Supabase.instance.client;

  String? get _deviceId {
    final raw = _db.auth.currentUser?.userMetadata?['device_id'];
    final v = raw?.toString().trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<Map<String, dynamic>> _mysql(
    String action,
    Map<String, dynamic> record, {
    Map<String, dynamic>? dualRecord,
  }) async {
    final response = await _db.functions.invoke(
      PyroGuardConfig.mysqlHistoryFunction,
      body: {
        'action': action,
        if (_deviceId != null) 'device_id': _deviceId,
        'record': record,
        if (dualRecord != null) 'dual_record': dualRecord,
      },
    );
    final raw = response.data;
    if (raw is! Map) throw Exception('Unexpected MySQL gateway response.');
    final data = Map<String, dynamic>.from(raw);
    if (data['ok'] != true) throw Exception(data['error'] ?? 'MySQL write failed.');
    return data;
  }

  /// Synchronize the non-secret Auth identity to BOTH databases. Supabase Auth
  /// remains the only credential authority; MySQL receives identity/role/status
  /// and session timestamps, never passwords or tokens.
  Future<bool> syncAccountIdentity({String? sessionEvent}) async {
    final user = _db.auth.currentUser;
    if (user == null) return false;

    Map<String,dynamic> payload;
    try {
      final saved = await _db.rpc('pyroguard_save_session', params: {'session_event': sessionEvent});
      if (saved is! Map) throw StateError('Identity source was not returned');
      payload = Map<String,dynamic>.from(saved);
    } catch (e) {
      debugPrint('Supabase account identity write failed: $e');
      return false;
    }

    final mirrored = await writeMirror(
      recordType: 'account_identities',
      recordKey: user.id,
      payload: payload,
      operation: 'UPSERT',
      source: 'flutter_auth',
    );

    return mirrored;
  }

  /// Records successful login/logout in both databases and updates the account
  /// identity mirror. Authentication itself is intentionally performed only by
  /// Supabase Auth; MySQL never stores credential material.
  Future<void> recordSessionEvent({
    required String event,
    required bool admin,
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await syncAccountIdentity(sessionEvent: event);
    await writeMirror(
      recordType: admin ? 'admin_session' : 'user_session',
      recordKey: '${user.id}_${event}_$now',
      payload: {
        'event': event,
        'email': user.email,
        'role': admin ? (user.appMetadata['role'] ?? 'administrator') : 'homeowner',
        if (event.endsWith('_login')) 'logged_in_at': now,
        if (event.endsWith('_logout')) 'logged_out_at': now,
      },
      operation: 'ACTION',
      source: 'flutter_auth',
    );
    await writeEvent({
      'event_type': event,
      'message': admin
          ? (event.endsWith('_login')
              ? 'Administrator signed in through the unified PyroGuard login.'
              : 'Administrator signed out of PyroGuard.')
          : (event.endsWith('_login')
              ? 'Homeowner signed in to PyroGuard.'
              : 'Homeowner signed out of PyroGuard.'),
      'severity': 0,
      'payload': {'email': user.email},
      'created_at': now,
    });
  }

  Future<bool> writeEvent(Map<String, dynamic> record) =>
      _writeBoth('event_history', 'write_incident', record);

  Future<bool> writeCamera(Map<String, dynamic> record) =>
      _writeBoth('camera_history', 'write_camera', record);

  Future<bool> writeSensor(Map<String, dynamic> record) =>
      _writeBoth('sensor_history', 'write_sensor', record);

  Map<String, dynamic> _ledgerPayload({
    required String recordId,
    required String userId,
    required String recordType,
    required String recordKey,
    required String operation,
    required String source,
    required Map<String, dynamic> payload,
    String? deviceId,
    String? createdAt,
  }) {
    return <String, dynamic>{
      'record_id': recordId,
      'user_id': userId,
      'device_id': deviceId,
      'record_type': recordType,
      'record_key': recordKey,
      'operation': operation,
      'source': source,
      'payload': payload,
      'mysql_synced': false,
      'created_at': createdAt ?? DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<dynamic> _saveLedger(Map<String, dynamic> ledger) async {
    try {
      final saved = await _db
          .from('dual_record_ledger')
          .insert(ledger)
          .select('id')
          .single();
      return saved['id'];
    } catch (e) {
      // The actual domain write is still allowed to continue. The ledger is a
      // reliability/audit layer, not a reason to lose the primary record.
      debugPrint('Supabase dual ledger insert failed: $e');
      return null;
    }
  }

  Future<void> _markLedger(
    dynamic ledgerId, {
    required bool synced,
    String? error,
  }) async {
    if (ledgerId == null) return;
    try {
      await _db.from('dual_record_ledger').update({
        'mysql_synced': synced,
        'mysql_synced_at': synced ? DateTime.now().toUtc().toIso8601String() : null,
        'last_sync_error': error,
      }).eq('id', ledgerId);
    } catch (e) {
      debugPrint('Could not update dual ledger sync state: $e');
    }
  }

  /// Stores a configuration/current-state/action record in Supabase's generic
  /// mirror table and MySQL's generic mirror table in the same write-through
  /// operation. An immutable ledger row is appended in both databases too.
  Future<bool> writeMirror({
    required String recordType,
    required String recordKey,
    required Map<String, dynamic> payload,
    String operation = 'UPSERT',
    String source = 'flutter',
  }) async {
    final user = _db.auth.currentUser;
    if (user == null) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final recordId = _uuid.v4();
    final row = <String, dynamic>{
      'user_id': user.id,
      'device_id': _deviceId,
      'record_type': recordType,
      'record_key': recordKey,
      'payload': payload,
      'mysql_synced': false,
      'updated_at': now,
    };
    final ledger = _ledgerPayload(
      recordId: recordId,
      userId: user.id,
      deviceId: _deviceId,
      recordType: recordType,
      recordKey: recordKey,
      operation: operation,
      source: source,
      payload: payload,
      createdAt: now,
    );

    dynamic mirrorId;
    dynamic ledgerId;
    try {
      final saved = await _db
          .from('mirror_records')
          .upsert(row, onConflict: 'user_id,record_type,record_key')
          .select('id')
          .single();
      mirrorId = saved['id'];
      ledgerId = await _saveLedger(ledger);
    } catch (e) {
      debugPrint('Supabase mirror write failed: $e');
      return false;
    }

    try {
      await _mysql(
        'write_mirror',
        {
          ...row,
          'supabase_id': mirrorId,
          'created_at': now,
        },
        dualRecord: ledger,
      );
      await _db.from('mirror_records').update({
        'mysql_synced': true,
        'mysql_synced_at': now,
        'last_sync_error': null,
      }).eq('id', mirrorId);
      await _markLedger(ledgerId, synced: true);
      return true;
    } catch (e) {
      final message = '$e';
      await _db.from('mirror_records').update({
        'mysql_synced': false,
        'last_sync_error': message,
      }).eq('id', mirrorId);
      await _markLedger(ledgerId, synced: false, error: message);
      debugPrint('MySQL mirror pending: $e');
      return false;
    }
  }

  Future<bool> _writeBoth(
    String supabaseTable,
    String mysqlAction,
    Map<String, dynamic> input,
  ) async {
    final user = _db.auth.currentUser;
    if (user == null) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    final recordId = _uuid.v4();
    final record = <String, dynamic>{
      ...input,
      'user_id': input['user_id'] ?? user.id,
      if (input['device_id'] == null && _deviceId != null) 'device_id': _deviceId,
      'created_at': input['created_at'] ?? now,
    };

    try {
      late final Map<String, dynamic> row;
      if (supabaseTable == 'event_history') {
        row = {
          'user_id': user.id,
          'device_id': record['device_id'],
          'event_type': record['event_type'] ?? record['incident_type'] ?? 'event',
          'sensor_name': record['sensor_name'] ?? record['sensor'],
          'location': record['location'],
          'event_status': record['event_status'] ?? record['status'],
          'image_url': record['image_url'] ?? record['snapshot_url'] ?? record['photo_url'],
          'acting_user_name': record['acting_user_name'] ?? record['user_name'],
          'message': record['message'],
          'severity': record['severity'] ?? record['severity_level'] ?? 0,
          'payload_json': record,
          'mysql_synced': false,
          'created_at': record['created_at'],
        };
      } else if (supabaseTable == 'camera_history') {
        row = {
          'user_id': user.id,
          'device_id': record['device_id'],
          'event_type': record['event_type'] ?? 'camera_event',
          'image_url': record['image_url'] ?? record['snapshot_url'] ?? record['photo_url'],
          'metadata_json': record,
          'mysql_synced': false,
          'created_at': record['created_at'],
        };
      } else {
        row = {
          'user_id': user.id,
          'device_id': record['device_id'] ?? PyroGuardConfig.mainDeviceId,
          'temperature': record['temperature'],
          'humidity': record['humidity'],
          'smoke_raw': record['smoke_raw'] ?? record['mq2_raw'],
          'smoke_level': record['smoke_level'],
          'smoke_status': record['smoke_status'],
          'flame_detected': record['flame_detected'] ?? record['flame_status'],
          'door_status': record['door_status'],
          'window_status': record['window_status'],
          'motion_detected': record['motion_detected'],
          'system_armed': record['system_armed'],
          'system_mode': record['system_mode'] ?? record['arm_mode'],
          'incident_type': record['incident_type'],
          'severity_level': record['severity_level'] ?? record['severity'] ?? 0,
          'alert_status': record['alert_status'],
          'location': record['location'],
          'device_lat': record['device_lat'] ?? record['latitude'],
          'device_lng': record['device_lng'] ?? record['longitude'],
          'payload_json': record,
          'mysql_synced': false,
          'created_at': record['created_at'],
        };
      }

      final saved = await _db.from(supabaseTable).insert(row).select('id').single();
      final recordKey = '${saved['id']}';
      final ledger = _ledgerPayload(
        recordId: recordId,
        userId: user.id,
        deviceId: record['device_id']?.toString(),
        recordType: supabaseTable,
        recordKey: recordKey,
        operation: 'INSERT',
        source: 'flutter',
        payload: record,
        createdAt: record['created_at']?.toString() ?? now,
      );
      final ledgerId = await _saveLedger(ledger);

      try {
        await _mysql(mysqlAction, record, dualRecord: ledger);
        await _db.from(supabaseTable).update({
          'mysql_synced': true,
          'mysql_synced_at': now,
          'last_sync_error': null,
        }).eq('id', saved['id']);
        await _markLedger(ledgerId, synced: true);
        return true;
      } catch (e) {
        final message = '$e';
        await _db.from(supabaseTable).update({
          'mysql_synced': false,
          'last_sync_error': message,
        }).eq('id', saved['id']);
        await _markLedger(ledgerId, synced: false, error: message);
        debugPrint('MySQL dual-write pending for $supabaseTable: $e');
        return false;
      }
    } catch (e) {
      debugPrint('Dual-write failed for $supabaseTable: $e');
      return false;
    }
  }

  /// Verifies that the signed-in client can communicate with BOTH database
  /// paths. Supabase is checked with an authenticated table read; MySQL is
  /// checked through the authenticated mysql-history Edge Function.
  Future<Map<String, dynamic>> checkDatabaseCommunication() async {
    final user = _db.auth.currentUser;
    if (user == null) {
      return {
        'supabase': false,
        'mysql': false,
        'edge_function': false,
        'checked_at': DateTime.now().toUtc().toIso8601String(),
        'error': 'No authenticated user.',
      };
    }

    var supabaseOk = false;
    var mysqlOk = false;
    var edgeOk = false;
    int? mysqlTableCount;
    int mysqlExpectedTableCount = 25;
    bool mysqlSchemaParity = false;
    String? error;

    try {
      await _db
          .from('account_identities')
          .select('user_id')
          .eq('user_id', user.id)
          .limit(1);
      supabaseOk = true;
    } catch (e) {
      error = 'Supabase: $e';
    }

    try {
      final response = await _db.functions.invoke(
        PyroGuardConfig.mysqlHistoryFunction,
        body: {'action': 'health'},
      );
      final raw = response.data;
      if (raw is Map) {
        final data = Map<String, dynamic>.from(raw);
        edgeOk = data['edge_function'] == true || data['ok'] == true;
        final mysql = data['mysql'];
        final mysqlMap = mysql is Map ? Map<String, dynamic>.from(mysql) : <String, dynamic>{};
        mysqlOk = data['ok'] == true && mysqlMap['reachable'] == true;
        if (mysqlMap.isNotEmpty) {
          // Returned to the Admin Console so deployment can prove the complete
          // 25-table MySQL mirror schema is installed, not merely that port
          // 3306 is reachable.
          mysqlTableCount = (mysqlMap['mirrored_table_count'] as num?)?.toInt();
          mysqlExpectedTableCount = (mysqlMap['expected_table_count'] as num?)?.toInt() ?? 25;
          mysqlSchemaParity = mysqlMap['schema_parity'] == true;
        }
        if (!mysqlOk && data['error'] != null) {
          error = [if (error != null) error, 'MySQL: ${data['error']}${data['resolution'] != null ? '\n${data['resolution']}' : ''}']
              .whereType<String>()
              .join(' | ');
        }
      }
    } catch (e) {
      error = [if (error != null) error, 'MySQL gateway: $e']
          .whereType<String>()
          .join(' | ');
    }

    return {
      'supabase': supabaseOk,
      'mysql': mysqlOk,
      'edge_function': edgeOk,
      'mysql_table_count': mysqlTableCount,
      'mysql_expected_table_count': mysqlExpectedTableCount,
      'mysql_schema_parity': mysqlSchemaParity,
      'checked_at': DateTime.now().toUtc().toIso8601String(),
      if (error != null) 'error': error,
    };
  }

  /// Retries all known Supabase records whose MySQL mirror did not complete.
  /// This is a safety net; normal operation writes to both backends immediately.
  Future<void> retryPending() async {
    final user = _db.auth.currentUser;
    if (user == null) return;

    // Account identities created by the Auth trigger may be pending if MySQL
    // was unavailable or email confirmation delayed the first authenticated
    // app session. Catch them up before the rest of the outbox.
    try {
      final identity = await _db
          .from('account_identities')
          .select()
          .eq('user_id', user.id)
          .eq('mysql_synced', false)
          .maybeSingle();
      if (identity != null) {
        await syncAccountIdentity();
      }
    } catch (_) {}

    for (final table in ['event_history', 'camera_history', 'sensor_history']) {
      try {
        final rows = await _db
            .from(table)
            .select()
            .eq('user_id', user.id)
            .eq('mysql_synced', false)
            .limit(50);
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw);
          final payloadRaw = row['payload_json'] ?? row['metadata_json'];
          final decoded = payloadRaw is Map
              ? Map<String, dynamic>.from(payloadRaw)
              : <String, dynamic>{};
          final payload = decoded.isNotEmpty
              ? decoded
              : Map<String, dynamic>.from(row);
          final action = table == 'event_history'
              ? 'write_incident'
              : table == 'camera_history'
                  ? 'write_camera'
                  : 'write_sensor';
          try {
            await _mysql(action, payload);
            await _db.from(table).update({
              'mysql_synced': true,
              'mysql_synced_at': DateTime.now().toUtc().toIso8601String(),
              'last_sync_error': null,
            }).eq('id', row['id']);
          } catch (_) {}
        }
      } catch (_) {}
    }

    // Firmware-originated camera/audio metadata is also dual-kept. It may
    // reach Supabase while MySQL is offline, so retry those rows explicitly.
    for (final media in [
      ('camera_events', 'camera_events'),
      ('audio_sessions', 'audio_sessions'),
    ]) {
      try {
        final rows = await _db
            .from(media.$1)
            .select()
            .eq('user_id', user.id)
            .eq('mysql_synced', false)
            .limit(50);
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw);
          try {
            final ok = await _mysql('write_mirror', {
              'user_id': user.id,
              'device_id': row['device_id'],
              'record_type': media.$2,
              'record_key': (row['record_key'] ?? '${media.$2}_${row['id']}').toString(),
              'payload': row,
              'created_at': row['created_at'],
              'updated_at': row['created_at'],
            });
            if (ok['ok'] == true) {
              await _db.from(media.$1).update({
                'mysql_synced': true,
                'mysql_synced_at': DateTime.now().toUtc().toIso8601String(),
                'last_sync_error': null,
              }).eq('id', row['id']);
            }
          } catch (e) {
            try {
              await _db.from(media.$1).update({
                'last_sync_error': '$e',
              }).eq('id', row['id']);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    try {
      final mirrors = await _db
          .from('mirror_records')
          .select()
          .eq('user_id', user.id)
          .eq('mysql_synced', false)
          .limit(50);
      for (final raw in mirrors) {
        final row = Map<String, dynamic>.from(raw);
        try {
          await _mysql('write_mirror', row);
          await _db.from('mirror_records').update({
            'mysql_synced': true,
            'mysql_synced_at': DateTime.now().toUtc().toIso8601String(),
            'last_sync_error': null,
          }).eq('id', row['id']);
        } catch (_) {}
      }
    } catch (_) {}

    // Immutable ledger retry. write_ledger is idempotent in MySQL because
    // record_id is unique, so rerunning this cannot duplicate the same audit.
    try {
      final rows = await _db
          .from('dual_record_ledger')
          .select()
          .eq('user_id', user.id)
          .eq('mysql_synced', false)
          .limit(100);
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw);
        try {
          await _mysql('write_ledger', row);
          await _db.from('dual_record_ledger').update({
            'mysql_synced': true,
            'mysql_synced_at': DateTime.now().toUtc().toIso8601String(),
            'last_sync_error': null,
          }).eq('id', row['id']);
        } catch (e) {
          try {
            await _db.from('dual_record_ledger').update({
              'last_sync_error': '$e',
            }).eq('id', row['id']);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
