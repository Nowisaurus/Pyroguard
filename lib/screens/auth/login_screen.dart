import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/pyroguard_config.dart';
import '../../services/login_lock_service.dart';
import '../../services/admin_identity.dart';
import '../../services/admin_service.dart';
import '../../services/verified_role_service.dart';
import '../../services/mfa_service.dart';
import '../../services/dual_sync_service.dart';
import '../../services/account_bootstrap_service.dart';
import '../../theme.dart';
import '../../responsive.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCt = TextEditingController();
  final _passCt = TextEditingController();

  bool _obscure = true;
  bool _rememberEmail = false;
  bool _loading = false;
  String? _error;
  LoginLockStatus _lockStatus =
      const LoginLockStatus(failedAttempts: 0, lockedUntil: null);
  Timer? _lockTimer;

  bool get _locked => _lockStatus.isLocked;

  @override
  void initState() {
    super.initState();
    _emailCt.addListener(_onEmailChanged);
    _restoreRememberedEmail();
    WidgetsBinding.instance.addPostFrameCallback((_) => _guardExistingSession());
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _lockStatus.lockedUntil == null) return;
      if (!_lockStatus.isLocked) {
        _refreshLockStatus();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _emailCt.removeListener(_onEmailChanged);
    _emailCt.dispose();
    _passCt.dispose();
    super.dispose();
  }

  void _onEmailChanged() {
    _refreshLockStatus();
  }

  Future<void> _restoreRememberedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString('pyroguard_remembered_email');
    if (saved != null && saved.isNotEmpty) {
      _emailCt.text = saved;
      setState(() => _rememberEmail = true);
    }
  }

  Future<void> _saveRememberedEmail(String email) async {
    final prefs = await SharedPreferences.getInstance();
    if (_rememberEmail) {
      await prefs.setString('pyroguard_remembered_email', email);
    } else {
      await prefs.remove('pyroguard_remembered_email');
    }
  }

  Future<void> _guardExistingSession() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null || !mounted) return;
    final role = await VerifiedRoleService.resolve();
    if (!mounted) return;
    if (role == VerifiedRole.administrator) context.go('/admin');
    if (role == VerifiedRole.homeowner) context.go('/dashboard');
    if (role == VerifiedRole.denied) context.go('/access-denied');
  }

  Future<void> _refreshLockStatus() async {
    final email = _emailCt.text;
    final status = await LoginLockService.statusFor(email);
    if (!mounted || _emailCt.text != email) return;
    setState(() => _lockStatus = status);
  }

  bool _isCredentialFailure(String message) {
    final m = message.toLowerCase();
    return m.contains('invalid') ||
        m.contains('credentials') ||
        m.contains('wrong') ||
        m.contains('user not found');
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailCt.text.trim().toLowerCase();
    final before = await LoginLockService.statusFor(email);
    if (!mounted) return;
    if (before.isLocked) {
      setState(() {
        _lockStatus = before;
        _error = _lockText(before);
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _lockStatus = before;
    });

    try {
      final response = await Supabase.instance.client.auth.signInWithPassword(
        email: email,
        password: _passCt.text,
      );

      if (response.session == null || response.user == null) {
        throw AuthException('Invalid login credentials');
      }

      if (await MfaService.needsVerification()) {
        if (mounted) context.go('/mfa');
        return;
      }
      await _saveRememberedEmail(email);
      final role = await VerifiedRoleService.resolve();
      if (!mounted) return;
      if (role == VerifiedRole.denied) {
        context.go('/access-denied');
        return;
      }
      if (role == VerifiedRole.signedOut) throw const AuthException('Session is not available.');
      await LoginLockService.clear(email);
      if (!mounted) return;
      if (role == VerifiedRole.administrator) {
        try { await DualSyncService.instance.recordSessionEvent(event: 'admin_login', admin: true); } catch (_) {}
        context.go('/admin');
      } else {
        try {
          await DualSyncService.instance.recordSessionEvent(event: 'homeowner_login', admin: false);
          await AccountBootstrapService.instance.ensureRegistrationPersisted();
        } catch (_) {}
        if (mounted) context.go('/dashboard');
      }
    } on AuthException catch (e) {
      if (!mounted) return;

      if (_isCredentialFailure(e.message)) {
        final updated = await LoginLockService.registerFailure(email);
        if (!mounted) return;
        setState(() {
          _lockStatus = updated;
          _error = updated.isLocked
              ? _lockText(updated)
              : 'Incorrect email or password. ${updated.remainingAttempts} '
                  '${updated.remainingAttempts == 1 ? 'attempt' : 'attempts'} remaining.';
        });
      } else {
        setState(() => _error = _friendly(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Connection error — check your internet and try again.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _oauth(OAuthProvider provider) async {
    if (_locked || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await Supabase.instance.client.auth.signInWithOAuth(
        provider,
        redirectTo: kIsWeb ? Uri.base.origin : 'io.supabase.flutter://callback',
      );
      if (!ok && mounted) {
        setState(() => _error = 'Could not start social sign-in. Please try again.');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = _friendly(e.message));
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not start social sign-in. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgotPassword() async {
    final controller = TextEditingController(text: _emailCt.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card(context),
        title: Text('Reset password',
            style: TextStyle(color: AppTheme.textPrimary(context))),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.emailAddress,
          style: TextStyle(color: AppTheme.textPrimary(context)),
          decoration: const InputDecoration(
            labelText: 'Email address',
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Send reset link'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (email == null || email.isEmpty) return;
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(email, redirectTo: Uri.base.origin + '/reset-password');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password reset link sent. Check your email.'),
          backgroundColor: const Color(0xFF166534),
        ),
      );
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = _friendly(e.message));
    }
  }

  String _friendly(String message) {
    final m = message.toLowerCase();
    if (m.contains('email not confirmed') || m.contains('not confirmed')) {
      return 'Please verify your email first — check your inbox.';
    }
    if (m.contains('rate limit') || m.contains('too many')) {
      return 'Too many requests. Please try again later.';
    }
    if (m.contains('network') || m.contains('connection')) {
      return 'Connection error — check your internet and try again.';
    }
    return message;
  }

  String _lockText(LoginLockStatus status) {
    final left = status.remainingLockTime;
    final minutes = left.inMinutes;
    final seconds = left.inSeconds.remainder(60).clamp(0, 59);
    return 'Sign-in temporarily locked (${status.failedAttempts} wrong attempts). '
        'Try again in ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final txtPri = AppTheme.textPrimary(context);
    final txtSec = AppTheme.textSecondary(context);

    return Scaffold(
      backgroundColor: AppTheme.bg(context),
      body: PhoenixBackdrop(
        child: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                Responsive.horizontalPadding(context),
                16,
                Responsive.horizontalPadding(context),
                32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => context.go('/'),
                          icon: const Icon(Icons.arrow_back_ios_new, size: 14),
                          label: const Text('Back'),
                          style: TextButton.styleFrom(foregroundColor: txtSec),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _BrandHeader(textSecondary: txtSec),
                      const SizedBox(height: 30),
                      GlassPanel(
                        radius: 24,
                        padding: EdgeInsets.all(Responsive.isCompact(context) ? 18 : 24),
                        tint: isDark
                            ? const Color(0xFF161410).withValues(alpha: 0.82)
                            : Colors.white.withValues(alpha: 0.82),
                        borderColor: AppColors.orange.withValues(alpha: 0.14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Welcome Back',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w800,
                                color: txtPri,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Sign in with your PyroGuard account. Homeowners and administrators use the same secure login.',
                              style: TextStyle(color: txtSec, fontSize: 13),
                            ),
                            const SizedBox(height: 20),
                            if (_locked) ...[
                              _MessageBox(
                                text: _lockText(_lockStatus),
                                color: AppColors.red,
                                icon: Icons.timer_outlined,
                              ),
                              const SizedBox(height: 14),
                            ],
                            if (_error != null && !_locked) ...[
                              _MessageBox(
                                text: _error!,
                                color: _locked ? AppColors.red : AppColors.redBright,
                                icon: _locked ? Icons.lock : Icons.error_outline,
                              ),
                              const SizedBox(height: 14),
                            ],
                            if (!_locked && _lockStatus.failedAttempts > 0) ...[
                              _MessageBox(
                                text:
                                    '${_lockStatus.failedAttempts} failed attempts. ${_lockStatus.remainingAttempts} until the next lock threshold (3 first, 10 for 15 minutes).',
                                color: AppColors.amber,
                                icon: Icons.shield_outlined,
                              ),
                              const SizedBox(height: 14),
                            ],
                            Form(
                              key: _formKey,
                              child: Column(
                                children: [
                                  _PyroField(
                                    ctrl: _emailCt,
                                    label: 'Email Address',
                                    hint: 'you@example.com',
                                    icon: Icons.email_outlined,
                                    type: TextInputType.emailAddress,
                                    enabled: !_locked,
                                    validator: (v) {
                                      if (v == null || v.trim().isEmpty) {
                                        return 'Email is required';
                                      }
                                      if (!v.contains('@')) return 'Enter a valid email';
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  _PyroField(
                                    ctrl: _passCt,
                                    label: 'Password',
                                    hint: 'Your password',
                                    icon: Icons.lock_outline,
                                    obscure: _obscure,
                                    enabled: !_locked,
                                    onToggle: () => setState(() => _obscure = !_obscure),
                                    validator: (v) =>
                                        (v == null || v.isEmpty) ? 'Password is required' : null,
                                  ),
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    dense: true,
                                    title: const Text('Remember my email (not password)'),
                                    value: _rememberEmail,
                                    onChanged: (v) => setState(() => _rememberEmail = v ?? false),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: _locked ? null : _forgotPassword,
                                      child: const Text('Forgot Password?'),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  _GradButton(
                                    label: _locked ? 'System Locked' : 'Sign In',
                                    loading: _loading,
                                    disabled: _locked,
                                    icon: _locked ? Icons.lock : Icons.login,
                                    onTap: _login,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(child: Divider(color: AppTheme.border(context))),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: Text('OR', style: TextStyle(color: txtSec, fontSize: 11)),
                                ),
                                Expanded(child: Divider(color: AppTheme.border(context))),
                              ],
                            ),
                            const SizedBox(height: 16),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final stack = constraints.maxWidth < 330;
                                final google = _SocialButton(
                                  label: 'Google',
                                  icon: Icons.account_circle_outlined,
                                  disabled: _locked || _loading,
                                  onTap: () => _oauth(OAuthProvider.google),
                                );
                                final facebook = _SocialButton(
                                  label: 'Facebook',
                                  icon: Icons.facebook,
                                  disabled: _locked || _loading,
                                  onTap: () => _oauth(OAuthProvider.facebook),
                                );
                                if (stack) {
                                  return Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [google, const SizedBox(height: 10), facebook],
                                  );
                                }
                                return Row(
                                  children: [
                                    Expanded(child: google),
                                    const SizedBox(width: 10),
                                    Expanded(child: facebook),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Security: 3 incorrect passwords lock sign-in for 1 minute; 10 cumulative incorrect passwords lock it for 15 minutes on this device.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: txtSec, fontSize: 10.5, height: 1.4),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text("Don't have an account? ",
                              style: TextStyle(color: txtSec, fontSize: 13)),
                          TextButton(
                            onPressed: () => context.go('/signup'),
                            child: const Text(
                              'Create Account',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader({required this.textSecondary});
  final Color textSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          const PyroGuardLogo(),
          const SizedBox(height: 14),
          ShaderMask(
            shaderCallback: (b) => const LinearGradient(
              colors: [AppColors.orange, AppColors.red],
            ).createShader(b),
            child: const Text(
              'PyroGuard',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w900,
                color: Colors.white,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Home Monitoring & Security',
            style: TextStyle(color: textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PyroField extends StatelessWidget {
  const _PyroField({
    required this.ctrl,
    required this.label,
    required this.hint,
    required this.icon,
    this.type,
    this.obscure = false,
    this.enabled = true,
    this.onToggle,
    this.validator,
  });

  final TextEditingController ctrl;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? type;
  final bool obscure;
  final bool enabled;
  final VoidCallback? onToggle;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: ctrl,
      keyboardType: type,
      obscureText: obscure,
      enabled: enabled,
      validator: validator,
      style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 19),
        suffixIcon: onToggle == null
            ? null
            : IconButton(
                onPressed: onToggle,
                icon: Icon(
                  obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 19,
                ),
              ),
      ),
    );
  }
}

class _GradButton extends StatelessWidget {
  const _GradButton({
    required this.label,
    required this.loading,
    required this.disabled,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final bool loading;
  final bool disabled;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final inactive = disabled || loading;
    return Opacity(
      opacity: inactive ? 0.62 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: inactive ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Ink(
            height: 52,
            decoration: BoxDecoration(
              gradient: inactive ? null : GlassStyle.brandGradient,
              color: inactive ? AppTheme.border(context) : null,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 18, color: Colors.white),
                        const SizedBox(width: 8),
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.icon,
    required this.disabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: disabled ? null : onTap,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.textPrimary(context),
        padding: const EdgeInsets.symmetric(vertical: 14),
        side: BorderSide(color: AppTheme.border(context)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({
    required this.text,
    required this.color,
    required this.icon,
  });

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.statusForeground(context, color), size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: AppTheme.statusForeground(context, color), fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
