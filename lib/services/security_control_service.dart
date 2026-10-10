import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
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
  SecurityMode _mode = SecurityMode.disarmed;
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
    final raw = Supabase.instance.client.auth.currentUser?.userMetadata?['device_id'];
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? PyroGuardConfig.mainDeviceId : value;
  }

  void startListening() {
    _sub?.cancel();
    _sub = Supabase.instance.client
        .from('system_state')
        .stream(primaryKey: ['id'])
        .eq('device_id', deviceId)
        .limit(1)
        .listen((rows) {
      if (rows.isEmpty) return;
      _apply(Map<String, dynamic>.from(rows.first));
    }, onError: (e) {
      _error = '$e';
      notifyListeners();
    });
    refresh();
  }

  Future<void> refresh() async {
    try {
      final row = await Supabase.instance.client
          .from('system_state')
          .select()
          .eq('device_id', deviceId)
          .maybeSingle();
      if (row != null) _apply(Map<String, dynamic>.from(row));
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
        eventType: enabled ? 'door_protection_armed' : 'door_protection_disarmed',
      );

  Future<bool> setWindowEnabled(bool enabled) => _save(
        windowEnabled: enabled,
        command: enabled ? 'ARM_WINDOW' : 'DISARM_WINDOW',
        eventType: enabled ? 'window_protection_armed' : 'window_protection_disarmed',
      );

  Future<bool> setMotionEnabled(bool enabled) => _save(
        motionEnabled: enabled,
        command: enabled ? 'ENABLE_MOTION' : 'DISABLE_MOTION',
        eventType: enabled ? 'motion_protection_enabled' : 'motion_protection_disabled',
      );

  Future<bool> _save({
    SecurityMode? mode,
    bool? doorEnabled,
    bool? windowEnabled,
    bool? motionEnabled,
    required String command,
    required String eventType,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return false;

    _saving = true;
    _error = null;
    notifyListeners();

    final nextMode = mode ?? _mode;
    final nextDoor = doorEnabled ?? _doorEnabled;
    final nextWindow = windowEnabled ?? _windowEnabled;
    final nextMotion = motionEnabled ?? _motionEnabled;

    try {
      final writeAt = DateTime.now().toUtc().toIso8601String();
      await Supabase.instance.client.from('system_state').upsert({
        'device_id': deviceId,
        'user_id': user.id,
        'arm_mode': nextMode.dbValue,
        'door_enabled': nextDoor,
        'window_enabled': nextWindow,
        'motion_enabled': nextMotion,
        'acting_user': user.id,
        'updated_at': writeAt,
      }, onConflict: 'device_id');

      // Commands are queued even when hardware is offline. Once the ESP32 is
      // connected, it can poll pending commands and immediately apply the most
      // recent security configuration.
      final commandPayload = <String, dynamic>{
        'user_id': user.id,
        'target_device_id': deviceId,
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
      await Supabase.instance.client.from('device_commands').insert(commandPayload);

      // Commands are application data too: keep the same command in MySQL,
      // not only the resulting system_state snapshot.
      await DualSyncService.instance.writeMirror(
        recordType: 'device_commands',
        recordKey: '${deviceId}_$writeAt',
        payload: commandPayload,
      );

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

      _mode = nextMode;
      _doorEnabled = nextDoor;
      _windowEnabled = nextWindow;
      _motionEnabled = nextMotion;
      _updatedAt = DateTime.now();

      await HistoricalService.instance.logEvent({
        'event_type': eventType,
        'message': '${nextMode.label}; door=${nextDoor ? 'armed' : 'disarmed'}; window=${nextWindow ? 'armed' : 'disarmed'}; motion=${nextMotion ? 'enabled' : 'disabled'}',
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
