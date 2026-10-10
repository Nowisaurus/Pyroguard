import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'admin_identity.dart';
import 'mfa_service.dart';

enum VerifiedRole { signedOut, homeowner, administrator, denied }

/// Fail-closed role resolution. Profile and identity records are checked against
/// the live, authenticated user and the fixed admin registry.
class VerifiedRoleService {
  static String? lastFailure;
  static VerifiedRole deny(String reason) {
    lastFailure = reason;
    assert(() { debugPrint('[PyroGuard role] DENIED: $reason'); return true; }());
    return VerifiedRole.denied;
  }

  static Future<VerifiedRole> resolve() async {
    lastFailure = null;
    final db = Supabase.instance.client;
    final user = db.auth.currentUser;
    if (user == null || db.auth.currentSession == null) return VerifiedRole.signedOut;
    if (user.emailConfirmedAt == null && user.appMetadata['provider'] == 'email') {
      return deny('Supabase email is unconfirmed');
    }
    if (await MfaService.needsVerification()) return deny('MFA assurance check requires verification or failed');
    try {
      final results = await Future.wait<dynamic>([
        db.from('profiles').select('account_role,account_status,email').eq('user_id', user.id).maybeSingle(),
        db.from('account_identities').select('account_role,account_status,email,email_confirmed').eq('user_id', user.id).maybeSingle(),
        db.from('admin_accounts').select('user_id,email,admin_role,active').eq('user_id', user.id).maybeSingle(),
      ]);
      final profile = results[0] as Map<String,dynamic>?;
      final identity = results[1] as Map<String,dynamic>?;
      final admin = results[2] as Map<String,dynamic>?;
      if (profile == null) return deny('profiles record missing or hidden by RLS');
      if (identity == null) return deny('account_identities record missing or hidden by RLS');
      final email = AdminIdentity.normalize(user.email);
      if (AdminIdentity.normalize(profile['email']?.toString()) != email ||
          AdminIdentity.normalize(identity['email']?.toString()) != email ||
          profile['account_status'] != 'active' || identity['account_status'] != 'active') {
        return deny('Profile/identity email or active status mismatch');
      }
      final fixed = AdminIdentity.isFixedAdminEmail(email);
      final marked = AdminIdentity.userMetadataMarksAdmin(user.appMetadata);
      if (fixed || marked || admin != null) {
        if (!fixed || !marked || admin == null || admin['active'] != true ||
            admin['user_id'] != user.id || AdminIdentity.normalize(admin['email']?.toString()) != email ||
            profile['account_role'] != admin['admin_role'] || identity['account_role'] != admin['admin_role']) {
          return deny('Admin allowlist, JWT metadata, registry, or role mismatch (admin row missing may be RLS)');
        }
        return VerifiedRole.administrator;
      }
      if (profile['account_role'] != 'homeowner' || identity['account_role'] != 'homeowner') {
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
