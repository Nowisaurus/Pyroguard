import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'historical_service.dart';
import 'dual_sync_service.dart';

enum SecurityMode { disarmed, armHome, armAway }

extension SecurityModeX on SecurityMode {
  String get dbValue => switch (this) {
        SecurityMode.disarmed => 'DISARMED',
        SecurityMode.armHome => 'ARM_HOME',
        SecurityMode.armAway => 'ARM_AWAY',
      };

  String get label => switch (this) {
        SecurityMode.disarmed => 'DISARMED',
        SecurityMode.armHome => 'ARM HOME',
        SecurityMode.armAway => 'ARM AWAY',
      };
}

class SecurityControlService extends ChangeNotifier {
  SecurityControlService._();
  static final SecurityControlService instance = SecurityControlService._();

  StreamSubscription? _sub;
  StreamSubscription? _commandSub;
  String? _commandStatus;
  String? _commandResult;
  String? get commandStatus => _commandStatus;
  String? get commandResult => _commandResult;
  SecurityMode _mode = SecurityMode.disarmed;

  /// Both Home 1 controllers. ARM/DISARM, silence and test chirp apply to the
  /// whole home, so every command is queued for each board (ESP32-002 used to
  /// be skipped, leaving the kitchen door / bedroom window unprotected and its
  /// buzzer impossible to silence from the app).
  static const controllers = ['ESP32-001', 'ESP32-002'];

  /// Mode the user just asked for, until a controller confirms it.
  SecurityMode? _requestedMode;
  SecurityMode? get requestedMode => _requestedMode;
  bool get awaitingConfirmation => _requestedMode != null && _requestedMode != _mode;

  // Latest confirmed state per controller; the most recently updated one wins.
  final Map<String, Map<String, dynamic>> _stateByDevice = {};
  bool _doorEnabled = true;
  bool _windowEnabled = true;
  bool _motionEnabled = true;
  bool _saving = false;
  String? _error;
  DateTime? _updatedAt;

  SecurityMode get mode => _mode;
  bool get doorEnabled => _doorEnabled;
  bool get windowEnabled => _windowEnabled;
  bool get motionEnabled => _motionEnabled;
  bool get saving => _saving;
  String? get error => _error;
  DateTime? get updatedAt => _updatedAt;

  String get deviceId {
    final raw =
        Supabase.instance.client.auth.currentUser?.userMetadata?['device_id'];
    final value = raw?.toString().trim();
    // Shared PyroGuard Home 1 controller. Database RLS still decides who
    // may insert control commands; this is not an authorization bypass.
    return (value != null && (value == 'ESP32-001' || value == 'ESP32-002'))
        ? value : 'ESP32-001';
  }

  void startListening() {
    _sub?.cancel();
    _commandSub?.cancel();
    _commandStatus = null;
    _commandResult = null;
    if (deviceId.isEmpty) return;
    _commandSub = Supabase.instance.client
        .from('device_commands')
        .stream(primaryKey: ['id'])
        .inFilter('target_device_id', controllers)
        .order('created_at', ascending: false)
        .limit(10)
        .listen((rows) {
          // Camera PTZ moves use the same table; skip them here so they never
          // replace the arm/disarm or buzzer feedback.
          final security = rows.where(
              (r) => r['command']?.toString() != 'PTZ');
          if (security.isEmpty) return;
          _commandStatus = security.first['status']?.toString();
          _commandResult = security.first['result_message']?.toString();
          notifyListeners();
        }, onError: (e) {
          _error = 'Command feedback unavailable: $e';
          notifyListeners();
        });
    _sub = Supabase.instance.client
        .from('system_state')
        .stream(primaryKey: ['id'])
        .inFilter('device_id', controllers)
        .listen((rows) {
          if (rows.isEmpty) return;
          _applyRows(rows);
        }, onError: (e) {
          _error = '$e';
          notifyListeners();
        });
    refresh();
  }

  Future<void> refresh() async {
    try {
      final rows = await Supabase.instance.client
          .from('system_state')
          .select()
          .inFilter('device_id', controllers);
      if (rows.isNotEmpty) _applyRows(rows);
      _error = null;
    } catch (e) {
      _error = '$e';
      debugPrint('SecurityControlService.refresh: $e');
      notifyListeners();
    }
  }

