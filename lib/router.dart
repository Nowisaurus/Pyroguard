import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/onboarding/splash_screen.dart';
import 'screens/onboarding/onboarding_screen.dart';
import 'screens/onboarding/post_signup_tutorial.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/auth/password_recovery_screen.dart';
import 'screens/dashboard/main_shell.dart';
import 'screens/camera/evidence_gallery.dart';
import 'screens/admin/admin_screen.dart';
import 'services/admin_identity.dart';
import 'services/admin_service.dart';
import 'services/verified_role_service.dart';
import 'services/mfa_service.dart';
import 'screens/auth/mfa_screen.dart';
import 'screens/auth/security_settings_screen.dart';

GoRouter createAppRouter() => GoRouter(
  initialLocation: '/splash',
  refreshListenable: _AuthChangeNotifier(
    Supabase.instance.client.auth.onAuthStateChange,
  ),
  redirect: (context, state) async {

    final session = Supabase.instance.client.auth.currentSession;
    final loggedIn = session != null;
    final location = state.matchedLocation;
    final isPublic = location == '/' ||
        location == '/login' ||
        location == '/signup' ||
        location == '/splash' || location == '/reset-password';

    if (!loggedIn) {
      if (location == '/tutorial' || location == '/admin' || !isPublic) {
        return '/login';
      }
      return null;
    }

    if (location == '/reset-password' && Supabase.instance.client.auth.currentSession?.user == null) return null;
    if (location != '/reset-password') {
      final needsMfa = await MfaService.needsVerification();
      if (needsMfa) return location == '/mfa' ? null : '/mfa';
      if (location == '/mfa') return '/login';
    }
    if (location == '/reset-password') return null;
    final role = await VerifiedRoleService.resolve();
    if (role == VerifiedRole.denied) {
      return location == '/access-denied' ? null : '/access-denied';
    }
    if (role == VerifiedRole.administrator) {
      return location == '/admin' ? null : '/admin';
    }
    if (role != VerifiedRole.homeowner) return '/login';
    if (location == '/admin') return '/access-denied';
    final onboardingCompleted = session.user.userMetadata?['onboarding_completed'] == true;
    if (!onboardingCompleted && location != '/tutorial') return '/tutorial';
    if (location == '/access-denied') return null;
    if (isPublic) return '/dashboard';
    return null;
  },
  routes: [
    GoRoute(path: '/splash', builder: (_, __) => const SplashScreen()),
    GoRoute(path: '/', builder: (_, __) => const OnboardingScreen()),
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    GoRoute(path: '/signup', builder: (_, __) => const SignupScreen()),
    GoRoute(path: '/security', builder: (_, __) => const SecuritySettingsScreen()),
    GoRoute(path: '/mfa', builder: (_, __) => const MfaScreen()),
    GoRoute(path: '/reset-password', builder: (_, __) => const PasswordRecoveryScreen()),
    GoRoute(path: '/access-denied', builder: (_, __) => const Scaffold(
      body: Center(child: Text('Account role could not be verified. Contact your administrator.')),
    )),
    GoRoute(path: '/admin', builder: (_, __) => const AdminConsoleScreen()),
    GoRoute(path: '/tutorial', builder: (_, __) => const PostSignupTutorialScreen()),
    ShellRoute(
      builder: (ctx, state, child) => MainShell(child: child),
      routes: [
        _tab('/dashboard', (_, __) => const DashboardTab()),
        _tab('/camera', (_, __) => const CameraTab()),
        _tab('/evidence', (_, __) => const EvidenceGalleryTab()),
        _tab('/incidents', (_, __) => const IncidentsTab()),
        _tab('/analytics', (_, __) => const AnalyticsTab()),
        _tab('/device', (_, __) => const DeviceTab()),
        _tab('/map', (_, __) => const MapTab()),
        _tab('/calendar', (_, __) => const CalendarTab()),
        _tab('/settings', (_, __) => const SettingsTab()),

      ],
    ),
  ],
);

GoRoute _tab(String path, Widget Function(BuildContext, GoRouterState) build) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => CustomTransitionPage(
      key: state.pageKey,
      child: build(context, state),
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOut);
        return FadeTransition(
          opacity: curved,
          child: Transform.translate(
            offset: Offset(0, (1 - curved.value) * 12),
            child: child,
          ),
        );
      },
    ),
  );
}

class _AuthChangeNotifier extends ChangeNotifier {
  _AuthChangeNotifier(Stream<dynamic> stream) {
    notifyListeners();
    _sub = stream.listen((_) => notifyListeners());
  }

  late final dynamic _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
