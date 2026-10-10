import 'package:supabase_flutter/supabase_flutter.dart';

/// Wait for the server's Auth + MySQL registration result, including when
/// email confirmation means there is no client session yet.
class RegistrationService {
  static Future<Map<String, dynamic>> register({required String email,
    required String password, required Map<String, dynamic> metadata}) async {
    final db = Supabase.instance.client;
    late FunctionResponse response;
    try {
    response = await db.functions.invoke('register-account', body: {
      'email': email.trim(), 'password': password, 'metadata': metadata,
    });
    } on FunctionException catch (e) {
      final details = e.details;
      throw AuthException(details is Map
        ? details['error']?.toString() ?? 'Registration server is unavailable.'
        : 'Registration server is unavailable. Please try again.');
    }
    final raw = response.data;
    if (raw is! Map) throw StateError('Unexpected registration response.');
    final result = Map<String, dynamic>.from(raw);
    if (result['ok'] != true) throw AuthException(result['error']?.toString() ?? 'Registration could not complete.');
    final session = result['session'];
    if (session is Map && session['refresh_token'] is String) {
      await db.auth.setSession(session['refresh_token'] as String);
    }
    return result;
  }
}