  void stopListening() {
    _sub?.cancel();
    _sub = null;
    _commandSub?.cancel();
    _commandSub = null;
    _commandStatus = null;
    _commandResult = null;
  }

  /// Shows the most recently confirmed state of either controller, so the
  /// dashboard follows whichever board applied the user's last command.
  void _applyRows(List<dynamic> rows) {
    for (final r in rows) {
      final row = Map<String, dynamic>.from(r as Map);
      final id = row['device_id']?.toString();
      if (id != null) _stateByDevice[id] = row;
    }
    Map<String, dynamic>? newest;
    DateTime? newestAt;
    for (final row in _stateByDevice.values) {
      final at = DateTime.tryParse((row['updated_at'] ?? '').toString());
      if (newest == null || (at != null && (newestAt == null || at.isAfter(newestAt)))) {
        newest = row;
        newestAt = at;
      }
    }
    if (newest != null) _apply(newest);
  }

  void _apply(Map<String, dynamic> row) {
    final raw = (row['arm_mode'] ?? row['system_mode'] ?? 'DISARMED')
        .toString()
        .toUpperCase();
    _mode = raw == 'ARM_AWAY'
        ? SecurityMode.armAway
        : raw == 'ARM_HOME'
            ? SecurityMode.armHome
            : SecurityMode.disarmed;
    _doorEnabled = row['door_enabled'] as bool? ?? true;
    _windowEnabled = row['window_enabled'] as bool? ?? true;
    _motionEnabled = row['motion_enabled'] as bool? ?? true;
    _updatedAt = DateTime.tryParse((row['updated_at'] ?? '').toString());
    if (_requestedMode == _mode) _requestedMode = null; // confirmed by hardware
    notifyListeners();
  }

  Future<bool> setMode(SecurityMode mode) async {
    return _save(
      mode: mode,
      command: 'SET_SECURITY_MODE',
      eventType: 'security_mode_changed',
    );
  }

  Future<bool> setDoorEnabled(bool enabled) => _save(
        doorEnabled: enabled,
        command: enabled ? 'ARM_DOOR' : 'DISARM_DOOR',
        eventType:
            enabled ? 'door_protection_armed' : 'door_protection_disarmed',
      );

  Future<bool> setWindowEnabled(bool enabled) => _save(
        windowEnabled: enabled,
        command: enabled ? 'ARM_WINDOW' : 'DISARM_WINDOW',
        eventType:
            enabled ? 'window_protection_armed' : 'window_protection_disarmed',
      );

  Future<bool> setMotionEnabled(bool enabled) => _save(
        motionEnabled: enabled,
        command: enabled ? 'ENABLE_MOTION' : 'DISABLE_MOTION',
        eventType: enabled
            ? 'motion_protection_enabled'
            : 'motion_protection_disabled',
      );

  /// Stops the 3.3V active piezo buzzer for the current alarm (intrusion or fire).
  /// The alarm itself stays recorded; a fire keeps alerting in the app.
  Future<bool> silenceSiren() => sendDeviceCommand('SILENCE_SIREN',
      'siren_silenced', 'Active piezo buzzer silenced from the app');

  /// One short, quiet chirp so the homeowner can check the bell.
  Future<bool> testBellChirp() => sendDeviceCommand(
      'TEST_CHIRP', 'siren_test_chirp', 'Buzzer test chirp requested');

