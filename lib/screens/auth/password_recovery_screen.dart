import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/password_policy.dart';

class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({super.key});
  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}
class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  final password = TextEditingController();
  final confirmation = TextEditingController();
  String? message;
  bool busy = false;
  @override
  void dispose() { password.dispose(); confirmation.dispose(); super.dispose(); }
  Future<void> save() async {
    final error = PasswordPolicy.validate(password.text);
    if (error != null || password.text != confirmation.text) {
      setState(() => message = error ?? 'Passwords do not match.'); return;
    }
    if (Supabase.instance.client.auth.currentSession == null) {
      setState(() => message = 'Open the newest password recovery link from your email first.'); return;
    }
    setState(() => busy = true);
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: password.text));
      if (!mounted) return;
      setState(() => message = 'Password updated. Sign in with your new password.');
      await Supabase.instance.client.auth.signOut();
    } on AuthException catch (e) {
      if (mounted) setState(() => message = e.message);
    } finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reset password')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Padding(
      padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Choose a new password: 12+ characters, uppercase, lowercase, number and symbol; no spaces.'),
        TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
        TextField(controller: confirmation, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
        if (message != null) Text(message!),
        ElevatedButton(onPressed: busy ? null : save, child: const Text('Update password')),
        TextButton(onPressed: () => context.go('/login'), child: const Text('Back to sign in')),
      ]),
    ))),
  );
}
