import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/mfa_service.dart';

/// Challenge is verified by Supabase; a locally entered code cannot unlock a role.
class MfaScreen extends StatefulWidget {
  const MfaScreen({super.key});
  @override
  State<MfaScreen> createState() => _MfaScreenState();
}
class _MfaScreenState extends State<MfaScreen> {
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;
  String? _factorId;
  String? _challengeId;
  @override
  void initState() { super.initState(); _begin(); }
  @override
  void dispose() { _code.dispose(); super.dispose(); }
  Future<void> _begin() async {
    setState(() { _busy = true; _error = null; });
    try {
      final auth = Supabase.instance.client.auth;
      final factors = await auth.mfa.listFactors();
      final verified = factors.totp.where((f) => f.status.toString().toLowerCase().contains('verified')).toList();
      if (verified.isEmpty) throw StateError('No verified authenticator configured. Contact your administrator.');
      final id = verified.first.id;
      final challenge = await auth.mfa.challenge(factorId: id);
      _factorId = id;
      _challengeId = challenge.id;
    } catch (e) { _error = 'Authenticator challenge unavailable: $e'; }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _verify() async {
    if (_busy || _factorId == null || _challengeId == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      await Supabase.instance.client.auth.mfa.verify(
        factorId: _factorId!, challengeId: _challengeId!, code: _code.text.trim());
      if (await MfaService.needsVerification()) throw StateError('Second factor was not accepted.');
      if (mounted) context.go('/login'); // router verifies role and chooses destination
    } catch (e) { _error = 'Verification failed: $e'; }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Two-factor verification')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.phonelink_lock, size: 56),
        const SizedBox(height: 12),
        const Text('Enter the six-digit code from your authenticator app.'),
        TextField(controller: _code, keyboardType: TextInputType.number,
          maxLength: 6, decoration: const InputDecoration(labelText: 'Authenticator code')),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        FilledButton(onPressed: _busy ? null : _verify, child: const Text('Verify code')),
        TextButton(onPressed: _busy ? null : _begin, child: const Text('Try another code')),
        TextButton(onPressed: () async { await Supabase.instance.client.auth.signOut(); if (context.mounted) context.go('/login'); },
          child: const Text('Sign out')),
      ])))),
  );
}
