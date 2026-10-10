import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'settings_service.dart';
import 'dual_sync_service.dart';
import 'historical_service.dart';
import 'admin_identity.dart';

/// Repairs/completes the four-part homeowner registration after a valid Auth
/// session exists. This is intentionally idempotent: it may run after immediate
/// signup, after email verification, or on a later login without duplicating
/// singleton configuration rows.
///
/// Supabase Auth is the credential authority. Every non-secret application
/// record created here is retained in Supabase and synchronously mirrored to
/// MySQL through [DualSyncService], with retry/outbox protection if MySQL is
/// temporarily unavailable.
class AccountBootstrapService {
  AccountBootstrapService._();
  static final AccountBootstrapService instance = AccountBootstrapService._();
  bool _running = false;

  Future<void> ensureRegistrationPersisted({bool force = false}) async {
    if (_running) return;
    final db = Supabase.instance.client;
    final user = db.auth.currentUser;
    if (user == null) return;

    _running = true;
    try {
      // Fixed admins do not receive homeowner/property setup, but their
      // non-secret identity must still exist in both databases.
      if (AdminIdentity.isFixedAdminEmail(user.email)) {
        await DualSyncService.instance.syncAccountIdentity();
        await DualSyncService.instance.retryPending();
        return;
      }

      final meta = user.userMetadata ?? const <String, dynamic>{};
      final alreadyPersisted = meta['registration_persisted'] == true;

      // Always refresh account identity. This also catches users created while
      // email confirmation was enabled (no session existed on the signup page).
      await DualSyncService.instance.syncAccountIdentity();
      final identity = await db.from('account_identities').select('user_id').eq('user_id', user.id).maybeSingle();
      if (identity == null) throw StateError('Account source repair incomplete; apply the current Supabase SQL and run the worker.');

      if (!alreadyPersisted || force) {
        final fullName = (meta['full_name'] ??
                user.email?.split('@').first ??
                'Homeowner')
            .toString();
        final phone = (meta['phone_number'] ?? '').toString();
        await SettingsService.instance.saveProfile(
          fullName: fullName,
          phone: phone,
        );

        final homeName = (meta['home_name'] ?? 'My Home').toString();
        final address = (meta['address'] ?? '').toString();
        if (meta['home_name'] != null || meta['address'] != null) {
          await SettingsService.instance.saveHome(
            homeName: homeName,
            address: address,
            latitude: (meta['home_latitude'] as num?)?.toDouble(),
            longitude: (meta['home_longitude'] as num?)?.toDouble(),
          );
        }

        if (meta['stakeholder_name'] != null) {
          await SettingsService.instance.saveStakeholder(
            fullName: meta['stakeholder_name'].toString(),
            relationship:
                (meta['stakeholder_relationship'] ?? 'Homeowner').toString(),
            phone: (meta['stakeholder_phone'] ?? phone).toString(),
          );
        }

        if (meta['bfp_station_name'] != null) {
          await SettingsService.instance.saveBfp(
            stationName: meta['bfp_station_name'].toString(),
            personnelName: meta['bfp_personnel_name']?.toString(),
            rankPosition: meta['bfp_rank_position']?.toString(),
            phone: (meta['bfp_phone'] ?? '').toString(),
            address: (meta['bfp_address'] ?? '').toString(),
          );
        }

        await SettingsService.instance.saveSafety(
          acknowledged: meta['safety_acknowledged'] == true,
          entryDelaySeconds: 20,
          sirenDurationSeconds: 60,
          aiAssistEnabled: true,
        );
        await SettingsService.instance.savePreferences(
          notificationsEnabled: true,
          pushNotifications: true,
          emailAlerts: false,
          smsAlerts: false,
        );

        final deviceId = (meta['device_id'] ?? '').toString().trim();
        if (deviceId.isNotEmpty) {
          await SettingsService.instance.saveDevice(deviceId: deviceId);
          final initialState = <String, dynamic>{
            'user_id': user.id,
            'device_id': deviceId,
            'arm_mode': 'DISARMED',
            'door_enabled': true,
            'window_enabled': true,
            'motion_enabled': true,
            'acting_user': user.id,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          };
          await db.from('system_state').upsert(
                initialState,
                onConflict: 'device_id',
              );
          await DualSyncService.instance.writeMirror(
            recordType: 'system_state',
            recordKey: deviceId,
            payload: initialState,
          );
        }

        final completedAt = DateTime.now().toUtc().toIso8601String();
        await db.auth.updateUser(UserAttributes(data: {
          ...meta,
          'registration_persisted': true,
          'registration_persisted_at': completedAt,
        }));

        await DualSyncService.instance.writeMirror(
          recordType: 'registration_state',
          recordKey: user.id,
          payload: {
            'registration_persisted': true,
            'completed_at': completedAt,
            'home_name': homeName,
            'address': address,
            'device_id': deviceId,
          },
        );
        await HistoricalService.instance.logEvent({
          'event_type': 'homeowner_registration_persisted',
          'message':
              'Homeowner registration was saved to Supabase and queued/saved to MySQL.',
          'severity': 0,
          'payload': {
            'home_name': homeName,
            'address': address,
            'device_id': deviceId,
          },
          'created_at': completedAt,
        });
      }

      // A previous MySQL outage must never leave the databases permanently
      // divergent. Retry all pending mirrors after every successful session.
      await DualSyncService.instance.retryPending();
    } catch (e) {
      // Do not invalidate a valid Supabase Auth session because MySQL or a
      // non-auth settings write is temporarily unavailable. The outbox/ledger
      // keeps pending records for later synchronization.
      debugPrint('Account bootstrap non-fatal/pending: $e');
    } finally {
      _running = false;
    }
  }
}
