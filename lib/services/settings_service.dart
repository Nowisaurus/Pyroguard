import 'philippine_phone.dart';
import '../config/pyroguard_config.dart';
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

  /// Independently loads each part of registration. A missing optional table
  /// must never make other saved data (especially profile/BFP) disappear.
  Future<Map<String, dynamic>> loadAll() async {
    final user = _db.auth.currentUser;
    if (user == null) throw StateError('Sign in first.');
    final failures = <String>[];

    Future<Map<String, dynamic>> safely(
      String label,
      Future<dynamic> Function() operation,
    ) async {
      try {
        final value = await operation().timeout(const Duration(seconds: 12));
        return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
      } catch (error) {
        failures.add(label);
        debugPrint('Settings $label unavailable: $error');
        return <String, dynamic>{};
      }
    }

    final profile = await safely('profile', () =>
        _db.from('profiles').select().eq('id', user.id).maybeSingle());
    // Auth metadata is a read-only fallback; never overwrite verified DB rows.
    if (profile.isEmpty) {
      profile.addAll({
        'id': user.id,
        'email': user.email,
        'full_name': user.userMetadata?['full_name'] ?? '',
        'phone': user.userMetadata?['phone_number'] ?? '',
      });
    }
    // Prefer the signed-in user's own home. A shared member can see the
    // authorized existing home without creating another household record.
    final home = await safely('home', () async {
      final own = await _singleForUser('homes');
      if (own != null) return own;
      final memberships = await _db.from('pyroguard_home_members')
          .select('home_id')
          .eq('user_id', user.id)
          .eq('membership_status', 'approved')
          .limit(1);
      if (memberships.isEmpty) return null;
      return _db.from('homes').select()
          .eq('id', memberships.first['home_id']).maybeSingle();
    });
    final stakeholder = await safely('stakeholder', () => _db.from('stakeholders')
        .select().eq('user_id', user.id).eq('is_primary', true).maybeSingle());
    final bfp = await safely('bfp', () => _db.from('emergency_contacts')
        .select().eq('user_id', user.id).eq('is_primary', true).maybeSingle());
    final safety = await safely('safety', () => _singleForUser('safety_setups'));
    final preferences = await safely('preferences', () => _singleForUser('user_preferences'));
    final device = await safely('device', () async {
      final own = await _db.from('devices').select()
          .eq('user_id', user.id).order('created_at', ascending: false)
          .limit(1).maybeSingle();
      if (own != null) return own;
      // Shared Home 1 hardware: the Batch 1 controller (RLS decides access).
      return _db.from('devices').select()
          .eq('device_id', PyroGuardConfig.mainDeviceId).maybeSingle();
    });

    return {
      'profile': profile,
      'home': home,
      'stakeholder': stakeholder,
      'bfp': bfp,
      'safety': safety,
      'preferences': preferences,
      'device': device,
      '_load_errors': failures,
    };
  }

  /// Confirm that the database really contains the submitted values before
  /// telling the user that a save succeeded. RLS errors are propagated.
  Future<void> _verifySaved(
    String table,
    String keyColumn,
    Object key,
    Map<String, dynamic> expected,
  ) async {
    final row = await _db.from(table).select(expected.keys.join(','))
        .eq(keyColumn, key).maybeSingle();
    if (row == null) {
      throw StateError('Save verification failed for $table: record was not readable.');
    }
    for (final field in expected.keys) {
      final actual = row[field];
      final wanted = expected[field];
      if (actual is num && wanted is num) {
        if ((actual.toDouble() - wanted.toDouble()).abs() < 0.000001) continue;
      } else if (actual == wanted) {
        continue;
      }
      throw StateError('Save verification failed for $table.$field.');
    }
  }

  Future<void> saveProfile({required String fullName, required String phone}) async {
    final user = _db.auth.currentUser!;
    await _db.from('profiles').upsert({
      'id': user.id,
      'user_id': user.id,
      'full_name': fullName.trim(),
      'email': user.email,
      'phone': PhilippinePhone.normalize(phone),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'id');
    final confirmedProfile = await _db.from('profiles')
        .select('id,full_name,phone')
        .eq('id', user.id).single();
    if (confirmedProfile['full_name']?.toString() != fullName.trim() ||
        confirmedProfile['phone']?.toString() != PhilippinePhone.normalize(phone)) {
      throw StateError('Profile verification failed: stored details do not match.');
    }
    try {
      await _db.auth.updateUser(UserAttributes(data: {
        ...?user.userMetadata,
        'full_name': fullName.trim(),
        'phone_number': PhilippinePhone.normalize(phone),
      }));
      await DualSyncService.instance.syncAccountIdentity();
    } catch (error) {
      debugPrint('Profile saved; Auth metadata sync pending: $error');
    }
    await _mirror('profiles', user.id, {
      'full_name': fullName.trim(),
      'email': user.email,
      'phone': PhilippinePhone.normalize(phone),
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
    await _verifySaved('homes', 'user_id', userId, {'home_name': homeName.trim(), 'address': address.trim()});
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
      'phone': PhilippinePhone.normalize(phone),
      'is_primary': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (existing == null) {
      await _db.from('stakeholders').insert(data);
    } else {
      await _db.from('stakeholders').update(data).eq('id', existing['id']);
    }
    await _verifySaved('stakeholders', 'id', (await _db.from('stakeholders').select('id').eq('user_id', userId).eq('is_primary', true).single())['id'], {'full_name': fullName.trim(), 'relationship': relationship.trim(), 'phone': PhilippinePhone.normalize(phone)});
    await _mirror('stakeholders', userId, {
      'full_name': fullName.trim(),
      'relationship': relationship.trim(),
      'phone': PhilippinePhone.normalize(phone),
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
    String? email,
    bool confirmed = true,
  }) async {
    final cleanEmail = (email ?? '').trim().toLowerCase();
    if (cleanEmail.isNotEmpty && !isValidEmail(cleanEmail)) {
      throw ArgumentError('Enter a valid BFP e-mail address (example: bfp.station@gmail.com) or leave it blank.');
    }
    final existing = await _db.from('emergency_contacts').select('id').eq('user_id', userId).eq('is_primary', true).maybeSingle();
    final data = {
      'user_id': userId,
      'station_name': stationName.trim(),
      'name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'rank_position': rankPosition?.trim(),
      'phone': PhilippinePhone.normalize(phone),
      'address': address.trim(),
      // Used to e-mail incident report PDFs to the station (v17).
      'email': cleanEmail.isEmpty ? null : cleanEmail,
      'is_primary': true,
      'is_confirmed': confirmed,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    if (existing == null) {
      await _db.from('emergency_contacts').insert(data);
    } else {
      await _db.from('emergency_contacts').update(data).eq('id', existing['id']);
    }
    final confirmedBfp = await _db.from('emergency_contacts')
        .select('station_name,personnel_name,rank_position,phone,address,is_confirmed')
        .eq('user_id', userId).eq('is_primary', true).single();
    if (confirmedBfp['station_name']?.toString() != stationName.trim() ||
        confirmedBfp['phone']?.toString() != PhilippinePhone.normalize(phone) ||
        confirmedBfp['is_confirmed'] != confirmed) {
      throw StateError('BFP contact verification failed: stored details do not match.');
    }
    await _mirror('emergency_contacts', userId, {
      'station_name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'rank_position': rankPosition?.trim(),
      'phone': PhilippinePhone.normalize(phone),
      'address': address.trim(),
      'confirmed': confirmed,
    });
    await _audit('settings_bfp_updated', {
      'station_name': stationName.trim(),
      'personnel_name': personnelName?.trim(),
      'phone': PhilippinePhone.normalize(phone),
      'confirmed': confirmed,
    });
  }

  static bool isValidEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim()) && value.trim().length <= 254;

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
    await _verifySaved('safety_setups', 'user_id', userId, {'safety_acknowledged': acknowledged, 'entry_delay_seconds': entryDelaySeconds, 'siren_duration_seconds': sirenDurationSeconds, 'ai_assist_enabled': aiAssistEnabled});
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
    await _verifySaved('user_preferences', 'user_id', userId, {'notifications_enabled': notificationsEnabled, 'push_notifications': pushNotifications, 'email_alerts': emailAlerts, 'sms_alerts': smsAlerts});
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
    await _verifySaved('user_preferences', 'user_id', userId, {'dark_mode': darkMode});
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
    final existing = await _db.from('devices')
        .select('device_id,user_id')
        .eq('device_id', deviceId.trim()).maybeSingle();
    if (existing != null && existing['user_id'] != userId) {
      throw StateError(
        'This device is registered to another homeowner. '
        'Shared-home members must use the existing device registration.'
      );
    }
    await _db.from('devices').upsert({
      'user_id': userId,
      'device_id': deviceId.trim(),
      'device_name': (deviceName?.trim().isNotEmpty ?? false) ? deviceName!.trim() : 'Main PyroGuard Controller',
      'device_type': 'ESP32_MAIN',
      'status': 'registered',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'device_id');
    try {
      await _db.auth.updateUser(UserAttributes(data: {
        ...?_db.auth.currentUser?.userMetadata,
        'device_id': deviceId.trim(),
      }));
      await DualSyncService.instance.syncAccountIdentity();
    } catch (error) {
      debugPrint('Device saved; Auth metadata sync pending: $error');
    }
    await _verifySaved('devices', 'device_id', deviceId.trim(), {'user_id': userId, 'device_id': deviceId.trim(), 'status': 'registered'});
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
