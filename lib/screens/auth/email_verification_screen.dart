import '../../services/inactivity_service.dart';
import '../../theme.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/account_bootstrap_service.dart';

class EmailVerificationScreen extends StatefulWidget {
  final String email;
  final bool reauthenticate;
  const EmailVerificationScreen({super.key, this.email = '', this.reauthenticate = false});
  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  late final TextEditingController _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  bool _busy = false;
  String? _message;
  int _remaining = 60;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    if (widget.reauthenticate) {
      _remaining = 0;
      InactivityService.instance.restoredEmail().then((email) {
        if (mounted && _email.text.isEmpty) setState(() => _email.text = email);
      });
    } else {
      _startCooldown();
    }
  }
  void _startCooldown() {
    _remaining = 60;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() => _remaining--);
      if (_remaining <= 0) timer.cancel();
    });
  }
  @override
  void dispose() { _timer?.cancel(); _email.dispose(); _code.dispose(); super.dispose(); }
  Future<void> _submit({bool resend = false}) async {
    final email = _email.text.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(() => _message = 'Enter the email used for signup.'); return;
    }
    if (!resend && !RegExp(r'^\d{6,8}$').hasMatch(_code.text.trim())) {
      setState(() => _message = 'Enter the 6–8 digit code from your email.'); return;
    }
    setState(() { _busy = true; _message = null; });
    try {
      final db = Supabase.instance.client;
      if (resend) {
        if (widget.reauthenticate) {
          await db.auth.signInWithOtp(email: email, shouldCreateUser: false,
            emailRedirectTo: 'https://pyroguard-web-blue.vercel.app/');
        } else {
          await db.auth.resend(type: OtpType.signup, email: email,
            emailRedirectTo: 'https://pyroguard-web-blue.vercel.app/');
        }
        if (mounted) setState(() { _startCooldown(); _message = 'Confirmation requested. Check your inbox and spam folder.'; });
      } else {
        InactivityService.instance.verifyingOtp = true;
        final response = await db.auth.verifyOTP(email: email,
          token: _code.text.trim(), type: OtpType.email);
        if (response.session == null || response.user == null ||
            (!widget.reauthenticate && response.user?.emailConfirmedAt == null)) {
          throw const AuthException('Email verification did not complete. Request a fresh code.');
        }
        await InactivityService.instance.verified(response.user!);
        InactivityService.instance.verifyingOtp = false;
        // Supabase verifies the code; the app never generates or stores OTPs.
        // Session audit is best-effort: an unavailable optional RPC must not
        // block a successful Supabase OTP confirmation.
        try {
          await db.rpc('pyroguard_save_session', params: {'session_event': null});
        } catch (error) {
          debugPrint('Session audit unavailable after successful OTP: $error');
        }
        await AccountBootstrapService.instance.ensureRegistrationPersisted(force: !widget.reauthenticate);
        if (mounted) context.go(widget.reauthenticate ? '/dashboard' : '/tutorial');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not complete verification/setup. If your email is already confirmed, sign in to retry account setup.');
    } finally {
      InactivityService.instance.verifyingOtp = false;
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: PhoenixBackdrop(child: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 470),
        child: GlassPanel(radius: 26, blur: 18,
          tint: AppTheme.isDark(context) ? const Color(0xFF171410).withValues(alpha: .58) : Colors.white.withValues(alpha: .62),
          borderColor: AppColors.orange.withValues(alpha: .46),
          glowColor: AppColors.orange.withValues(alpha: .17),
          padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 25),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Center(child: PyroGuardLogo()),
            const SizedBox(height: 12),
            Text(widget.reauthenticate ? 'Verify to continue' : 'Confirm your account',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900,
              color: AppTheme.textPrimary(context))),
            const SizedBox(height: 8),
            Text(widget.reauthenticate
              ? 'Enter the email code to securely restore your session.'
              : 'Enter the verification code sent to your email to activate PyroGuard.',
              textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: AppTheme.textSecondary(context))),
            const SizedBox(height: 20),
            TextField(controller: _email, enabled: !_busy, keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(prefixIcon: Icon(Icons.alternate_email), labelText: 'Email address',
                border: OutlineInputBorder())),
            const SizedBox(height: 13),
            TextField(controller: _code, enabled: !_busy, keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode], maxLength: 8,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(prefixIcon: Icon(Icons.verified_user_outlined),
                labelText: 'Verification code', helperText: 'Enter the 6–8 digit code from your email',
                border: OutlineInputBorder())),
            if (_message != null) Padding(padding: const EdgeInsets.only(bottom: 12),
              child: Text(_message!, textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textPrimary(context)))),
            const SizedBox(height: 5),
            FilledButton.icon(onPressed: _busy ? null : () => _submit(),
              icon: const Icon(Icons.check_circle_outline),
              label: Text(_busy ? 'Please wait…' : widget.reauthenticate ? 'Verify and continue' : 'Confirm Account')),
            const SizedBox(height: 5),
            OutlinedButton.icon(onPressed: _busy || _remaining > 0 ? null : () => _submit(resend: true),
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: Text(_remaining > 0 ? 'Resend in ${_remaining}s' : widget.reauthenticate ? 'Send / resend code' : 'Resend Code')),
            TextButton.icon(onPressed: _busy ? null : () => context.go('/login'),
              icon: const Icon(Icons.arrow_back), label: const Text('Back to Log In')),
          ]),
        ),
      ),
    )))),
  );
}
