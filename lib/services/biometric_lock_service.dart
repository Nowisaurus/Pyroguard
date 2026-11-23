import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fingerprint / face unlock for the mobile app (panel suggestion: "there
/// should be a fingerprint on the cellphone ... as a security").
/// The Supabase session stays signed in; the biometric check only unlocks
/// the app on this phone. Not used on the web build.
class BiometricLockService {
  BiometricLockService._();
  static final instance = BiometricLockService._();

  static const _prefKey = 'pyroguard_biometric_lock';
  static const _emailKey = 'pyroguard_fp_email';
  static const _passKey = 'pyroguard_fp_password';
  final _auth = LocalAuthentication();
  // Android Keystore / iOS Keychain encrypted storage (never plain text).
  final _vault = const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  Future<bool> isSupported() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isEnabled() async {
    if (kIsWeb) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, value);
    if (!value) await clearLogin();
  }

  /// Shows the system fingerprint / face prompt. Returns true when verified.
  Future<bool> authenticate({String reason = 'Unlock PyroGuard'}) async {
    if (kIsWeb) return true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false, // allows the phone PIN as a fallback
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('Biometric unlock failed: $e');
      return false;
    }
  }

  // ── Fingerprint sign-in (panel: "add fingerprint para in case magkamali si
  // user, maopen pa rin ang account") ──────────────────────────────────────
  /// Saves the login on this phone, encrypted, for fingerprint sign-in.
  Future<void> saveLogin(String email, String password) async {
    if (kIsWeb) return;
    try {
      await _vault.write(key: _emailKey, value: email.trim().toLowerCase());
      await _vault.write(key: _passKey, value: password);
    } catch (e) {
      debugPrint('Fingerprint login not saved: $e');
    }
  }

  Future<({String email, String password})?> readLogin() async {
    if (kIsWeb) return null;
    try {
      final email = await _vault.read(key: _emailKey);
      final pass = await _vault.read(key: _passKey);
      if (email == null || pass == null || email.isEmpty || pass.isEmpty) return null;
      return (email: email, password: pass);
    } catch (_) {
      return null;
    }
  }

  Future<String?> savedEmail() async => (await readLogin())?.email;

  Future<void> clearLogin() async {
    if (kIsWeb) return;
    try {
      await _vault.delete(key: _emailKey);
      await _vault.delete(key: _passKey);
    } catch (_) {}
  }

  /// True when the fingerprint sign-in button should appear on the login page.
  Future<bool> canSignInWithFingerprint() async =>
      await isEnabled() && await isSupported() && await readLogin() != null;
}
