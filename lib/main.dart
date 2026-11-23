// ignore_for_file: deprecated_member_use

import 'screens/auth/inactivity_monitor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'router.dart';
import 'services/notification_service.dart';
import 'theme.dart';
import 'widgets/biometric_gate.dart';

const String _defaultSupabaseUrl = 'https://gljzunjbmmsbkayxtyfc.supabase.co';
const String _defaultSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdsanp1bmpibW1zYmtheXh0eWZjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTUwNjY1MTgsImV4cCI6MjExMDY0MjUxOH0.PTpkL8ElB23FchzghBXib_V7__hlKBLeKCr844v8kwA';

// Production builds can override these without editing source:
// flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
const String supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: _defaultSupabaseUrl,
);
const String supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: _defaultSupabaseAnonKey,
);

final FlutterLocalNotificationsPlugin notificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Flipped to true only if Supabase.initialize() actually succeeds.
// router.dart checks this before touching Supabase.instance, so a
// failed/blocked init can never throw an unguarded exception that
// freezes the app on the splash screen.
bool supabaseInitialized = false;
Object? supabaseInitError;
GoRouter? appRouter;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Surface ANY uncaught error on screen instead of leaving a blank/
  // splash page with no clue what happened. Check the browser
  // console (F12) too — this repeats the message there as well.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('FlutterError: ${details.exceptionAsString()}');
  };

  // Never let a single startup step take down the whole app before
  // runApp() has a chance to render — on web especially, an uncaught
  // exception here means Flutter never fires its first frame, so the
  // static HTML splash in web/index.html is left showing forever.
  try {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
      ),
      realtimeClientOptions: const RealtimeClientOptions(
        logLevel: RealtimeLogLevel.info,
      ),
    );
    supabaseInitialized = true;
    appRouter = createAppRouter();
  } catch (e) {
    supabaseInitError = e;
    debugPrint('Supabase init failed: $e');
  }

  // flutter_local_notifications has no web implementation — calling
  // it on web throws, and since this ran before runApp(), that
  // exception used to prevent the entire app from ever rendering.
  if (!kIsWeb) {
    try {
      await NotificationService.initialize(notificationsPlugin);
    } catch (e) {
      debugPrint('Notification init failed: $e');
    }
  }

  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint('SharedPreferences init failed: $e');
  }
  final savedDark = prefs?.getBool('dark_mode') ?? false;

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeNotifier(initialDark: savedDark, prefs: prefs),
      child: const PyroGuardApp(),
    ),
  );
}

class PyroGuardApp extends StatelessWidget {
  const PyroGuardApp({super.key});
  @override
  Widget build(BuildContext context) {
    final themeNotifier = context.watch<ThemeNotifier>();

    // If Supabase never came up, don't silently render a dead app —
    // show exactly why, with a retry button, so this is never a
    // mystery blank screen again.
    if (!supabaseInitialized) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        builder: (context, child) => PhoenixBackdrop(child: child ?? const SizedBox.shrink()),
        home: _StartupErrorScreen(error: supabaseInitError),
      );
    }

    return MaterialApp.router(
      title: 'PyroGuard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeNotifier.mode,
      routerConfig: appRouter!,
      builder: (context, child) => PhoenixBackdrop(
        child: InactivityMonitor(
          router: appRouter!,
          // Fingerprint unlock on phones (panel suggestion); no effect on web.
          child: BiometricGate(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.error});
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52, color: AppColors.orange),
              const SizedBox(height: 16),
              const Text('PyroGuard couldn\'t connect to Supabase',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 20),
              const Text(
                'Check your SUPABASE_URL / SUPABASE_ANON_KEY dart-defines (or the defaults in main.dart), your '
                'internet connection, and the browser console (F12) for '
                'the full error.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}