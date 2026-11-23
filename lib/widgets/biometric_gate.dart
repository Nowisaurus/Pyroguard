import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/biometric_lock_service.dart';
import '../theme.dart';

/// Covers the app with a lock screen on phones where fingerprint unlock is
/// turned on: when the app opens with a saved session, and when it returns
/// from the background after 30 seconds. Fire alarms and notifications are
/// not affected; only the app screen is locked.
class BiometricGate extends StatefulWidget {
  const BiometricGate({super.key, required this.child});
  final Widget child;

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate> with WidgetsBindingObserver {
  static const _relockAfter = Duration(seconds: 30);
  final _bio = BiometricLockService.instance;
  bool _locked = false;
  bool _prompting = false;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) return;
    WidgetsBinding.instance.addObserver(this);
    _lockIfNeeded();
  }

  @override
  void dispose() {
    if (!kIsWeb) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null ? Duration.zero : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (away >= _relockAfter) _lockIfNeeded();
    }
  }

  Future<void> _lockIfNeeded() async {
    final signedIn = Supabase.instance.client.auth.currentSession != null;
    if (!signedIn || !await _bio.isEnabled()) return;
    if (!mounted) return;
    setState(() => _locked = true);
    await _unlock();
  }

  Future<void> _unlock() async {
    if (_prompting) return;
    _prompting = true;
    final ok = await _bio.authenticate(reason: 'Unlock PyroGuard with your fingerprint');
    _prompting = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  Future<void> _usePassword() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) setState(() => _locked = false); // router sends the user to sign-in
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: Material(
          color: AppTheme.isDark(context) ? AppColors.darkBg : AppColors.lightBg,
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const PyroGuardLogo(),
                  const SizedBox(height: 18),
                  Text('PyroGuard is locked',
                      style: TextStyle(
                          color: AppTheme.textPrimary(context), fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text('Use your fingerprint (or phone PIN) to open the app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary(context))),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                    ),
                    onPressed: _unlock,
                    icon: const Icon(Icons.fingerprint_rounded, size: 26),
                    label: const Text('Unlock'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(onPressed: _usePassword, child: const Text('Sign in with password instead')),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}