  /// Queues a one-off command for the controller (Supabase device_commands,
  /// mirrored to MySQL). The controller acknowledges it as applied/failed.
  Future<bool> sendDeviceCommand(
      String command, String eventType, String message) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || deviceId.isEmpty) {
      _error = 'Sign in and register the actual device first.';
      notifyListeners();
      return false;
    }
    try {
      final writeAt = DateTime.now().toUtc().toIso8601String();
      final commands = [
        for (final target in controllers)
          <String, dynamic>{
            'user_id': user.id,
            'target_device_id': target,
            'command': command,
            'payload': <String, dynamic>{'requested_at': writeAt},
            'requested_by': user.id,
            'status': 'pending',
            'created_at': writeAt,
          },
      ];
      await Supabase.instance.client.from('device_commands').insert(commands);
      for (final c in commands) {
        await DualSyncService.instance.writeMirror(
          recordType: 'device_commands',
          recordKey: '${c['target_device_id']}_$writeAt',
          payload: c,
        );
      }
      await HistoricalService.instance.logEvent({
        'event_type': eventType,
        'message': message,
        'severity': 0,
        'device_id': deviceId,
        'created_at': writeAt,
      });
      _commandStatus = 'pending';
      _commandResult = 'Waiting for the device acknowledgement';
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = '$e';
      debugPrint('SecurityControlService command $command: $e');
      notifyListeners();
      return false;
    }
  }

  Future<bool> _save({
    SecurityMode? mode,
    bool? doorEnabled,
    bool? windowEnabled,
    bool? motionEnabled,
    required String command,
    required String eventType,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || deviceId.isEmpty) {
      _error = 'Sign in and register the actual device first.';
      notifyListeners();
      return false;
    }

    _saving = true;
    _error = null;
    notifyListeners();

    final nextMode = mode ?? _mode;
    final nextDoor = doorEnabled ?? _doorEnabled;
    final nextWindow = windowEnabled ?? _windowEnabled;
    final nextMotion = motionEnabled ?? _motionEnabled;

    try {
      final writeAt = DateTime.now().toUtc().toIso8601String();
      // Hardware state must be updated only after ESP32 acknowledgment.

      // Commands are queued even when hardware is offline. Once the ESP32 is
      // connected, it can poll pending commands and immediately apply the most
      // recent security configuration.
      Map<String, dynamic> commandFor(String target) => <String, dynamic>{
        'user_id': user.id,
        'target_device_id': target,
        'command': command,
        'payload': {
          'arm_mode': nextMode.dbValue,
          'door_enabled': nextDoor,
          'window_enabled': nextWindow,
          'motion_enabled': nextMotion,
        },
        'requested_by': user.id,
        'status': 'pending',
        'created_at': writeAt,
      };
      final commands = [for (final target in controllers) commandFor(target)];
      await Supabase.instance.client.from('device_commands').insert(commands);

      // Commands are application data too: keep the same command in MySQL,
      // not only the resulting system_state snapshot.
      for (final c in commands) {
        await DualSyncService.instance.writeMirror(
          recordType: 'device_commands',
          recordKey: '${c['target_device_id']}_$writeAt',
          payload: c,
        );
      }

      // The current control state is also mirrored to MySQL immediately.
      // Supabase remains the live command/state source, while the same control
      // configuration is retained in MySQL for audit/recovery.
      await DualSyncService.instance.writeMirror(
        recordType: 'system_state',
        recordKey: deviceId,
        payload: {
          'arm_mode': nextMode.dbValue,
          'door_enabled': nextDoor,
          'window_enabled': nextWindow,
          'motion_enabled': nextMotion,
          'command': command,
          'acting_user': user.id,
          'updated_at': writeAt,
        },
      );

      _commandStatus = 'pending';
      _commandResult = 'Waiting for the device acknowledgement';
      if (mode != null) _requestedMode = mode == _mode ? null : mode;
      // Do NOT optimistically change the displayed armed state.
      // This remains pending until firmware acknowledges and the server
      // persists system_state. A queued command is not proof of actuation.
      notifyListeners();

      await HistoricalService.instance.logEvent({
        'event_type': eventType,
        'message':
            'REQUESTED ${nextMode.label}; door=${nextDoor ? 'armed' : 'disarmed'}; window=${nextWindow ? 'armed' : 'disarmed'}; motion=${nextMotion ? 'enabled' : 'disabled'}',
        'severity': 0,
        'device_id': deviceId,
        'arm_mode': nextMode.dbValue,
        'door_enabled': nextDoor,
        'window_enabled': nextWindow,
        'motion_enabled': nextMotion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      return true;
    } catch (e) {
      _error = '$e';
      debugPrint('SecurityControlService save: $e');
      return false;
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
