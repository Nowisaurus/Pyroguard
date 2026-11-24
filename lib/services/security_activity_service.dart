import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/coverage_config.dart';
import 'notification_service.dart';

/// One door/window/arm change stored by a controller in `event_history`.
class SecurityEvent {
  SecurityEvent(this.row)
      : id = (row['id'] as num?)?.toInt() ?? 0,
        deviceId = '${row['device_id'] ?? ''}',
        type = '${row['event_type'] ?? ''}',
        message = '${row['message'] ?? ''}',
        severity = (row['severity'] as num?)?.toInt() ?? 0,
        mysqlSynced = row['mysql_synced'] == true,
        createdAt = DateTime.tryParse('${row['created_at']}')?.toLocal(),
        payload = _decode(row['payload_json']);

  final Map<String, dynamic> row;
  final int id;
  final String deviceId;
  final String type;
  final String message;
  final int severity;
  final bool mysqlSynced;
  final DateTime? createdAt;
  final Map<String, dynamic> payload;

  static Map<String, dynamic> _decode(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final d = jsonDecode(raw);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return const {};
  }

  /// "door", "window" or "" for ARMED/DISARMED.
  String get contact => type.startsWith('DOOR')
      ? 'door'
      : type.startsWith('WINDOW')
          ? 'window'
          : '';
  bool get isOpen => type.endsWith('_OPEN');
  bool get isArmChange => type == 'ARMED' || type == 'DISARMED';

  /// Arm state at the moment of the event (stored by the firmware).
  bool get armedAtTime => isArmChange ? type == 'ARMED' : payload['armed'] == true;
  String get armModeAtTime => '${payload['arm_mode'] ?? (armedAtTime ? 'ARMED' : 'DISARMED')}';
  bool get intrusion => severity >= 2 && isOpen;

  String get label => contact.isEmpty
      ? 'System'
      : CoverageConfig.contactLabel(deviceId, contact);
  String get batch => CoverageConfig.batchName(deviceId);
}

/// Live OPEN/CLOSED for one reed switch.
class ContactState {
  const ContactState(this.state, this.at, this.armedAtChange, this.source);
  final String state; // OPEN, CLOSED, UNKNOWN
  final DateTime? at;
  final bool? armedAtChange;
  final String source; // "live" or "event"
}

/// Watches both controllers (ESP32-001 Batch 1, ESP32-002 Batch 2) so the owner
/// always sees every door/window OPEN/CLOSE together with ARMED/DISARMED,
/// and gets a notification for each new one. Reads existing tables only.
class SecurityActivityService extends ChangeNotifier {
  SecurityActivityService._();
  static final SecurityActivityService instance = SecurityActivityService._();

  static const types = [
    'DOOR_OPEN', 'DOOR_CLOSED', 'WINDOW_OPEN', 'WINDOW_CLOSED', 'ARMED', 'DISARMED',
  ];

  List<SecurityEvent> events = const [];
  Map<String, Map<String, dynamic>> _live = const {};
  Map<String, Map<String, dynamic>> _contactLive = const {};
  String? error;
  bool loading = true;
  Timer? _timer;
  int _users = 0;
  int _lastNotifiedId = 0;
  bool _firstLoad = true;
  bool notifications = false;

  /// Door/window opened while ARMED that the owner has not handled yet.
  /// Shown as the full-screen intrusion alarm; cleared by DISARM or
  /// [acknowledgeIntrusion].
  SecurityEvent? activeIntrusion;
  int _acknowledgedIntrusionId = 0;

  /// The owner has seen the intrusion alarm: hide it and stop the app siren.
  void acknowledgeIntrusion() {
    final e = activeIntrusion;
    if (e != null) _acknowledgedIntrusionId = e.id;
    activeIntrusion = null;
    NotificationService.stopIntrusionSiren();
    notifyListeners();
  }

  void _raiseIntrusion(SecurityEvent e) {
    if (e.id <= _acknowledgedIntrusionId) return;
    activeIntrusion = e;
    final where = '${e.label} (${e.batch}, ${CoverageConfig.controllerCoverage(e.deviceId)})';
    NotificationService.startIntrusionSiren(
      'INTRUSION: ${e.label} opened',
      '$where was opened while the system is ARMED. Disarm or check the camera now.',
    );
  }

  void _clearIntrusion() {
    if (activeIntrusion == null) return;
    activeIntrusion = null;
    NotificationService.stopIntrusionSiren();
  }

  /// Starts polling (reference counted). [notify] = raise notifications.
  void start({bool notify = false}) {
    _users++;
    if (notify) notifications = true;
    // 2 s so door/window and arm changes show up quickly (was 5 s).
    _timer ??= Timer.periodic(const Duration(seconds: 2), (_) => refresh());
    refresh();
  }

