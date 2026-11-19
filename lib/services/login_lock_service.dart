import 'package:shared_preferences/shared_preferences.dart';
import '../config/pyroguard_config.dart';

class LoginLockStatus {
  final int failedAttempts;
  final DateTime? lockedUntil;
  final bool extendedLock;

  const LoginLockStatus({
    required this.failedAttempts,
    required this.lockedUntil,
    this.extendedLock = false,
  });

  bool get isLocked =>
      lockedUntil != null && DateTime.now().isBefore(lockedUntil!);

  int get remainingAttempts =>
      (failedAttempts < PyroGuardConfig.maxLoginAttempts
          ? PyroGuardConfig.maxLoginAttempts - failedAttempts
          : PyroGuardConfig.extendedLoginAttempts - failedAttempts)
          .clamp(0, PyroGuardConfig.extendedLoginAttempts).toInt();

  Duration get remainingLockTime {
    if (!isLocked) return Duration.zero;
    return lockedUntil!.difference(DateTime.now());
  }
}

/// Persists failed-login protection locally so closing/reopening the app does
/// not reset the attempt counter. Passwords are never stored.
class LoginLockService {
  LoginLockService._();

  static String _accountKey(String email) {
    final normalized = email.trim().toLowerCase();
    return normalized.replaceAll(RegExp(r'[^a-z0-9]'), '_');
  }

  static Future<LoginLockStatus> statusFor(String email) async {
    if (email.trim().isEmpty) {
      return const LoginLockStatus(failedAttempts: 0, lockedUntil: null);
    }

    final prefs = await SharedPreferences.getInstance();
    final key = _accountKey(email);
    final attempts = prefs.getInt('login_failures_$key') ?? 0;
    final extended = prefs.getBool('login_extended_$key') ?? false;
    final lockedUntilMs = prefs.getInt('login_locked_until_$key');
    DateTime? lockedUntil = lockedUntilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(lockedUntilMs);

    // Expired locks are cleared automatically.
    if (lockedUntil != null && !DateTime.now().isBefore(lockedUntil)) {
      await prefs.remove('login_locked_until_$key');
      await prefs.remove('login_extended_$key');
      if (extended) {
        await prefs.remove('login_failures_$key');
        return const LoginLockStatus(failedAttempts: 0, lockedUntil: null);
      }
      // The first tier has elapsed; retain cumulative failures until success
      // or the longer lock expires. Another wrong password re-triggers 1 min.
      return LoginLockStatus(failedAttempts: attempts, lockedUntil: null);
    }

    return LoginLockStatus(
      failedAttempts: attempts,
      lockedUntil: lockedUntil,
      extendedLock: extended,
    );
  }

  static Future<LoginLockStatus> registerFailure(String email) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _accountKey(email);
    final current = await statusFor(email);
    if (current.isLocked) return current;

    final next = current.failedAttempts + 1;
    await prefs.setInt('login_failures_$key', next);

    if (next >= PyroGuardConfig.maxLoginAttempts) {
      final extended = next >= PyroGuardConfig.extendedLoginAttempts;
      final lockedUntil = DateTime.now().add(extended
          ? PyroGuardConfig.extendedLoginLockDuration
          : PyroGuardConfig.loginLockDuration);
      await prefs.setBool('login_extended_$key', extended);
      await prefs.setInt('login_locked_until_$key', lockedUntil.millisecondsSinceEpoch);
      return LoginLockStatus(
        failedAttempts: next,
        lockedUntil: lockedUntil,
        extendedLock: extended,
      );
    }

    return LoginLockStatus(failedAttempts: next, lockedUntil: null);
  }

  static Future<void> clear(String email) async {
    if (email.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _accountKey(email);
    await prefs.remove('login_failures_$key');
    await prefs.remove('login_locked_until_$key');
    await prefs.remove('login_extended_$key');
  }
}
