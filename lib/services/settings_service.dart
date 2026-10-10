import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'historical_service.dart';
import 'dual_sync_service.dart';

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  SupabaseClient get _db => Supabase.instance.client;
  String get userId => _db.auth.currentUser!.id;

  Future<Map<String, dynamic>?> _singleForUser(String table) async {
    final row = await _db.from(table).select().eq('user_id', userId).maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  Future<Map<String, dynamic>> loadAll() async {
    final user = _db.auth.currentUser;
    if (user == null) throw StateError('Sign in first.');

    final results = await Future.wait<dynamic>([
      _db.from('profiles').select().eq('id', user.id).maybeSingle(),
      _singleForUser('homes'),
      _db.from('stakeholders').select().eq('user_id', user.id).eq('is_primary', true).maybeSingle(),
      _db.from('emergency_contacts').select().eq('user_id', user.id).eq('is_primary', true).maybeSingle(),
      _singleForUser('safety_setups'),
      _singleForUser('user_preferences'),
      _db.from('devices').select().eq('user_id', user.id).maybeSingle(),
    ]);

    Map<String, dynamic> map(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    return {
      'profile': map(results[0]),
      'home': map(results[1]),
      'stakeholder': map(results[2]),
      'bfp': map(results[3]),
      'safety': map(results[4]),
      'preferences': map(results[5]),
      'device': map(results[6]),
    };
  }

  Future<void> saveProfile({required String fullName, required String phone}) async {
    final user = _db.auth.currentUser!;
    await _db.from('profiles').upsert({
      'id': user.id,
      'user_id': user.id,
      'full_name': fullName.trim(),
      'email': user.email,
      'phone': phone.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
    await _db.auth.updateUser(UserAttributes(data: {
      ...?user.userMetadata,
      'full_name': fullName.trim(),
      'phone_number': phone.trim(),
    }));
    await DualSyncService.instance.syncAccountIdentity();
    await _mirror('profiles', user.id, {
      'full_name': fullName.trim(),
      'email': user.email,
      'phone': phone.trim(),
    });
    await _audit('settings_profile_updated', {'full_name': fullName.trim()});
  }

  Future<void> saveHome({
    required String homeName,
    required String address,
    String? barangay,
    String? city,
    double? latitude,
    double? longitude,
  }) async {
    await _db.from('homes').upsert({
      'user_id': userId,
      'home_name': homeName.trim(),
      'address': address.trim(),
      'barangay': barangay?.trim(),
      'city': city?.trim(),
      'latitude': latitude,
      'longitude': longitude,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
    await _mirror('homes', userId, {
      'home_name': homeName.trim(),
      'address': address.trim(),
      'barangay': barangay?.trim(),
      'city': city?.trim(),
      'latitude': latitude,
      'longitude': longitude,
    });
    await _audit('settings_home_updated', {
      'home_name': homeName.trim(),
      'address': address.trim(),
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  Future<void> saveStakeholder({
    required String fullName,
    required String relationship,
    required String phone,
  }) async {
    final existing = await _db.from('stakeholders').select('id').eq('user_id', userId).eq('is_primary', true).maybeSingle();
    final data = {
      'user_id': userId,
      'full_name': fullName.trim(),
      'relationship': relationship.trim(),
      'phone': phone.trim(),
      'is_primary': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (existing == null) {
      await _db.from('stakeholders').insert(data);
    } else {
      await _db.from('stakeholders').update(data).eq('id', existing['id']);
    }
    await _mirror('stakeholders', userId, {
      'full_name': fullName.trim(),
      'relationship': relationship.trim(),
      'phone': phone.trim(),
      'is_primary': true,
    });
    await _audit('settings_stakeholder_updated', {'full_name': fullName.trim(), 'relationship': relationship.trim()});
  }

  Future<void> saveBfp({
    required String stationName,
    required String phone,
    required String address,
    String? personnelName,
    String? rankPosition,
    bool confirmed = true,
  }) async {
    final existing = await _db.from('emergency_contacts').select('id').eq('user_id', userId).eq('is_primary', true).maybeSingle();
    final data = {
      'user_id': userId,
      'station_name': stationName.trim(),
      'name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'rank_position': rankPosition?.trim(),
      'phone': phone.trim(),
      'address': address.trim(),
      'is_primary': true,
      'is_confirmed': confirmed,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (existing == null) {
      await _db.from('emergency_contacts').insert(data);
    } else {
      await _db.from('emergency_contacts').update(data).eq('id', existing['id']);
    }
    await _mirror('emergency_contacts', userId, {
      'station_name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'rank_position': rankPosition?.trim(),
      'phone': phone.trim(),
      'address': address.trim(),
      'confirmed': confirmed,
    });
    await _audit('settings_bfp_updated', {
      'station_name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'phone': phone.trim(),
      'confirmed': confirmed,
    });
  }

  Future<void> saveSafety({
    required bool acknowledged,
    required int entryDelaySeconds,
    required int sirenDurationSeconds,
    required bool aiAssistEnabled,
    String? notes,
  }) async {
    await _db.from('safety_setups').upsert({
      'user_id': userId,
      'safety_acknowledged': acknowledged,
      'entry_delay_seconds': entryDelaySeconds,
      'siren_duration_seconds': sirenDurationSeconds,
      'ai_assist_enabled': aiAssistEnabled,
      'notes': notes?.trim(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
    await _mirror('safety_setups', userId, {
      'safety_acknowledged': acknowledged,
      'entry_delay_seconds': entryDelaySeconds,
      'siren_duration_seconds': sirenDurationSeconds,
      'ai_assist_enabled': aiAssistEnabled,
      'notes': notes?.trim(),
    });
    await _audit('settings_safety_updated', {
      'entry_delay_seconds': entryDelaySeconds,
      'siren_duration_seconds': sirenDurationSeconds,
      'ai_assist_enabled': aiAssistEnabled,
    });
  }

  Future<void> savePreferences({
    required bool notificationsEnabled,
    required bool pushNotifications,
    required bool emailAlerts,
    required bool smsAlerts,
  }) async {
    await _db.from('user_preferences').upsert({
      'user_id': userId,
      'notifications_enabled': notificationsEnabled,
      'push_notifications': pushNotifications,
      'email_alerts': emailAlerts,
      'sms_alerts': smsAlerts,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
    await _mirror('user_preferences', userId, {
      'notifications_enabled': notificationsEnabled,
      'push_notifications': pushNotifications,
      'email_alerts': emailAlerts,
      'sms_alerts': smsAlerts,
    });
    await _audit('settings_notifications_updated', {
      'notifications_enabled': notificationsEnabled,
      'push_notifications': pushNotifications,
      'email_alerts': emailAlerts,
      'sms_alerts': smsAlerts,
    });
  }

  Future<void> saveAppearance({required bool darkMode}) async {
    await _db.from('user_preferences').upsert({
      'user_id': userId,
      'dark_mode': darkMode,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
    await _mirror('user_preferences', userId, {
      'dark_mode': darkMode,
      'theme': darkMode ? 'dark' : 'light',
    });
    await _audit('settings_appearance_updated', {
      'dark_mode': darkMode,
      'theme': darkMode ? 'dark' : 'light',
    });
  }

  Future<void> saveDevice({required String deviceId, String? deviceName}) async {
    await _db.from('devices').upsert({
      'user_id': userId,
      'device_id': deviceId.trim(),
      'device_name': (deviceName?.trim().isNotEmpty ?? false) ? deviceName!.trim() : 'Main PyroGuard Controller',
      'device_type': 'ESP32_MAIN',
      'status': 'registered',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'device_id');
    await _db.auth.updateUser(UserAttributes(data: {
      ...?_db.auth.currentUser?.userMetadata,
      'device_id': deviceId.trim(),
    }));
    await DualSyncService.instance.syncAccountIdentity();
    await _mirror('devices', deviceId.trim(), {
      'device_id': deviceId.trim(),
      'device_name': (deviceName?.trim().isNotEmpty ?? false) ? deviceName!.trim() : 'Main PyroGuard Controller',
      'status': 'registered',
    });
    await _audit('settings_device_updated', {'device_id': deviceId.trim()});
  }

  Future<void> _mirror(String type, String key, Map<String, dynamic> payload) async {
    try {
      await DualSyncService.instance.writeMirror(
        recordType: type,
        recordKey: key,
        payload: payload,
      );
    } catch (e) {
      debugPrint('Settings mirror pending: $e');
    }
  }

  Future<void> _audit(String eventType, Map<String, dynamic> values) async {
    try {
      await HistoricalService.instance.logEvent({
        'event_type': eventType,
        'message': 'PyroGuard settings changed',
        'severity': 0,
        'payload': values,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('Settings audit write skipped: $e');
    }
  }
}
