import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Device-local inactivity lock. This does not replace server session policies.
class InactivityService {
  InactivityService._();
  static final instance = InactivityService._();
  static const timeout = Duration(hours: 24);
  bool verifyingOtp = false;
  String? pendingEmail;
  int _lastWrite = 0;
  Future<bool> requiresOtp(User user) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = prefs.getInt('pyroguard_activity_${user.id}');
    final locked = prefs.getBool('pyroguard_otp_required_${user.id}') == true;
    if (locked || (last != null && (now - last >= timeout.inMilliseconds || now < last))) {
      await prefs.setBool('pyroguard_otp_required_${user.id}', true);
      pendingEmail = user.email;
      if (pendingEmail != null) await prefs.setString('pyroguard_pending_otp_email', pendingEmail!);
      return true;
    }
    // Establish an initial baseline for existing installations without history.
    if (last == null) await prefs.setInt('pyroguard_activity_${user.id}', now);
    return false;
  }
  Future<String> restoredEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return pendingEmail ?? prefs.getString('pyroguard_pending_otp_email') ?? '';
  }
  Future<void> activity() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || verifyingOtp) return;
    // Never let a tap after 24h reset the expired timestamp before checking it.
    if (await requiresOtp(user)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastWrite < 1000) return;
    _lastWrite = now;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pyroguard_activity_${user.id}', now);
  }
  Future<void> verified(User user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pyroguard_otp_required_${user.id}');
    await prefs.setInt('pyroguard_activity_${user.id}', DateTime.now().millisecondsSinceEpoch);
    if ((await restoredEmail()).toLowerCase() == (user.email ?? '').toLowerCase()) {
      pendingEmail = null;
      await prefs.remove('pyroguard_pending_otp_email');
    }
  }
}
