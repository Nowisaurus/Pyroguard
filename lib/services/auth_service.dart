import 'registration_service.dart';
import 'password_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'login_lock_service.dart';
import 'dual_sync_service.dart';
import 'account_bootstrap_service.dart';
import 'admin_identity.dart';

/// Consolidated authentication service - single source of truth for all auth operations
/// Handles email/password, OAuth, session management, and error handling
class AuthService extends ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  
  // State management
  bool _isLoading = false;
  String? _error;
  User? _currentUser;
  bool _isAuthenticated = false;

  // Getters
  bool get isLoading => _isLoading;
  String? get error => _error;
  User? get currentUser => _currentUser;
  bool get isAuthenticated => _isAuthenticated;
  SupabaseClient get supabase => _supabase;

  AuthService() {
    _initializeAuth();
  }

  /// Initialize auth state on app startup
  Future<void> _initializeAuth() async {
    try {
      final session = _supabase.auth.currentSession;
      if (session != null) {
        _currentUser = session.user;
        _isAuthenticated = true;
      }
      _supabase.auth.onAuthStateChange.listen((data) {
        _currentUser = data.session?.user;
        _isAuthenticated = data.session != null;
        notifyListeners();
      });
    } catch (e) {
      _error = 'Failed to initialize auth: $e';
      if (kDebugMode) print('Auth init error: $e');
    }
  }

  /// Email/Password Sign Up with profile data
  Future<bool> signUpWithEmail({
    required String email,
    required String password,
    required String fullName,
    required String homeName,
    required String address,
  }) async {
    _setLoading(true);
    _clearError();
    
    try {
      // Validate inputs
      if (!_isValidEmail(email)) throw Exception('Invalid email format');
      final passwordError = PasswordPolicy.validate(password);
      if (passwordError != null) throw Exception(passwordError);
      if (fullName.trim().isEmpty) throw Exception('Full name is required');
      if (homeName.trim().isEmpty) throw Exception('Home name is required');
      if (address.trim().isEmpty) throw Exception('Address is required');

      await RegistrationService.register(email: email, password: password, metadata: {
        'full_name': fullName.trim(), 'home_name': homeName.trim(),
        'address': address.trim(), 'onboarding_completed': false,
      });
      _currentUser = _supabase.auth.currentUser;
      _isAuthenticated = _supabase.auth.currentSession != null;
      if (_isAuthenticated) {
        await AccountBootstrapService.instance.ensureRegistrationPersisted(force: true);
      }
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _error = _formatAuthError(e.message);
      if (kDebugMode) print('SignUp error: ${e.message}');
      return false;
    } catch (e) {
      _error = _formatError(e.toString());
      if (kDebugMode) print('SignUp error: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Email/Password Sign In. This mirrors the LoginScreen three-strike lock
  /// so future callers cannot accidentally bypass the same protection.
  Future<bool> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _setLoading(true);
    _clearError();
    final normalizedEmail = email.trim();

    try {
      if (!_isValidEmail(normalizedEmail)) throw Exception('Invalid email format');
      if (password.isEmpty) throw Exception('Password is required');

      final lock = await LoginLockService.statusFor(normalizedEmail);
      if (lock.isLocked) {
        final minutes = lock.remainingLockTime.inMinutes;
        final seconds = lock.remainingLockTime.inSeconds.remainder(60);
        _error = 'Login locked after ${lock.failedAttempts} failed attempts. '
            'Try again in ${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.';
        return false;
      }

      final response = await _supabase.auth.signInWithPassword(
        email: normalizedEmail,
        password: password,
      );

      if (response.session != null && response.user != null) {
        await LoginLockService.clear(normalizedEmail);
        _currentUser = response.user;
        _isAuthenticated = true;
        final isAdmin = AdminIdentity.isFixedAdminEmail(response.user!.email) &&
            AdminIdentity.userMetadataMarksAdmin(response.user!.appMetadata);
        await DualSyncService.instance.recordSessionEvent(
          event: isAdmin ? 'admin_login' : 'homeowner_login',
          admin: isAdmin,
        );
        if (!isAdmin) {
          await AccountBootstrapService.instance.ensureRegistrationPersisted();
        }
        notifyListeners();
        return true;
      }
      throw AuthException('Invalid login credentials');
    } on AuthException catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('invalid') || msg.contains('credentials') || msg.contains('wrong')) {
        final lock = await LoginLockService.registerFailure(normalizedEmail);
        _error = lock.isLocked
            ? 'Login locked after ${lock.failedAttempts} failed attempts for ${lock.extendedLock ? 15 : 1} minute(s).'
            : 'Incorrect email or password. ${lock.remainingAttempts} attempts remaining.';
      } else {
        _error = _formatAuthError(e.message);
      }
      if (kDebugMode) print('SignIn error: ${e.message}');
      return false;
    } catch (e) {
      _error = _formatError(e.toString());
      if (kDebugMode) print('SignIn error: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Sign In with Google OAuth
  Future<bool> signInWithGoogle() async {
    _setLoading(true);
    _clearError();

    try {
      final response = await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: kIsWeb ? Uri.base.origin : 'io.supabase.flutter://callback',
      );

      if (response == true) {
        _isAuthenticated = true;
        notifyListeners();
        return true;
      }
      throw Exception('Google sign in failed');
    } on AuthException catch (e) {
      _error = _formatAuthError(e.message);
      if (kDebugMode) print('Google SignIn error: ${e.message}');
      return false;
    } catch (e) {
      _error = _formatError(e.toString());
      if (kDebugMode) print('Google SignIn error: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Sign In with Facebook OAuth
  Future<bool> signInWithFacebook() async {
    _setLoading(true);
    _clearError();

    try {
      final response = await _supabase.auth.signInWithOAuth(
        OAuthProvider.facebook,
        redirectTo: kIsWeb ? Uri.base.origin : 'io.supabase.flutter://callback',
      );

      if (response == true) {
        _isAuthenticated = true;
        notifyListeners();
        return true;
      }
      throw Exception('Facebook sign in failed');
    } on AuthException catch (e) {
      _error = _formatAuthError(e.message);
      if (kDebugMode) print('Facebook SignIn error: ${e.message}');
      return false;
    } catch (e) {
      _error = _formatError(e.toString());
      if (kDebugMode) print('Facebook SignIn error: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Password Reset
  Future<bool> resetPassword(String email) async {
    _setLoading(true);
    _clearError();

    try {
      if (!_isValidEmail(email)) throw Exception('Invalid email format');

      await _supabase.auth.resetPasswordForEmail(email.trim(), redirectTo: kIsWeb ? '${Uri.base.origin}/reset-password' : 'io.supabase.flutter://reset-password');
      _error = 'Password reset email sent. Check your inbox.';
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _error = _formatAuthError(e.message);
      if (kDebugMode) print('Password reset error: ${e.message}');
      return false;
    } catch (e) {
      _error = _formatError(e.toString());
      if (kDebugMode) print('Password reset error: $e');
      return false;
    } finally {
      _setLoading(false);
    }
  }

  /// Sign Out
  Future<void> signOut() async {
    _setLoading(true);
    try {
      final user = _supabase.auth.currentUser;
      if (user != null) {
        final isAdmin = AdminIdentity.isFixedAdminEmail(user.email) &&
            AdminIdentity.userMetadataMarksAdmin(user.appMetadata);
        try {
          await DualSyncService.instance.recordSessionEvent(
            event: isAdmin ? 'admin_logout' : 'homeowner_logout',
            admin: isAdmin,
          );
        } catch (_) {}
      }
      await _supabase.auth.signOut();
      _currentUser = null;
      _isAuthenticated = false;
      _clearError();
      notifyListeners();
    } catch (e) {
      _error = 'Sign out failed: $e';
      if (kDebugMode) print('SignOut error: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ============ HELPER METHODS ============

  /// Format Supabase auth errors to user-friendly messages
  String _formatAuthError(String message) {
    final lowerMsg = message.toLowerCase();

    if (lowerMsg.contains('invalid') || lowerMsg.contains('credentials')) {
      return 'Incorrect email or password. Please try again.';
    }
    if (lowerMsg.contains('email not confirmed') || lowerMsg.contains('not confirmed')) {
      return 'Please verify your email first — check your inbox.';
    }
    if (lowerMsg.contains('rate limit') || lowerMsg.contains('too many')) {
      return 'Too many attempts — please wait a few minutes.';
    }
    if (lowerMsg.contains('user not found')) {
      return 'No account found with that email.';
    }
    if (lowerMsg.contains('already registered')) {
      return 'This email is already registered. Please sign in instead.';
    }
    if (lowerMsg.contains('password')) {
      return 'New passwords require 12+ characters, uppercase, lowercase, number and symbol, without spaces.';
    }
    if (lowerMsg.contains('network') || lowerMsg.contains('connection')) {
      return 'Connection error — check your internet and try again.';
    }

    return message;
  }

  /// Format generic errors
  String _formatError(String error) {
    if (error.contains('Connection failed')) {
      return 'No internet connection — please check and try again.';
    }
    if (error.contains('TimeoutException')) {
      return 'Request timed out — please try again.';
    }
    if (error.contains('OAuth')) {
      return 'Social login failed — please try again.';
    }
    return 'Something went wrong — please try again.';
  }

  /// Validate email format
  bool _isValidEmail(String email) {
    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    return emailRegex.hasMatch(email.trim());
  }

  /// Set loading state
  void _setLoading(bool value) {
    _isLoading = value;
    notifyListeners();
  }

  /// Clear error
  void _clearError() {
    _error = null;
  }
}
