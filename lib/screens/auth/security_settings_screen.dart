import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/password_policy.dart';

class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});
  @override State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}
class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final _code = TextEditingController(); final _newPass = TextEditingController();
  final _confirm = TextEditingController();
  String? _factorId; String? _qr; String? _message; bool _busy = false;
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
