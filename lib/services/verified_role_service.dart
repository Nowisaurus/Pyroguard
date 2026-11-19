import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_identity.dart';
import 'mfa_service.dart';

enum VerifiedRole { signedOut, homeowner, administrator, denied }

/// Fail-closed role resolution against the authenticated Supabase user,
/// the fixed admin allowlist, and the database identity/role records.
class VerifiedRoleService {
  static String? lastFailure;
  static final Set<String> _prepared = <String>{};

  static VerifiedRole deny(String reason) {
    lastFailure = reason;
    if (kDebugMode) {
      debugPrint('[PyroGuard role] DENIED: $reason');
    }
    return VerifiedRole.denied;
  }

  static Future<VerifiedRole> resolve() async {
    lastFailure = null;
    final db = Supabase.instance.client;
    final user = db.auth.currentUser;
    if (user == null || db.auth.currentSession == null) {
      return VerifiedRole.signedOut;
    }

    if (user.emailConfirmedAt == null &&
        user.appMetadata['provider'] == 'email') {
      return deny('Supabase email is unconfirmed');
    }

    try {
      if (await MfaService.needsVerification()) {
        return deny('MFA assurance check requires verification or failed');
      }

      if (!_prepared.contains(user.id)) {
        await db.rpc(
          'pyroguard_save_session',
          params: {'session_event': null},
        );
        _prepared.add(user.id);
      }

      final results = await Future.wait<Map<String, dynamic>?>([
        db.from('profiles')
            .select('account_role,account_status,email')
            .eq('user_id', user.id)
            .maybeSingle(),
        db.from('account_identities')
            .select('account_role,account_status,email,email_confirmed')
            .eq('user_id', user.id)
            .maybeSingle(),
        db.from('admin_accounts')
            .select('user_id,email,admin_role,active')
            .eq('user_id', user.id)
            .maybeSingle(),
      ]);

      final profile = results[0];
      final identity = results[1];
      final admin = results[2];

      if (profile == null) {
        return deny('profiles record missing or hidden by RLS');
      }
      if (identity == null) {
        return deny('account_identities record missing or hidden by RLS');
      }

      final email = AdminIdentity.normalize(user.email);
      if (email.isEmpty ||
          AdminIdentity.normalize(profile['email']?.toString()) != email ||
          AdminIdentity.normalize(identity['email']?.toString()) != email ||
          profile['account_status'] != 'active' ||
          identity['account_status'] != 'active') {
        return deny('Profile/identity email or active status mismatch');
      }

      final registeredAdmin = AdminIdentity.byEmail(email);
      final fixed = registeredAdmin != null;
      final marked = AdminIdentity.userMetadataMarksAdmin(user.appMetadata);

      // Any admin indicator requires the complete admin authorization path.
      // Never fall back to homeowner access for an incomplete admin identity.
      if (fixed || marked || admin != null) {
        if (kDebugMode) {
          debugPrint('[Role Check] email=$email');
          debugPrint('[Role Check] fixed=$fixed');
          debugPrint('[Role Check] marked=$marked');
          debugPrint('[Role Check] adminExists=${admin != null}');
          debugPrint('[Role Check] adminActive=${admin?['active']}');
          debugPrint('[Role Check] adminUidMatches=${admin?['user_id'] == user.id}');
          debugPrint('[Role Check] adminEmailMatches=${AdminIdentity.normalize(admin?['email']?.toString()) == email}');
          debugPrint('[Role Check] adminRole=${admin?['admin_role']}');
          debugPrint('[Role Check] profileRole=${profile['account_role']}');
          debugPrint('[Role Check] identityRole=${identity['account_role']}');
        }

        if (registeredAdmin == null) {
          return deny('Administrator email is not in the fixed allowlist');
        }
        if (admin == null) {
          return deny('Administrator registry record missing or hidden by RLS');
        }
        if (admin['active'] != true) {
          return deny('Administrator registry account is inactive');
        }
        if (admin['user_id'] != user.id) {
          return deny('Administrator UID does not match Supabase Auth');
        }
        if (AdminIdentity.normalize(admin['email']?.toString()) != email) {
          return deny('Administrator email does not match Supabase Auth');
        }
        if (admin['admin_role'] != registeredAdmin.role) {
          return deny('Administrator registry role does not match fixed allowlist');
        }
        if (profile['account_role'] != registeredAdmin.role ||
            identity['account_role'] != registeredAdmin.role) {
          return deny('Profile/identity administrator role mismatch');
        }

        if (kDebugMode) {
          debugPrint('[PyroGuard role] Administrator verified: $email');
        }
        return VerifiedRole.administrator;
      }

      if (profile['account_role'] != 'homeowner' ||
          identity['account_role'] != 'homeowner') {
        return deny('Unexpected homeowner role');
      }
      return VerifiedRole.homeowner;
    } on PostgrestException catch (e) {
      return deny('Supabase query/RLS failed: ${e.code} ${e.message}');
    } catch (e) {
      return deny('Role verification exception: ${e.runtimeType}: $e');
    }
  }
}
