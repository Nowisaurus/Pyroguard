import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'admin_identity.dart';

class AdminService extends ChangeNotifier {
  AdminService._();
  static final AdminService instance = AdminService._();

  bool _loaded = false;
  bool _isAdmin = false;
  bool _isHeadDeveloper = false;
  Map<String, dynamic>? _record;

  bool get loaded => _loaded;
  bool get isAdmin => _isAdmin;
  bool get isHeadDeveloper => _isHeadDeveloper;
  Map<String, dynamic>? get record => _record;

  static bool isFixedAdminEmail(String? email) => AdminIdentity.isFixedAdminEmail(email);

  Future<void> refresh() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _loaded = true;
      _isAdmin = false;
      _isHeadDeveloper = false;
      _record = null;
      notifyListeners();
      return;
    }
    try {
      if (!AdminIdentity.isFixedAdminEmail(user.email)) {
        _record = null;
        _isAdmin = false;
        _isHeadDeveloper = false;
        _loaded = true;
        notifyListeners();
        return;
      }
      Map<String,dynamic>? row;
      try {
        final response = await Supabase.instance.client.functions.invoke('admin-console', body:{'action':'identity'});
        final raw = response.data;
        if (raw is Map && raw['ok'] == true && raw['admin'] is Map) row=Map<String,dynamic>.from(raw['admin'] as Map);
      } catch (_) {
        final legacy = await Supabase.instance.client.from('admin_accounts').select()
          .eq('user_id',user.id).eq('active',true).maybeSingle();
        if (legacy != null) row=Map<String,dynamic>.from(legacy);
      }

debugPrint('Admin registry found: ${row != null}');

if (row != null &&
    row['email']?.toString().trim().toLowerCase() !=
        user.email?.trim().toLowerCase()) {
  throw StateError('Administrator email mismatch');
}
      _record = row == null ? null : Map<String, dynamic>.from(row);
      _isAdmin = _record != null;
      _isHeadDeveloper = (_record?['admin_role'] ?? '').toString() == 'head_developer';
    } catch (e) {
      debugPrint('AdminService.refresh: $e');
      _record = null;
      _isAdmin = false;
      _isHeadDeveloper = false;
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }
}
