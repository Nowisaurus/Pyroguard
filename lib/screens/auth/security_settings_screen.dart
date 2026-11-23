import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/password_policy.dart';
import '../../services/biometric_lock_service.dart';

class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});
  @override State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}
class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final _code = TextEditingController(); final _newPass = TextEditingController();
  final _confirm = TextEditingController();
  String? _factorId; String? _qr; String? _message; bool _busy = false;
  bool _bioSupported = false; bool _bioEnabled = false;
  @override void initState() { super.initState(); _loadBio(); }
  Future<void> _loadBio() async {
    final bio = BiometricLockService.instance;
    final supported = await bio.isSupported();
    final enabled = await bio.isEnabled();
    if (mounted) setState(() { _bioSupported = supported; _bioEnabled = enabled; });
  }
  Future<void> _toggleBio(bool on) async {
    final bio = BiometricLockService.instance;
    String? password;
    if (on) {
      // The password is checked once and kept encrypted on this phone, so the
      // fingerprint can sign in even after a wrong password or a sign-out.
      final ct = TextEditingController();
      password = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm your password'),
          content: TextField(controller: ct, obscureText: true, autofocus: true,
              decoration: const InputDecoration(labelText: 'Current password')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ct.text), child: const Text('Continue')),
          ],
        ),
      );
      if (password == null || password.isEmpty) return;
      final email = Supabase.instance.client.auth.currentUser?.email;
      if (email == null) return;
      setState(() => _busy = true);
      try {
        await Supabase.instance.client.auth.signInWithPassword(email: email, password: password);
      } catch (_) {
        setState(() { _busy = false; _message = 'Wrong password; fingerprint sign-in was not turned on.'; });
        return;
      }
      setState(() => _busy = false);
    }
    // Confirm the fingerprint once before turning it on or off.
    if (!await bio.authenticate(reason: on ? 'Confirm your fingerprint to turn on fingerprint sign-in' : 'Confirm to turn off fingerprint sign-in')) {
      setState(() => _message = 'Fingerprint not confirmed; setting unchanged.'); return;
    }
    await bio.setEnabled(on);
    if (on) {
      await bio.saveLogin(Supabase.instance.client.auth.currentUser!.email!, password!);
    }
    setState(() { _bioEnabled = on; _message = on
        ? 'Fingerprint is ON: it unlocks the app and can sign you in on the login page.'
        : 'Fingerprint sign-in is OFF.'; });
  }
  @override void dispose() { _code.dispose(); _newPass.dispose(); _confirm.dispose(); super.dispose(); }
  Future<void> _enroll() async {
    setState(() { _busy = true; _message = null; });
    try {
      final r = await Supabase.instance.client.auth.mfa.enroll(factorType: FactorType.totp,
        friendlyName: 'PyroGuard authenticator');
      setState(() { _factorId = r.id; _qr = r.totp?.uri;
        _message = 'Add the URI below to an authenticator application, then verify its code.'; });
    } catch(e) { setState(() => _message = '$e'); }
    finally { if(mounted) setState(() => _busy = false); }
  }
  Future<void> _activate() async {
    setState(() { _busy = true; _message = null; });
    try {
      final auth = Supabase.instance.client.auth;
      final c = await auth.mfa.challenge(factorId: _factorId!);
      await auth.mfa.verify(factorId: _factorId!, challengeId: c.id, code: _code.text.trim());
      setState(() { _factorId = null; _qr = null; _message = 'Authenticator enabled.'; });
    } catch(e) { setState(() => _message = '$e'); }
    finally { if(mounted) setState(() => _busy = false); }
  }
  Future<void> _changePassword() async {
    final reason = PasswordPolicy.validate(_newPass.text);
    if(reason != null || _newPass.text != _confirm.text) {
      setState(() => _message = reason ?? 'Passwords do not match.'); return;
    }
    setState(() { _busy = true; _message = null; });
    try { await Supabase.instance.client.auth.updateUser(UserAttributes(password: _newPass.text));
      _newPass.clear(); _confirm.clear(); setState(() => _message = 'Password changed.');
    } catch(e) { setState(() => _message = '$e'); }
    finally { if(mounted) setState(() => _busy = false); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account security')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 500),
      child: ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Fingerprint unlock (this phone)', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _bioEnabled,
          onChanged: !_bioSupported || _busy ? null : _toggleBio,
          title: const Text('Fingerprint unlock and sign-in'),
          subtitle: Text(_bioSupported
              ? 'Unlocks the app, and signs you in from the login page even after a wrong password. Alarms keep working.'
              : 'Available in the Android/iOS app on phones with a fingerprint or face unlock set up.'),
        ),
        const Divider(height: 36),
        const Text('Authenticator app (TOTP)', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        FilledButton(onPressed: _busy ? null : _enroll, child: const Text('Set up authenticator')),
        if(_qr != null) ...[SelectableText(_qr!), TextField(controller: _code,
          decoration: const InputDecoration(labelText: '6-digit authenticator code')),
          FilledButton(onPressed: _busy ? null : _activate, child: const Text('Activate MFA'))],
        const Divider(height: 36),
        const Text('Change password', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
        TextField(controller: _newPass, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
        TextField(controller: _confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
        FilledButton(onPressed: _busy ? null : _changePassword, child: const Text('Change password')),
        if(_message != null) Padding(padding: const EdgeInsets.all(12), child: Text(_message!)),
      ]))),
  );
}
