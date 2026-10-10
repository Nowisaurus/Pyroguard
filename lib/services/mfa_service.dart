import 'package:supabase_flutter/supabase_flutter.dart';

/// Server-verified authenticator assurance checks. Never trust user-editable metadata.
class MfaService {
  static final _auth = Supabase.instance.client.auth;

  static Future<bool> needsVerification() async {
    if (_auth.currentSession == null) return false;
    try {
      final assurance = await _auth.mfa.getAuthenticatorAssuranceLevel();
      return assurance.nextLevel == AuthenticatorAssuranceLevels.aal2 &&
          assurance.currentLevel != AuthenticatorAssuranceLevels.aal2;
    } catch (_) {
      // Fail closed: an unavailable assurance service cannot authorize entry.
      return true;
    }
  }
}