  void stop() {
    if (_users > 0) _users--;
    if (_users == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  bool _busy = false;
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    final db = Supabase.instance.client;
    try {
      final rows = await db
          .from('event_history')
          .select('id,device_id,event_type,message,severity,payload_json,mysql_synced,created_at')
          .inFilter('event_type', types)
          .inFilter('device_id', CoverageConfig.controllers)
          .order('created_at', ascending: false)
          .limit(40);
      events = [for (final r in List<Map<String, dynamic>>.from(rows as List)) SecurityEvent(r)];
      try {
        final live = await db
            .from('device_current_state')
            .select()
            .inFilter('device_id', CoverageConfig.controllers);
        _live = {
          for (final r in List<Map<String, dynamic>>.from(live as List))
            '${r['device_id']}': r,
        };
      } catch (_) {
        // Live state is optional; the latest stored event is used instead.
      }
      // Optional current reed-switch table written by authenticated sensor-ingest.
      // Older deployments may not have this table; keep existing event fallback.
      try {
        final contacts = await db.from('pyroguard_contact_current_state')
            .select('device_id,contact_type,is_open,received_at')
            .inFilter('device_id', CoverageConfig.controllers);
        _contactLive = {
          for (final row in List<Map<String, dynamic>>.from(contacts as List))
            '${row['device_id']}/${row['contact_type']}': row,
        };
      } catch (e) {
        _contactLive = const {};
        debugPrint('Optional live reed-switch state unavailable: $e');
      }
      error = null;
      _notifyNew();
    } catch (e) {
      error = 'Could not read door/window activity: $e';
    } finally {
      loading = false;
      _busy = false;
      notifyListeners();
    }
  }

  void _notifyNew() {
    final newest = events.isEmpty ? 0 : events.map((e) => e.id).reduce((a, b) => a > b ? a : b);
    if (_firstLoad) {
      // Existing history is not "new": only notify what happens from now on.
      _firstLoad = false;
      _lastNotifiedId = newest;
      // ...except an intrusion from the last 3 minutes that nobody disarmed
      // yet (e.g. the app was opened / reloaded while the alarm is on).
      if (notifications) {
        for (final e in events) {
          if (e.type == 'DISARMED') break;
          if (e.intrusion) {
            final age = e.createdAt == null ? null : DateTime.now().difference(e.createdAt!);
            if (age != null && age < const Duration(minutes: 3)) _raiseIntrusion(e);
            break;
          }
        }
      }
      return;
    }
    if (!notifications) {
      _lastNotifiedId = newest;
      return;
    }
    final fresh = events.where((e) => e.id > _lastNotifiedId).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final e in fresh) {
      final title = e.isArmChange
          ? (e.type == 'ARMED' ? 'System ARMED' : 'System DISARMED')
          : '${e.label} ${e.isOpen ? 'OPENED' : 'CLOSED'}';
      final body = e.isArmChange
          ? '${e.batch} (${e.deviceId}) confirmed: ${e.message}'
          : '${e.batch} • ${e.armedAtTime ? 'system ARMED' : 'system DISARMED'}'
              '${e.intrusion ? ' • INTRUSION ALARM' : ''}';
      if (e.intrusion) {
        _raiseIntrusion(e); // full-screen alarm + siren (replaces the small notice)
      } else {
        NotificationService.notifyContactEvent(title, body);
      }
      if (e.type == 'DISARMED') _clearIntrusion();
    }
    _lastNotifiedId = newest;
  }

  /// OPEN/CLOSED for one reed switch: fresh live telemetry first, otherwise
  /// the latest stored event for that switch.
  ContactState contactState(String deviceId, String contact) {
    SecurityEvent? last;
    for (final e in events) {
      if (e.deviceId == deviceId && e.contact == contact) {
        last = e;
        break;
      }
    }
    final contactRow = _contactLive['$deviceId/$contact'];
    if (contactRow != null && contactRow['is_open'] is bool) {
      final at = DateTime.tryParse('${contactRow['received_at']}')?.toUtc();
      if (at != null) {
        final age = DateTime.now().toUtc().difference(at);
        if (!age.isNegative && age <= const Duration(minutes: 2)) {
          return ContactState(contactRow['is_open'] == true ? 'OPEN' : 'CLOSED',
              at.toLocal(), last?.armedAtTime, 'reed-switch');
        }
      }
    }
    final row = _live[deviceId];
    if (row != null) {
      final updated = DateTime.tryParse('${row['updated_at']}');
      final fresh = updated != null &&
          DateTime.now().toUtc().difference(updated.toUtc()) <= const Duration(minutes: 2);
      String? state;
      final status = row['${contact}_status'];
      final open = row['${contact}_open'];
      if (status != null && '$status'.trim().isNotEmpty) {
        state = '$status'.toUpperCase();
      } else if (open is bool) {
        state = open ? 'OPEN' : 'CLOSED';
      }
      if (fresh && (state == 'OPEN' || state == 'CLOSED')) {
        return ContactState(state!, last?.createdAt, last?.armedAtTime, 'live');
      }
    }
    if (last != null) {
      return ContactState(last.isOpen ? 'OPEN' : 'CLOSED', last.createdAt, last.armedAtTime, 'event');
    }
    return const ContactState('UNKNOWN', null, null, 'none');
  }

  /// Latest ARMED/DISARMED confirmation from a controller.
  SecurityEvent? lastArmEvent(String deviceId) {
    for (final e in events) {
      if (e.deviceId == deviceId && e.isArmChange) return e;
    }
    return null;
  }

  @visibleForTesting
  void debugSet(List<SecurityEvent> list) {
    events = list;
    notifyListeners();
  }
}
