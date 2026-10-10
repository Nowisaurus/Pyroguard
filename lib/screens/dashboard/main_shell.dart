import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import '../../services/sensor_service.dart';
import '../../services/device_service.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/notification_service.dart';
import '../../services/account_bootstrap_service.dart';
import '../../services/security_control_service.dart';
import '../../services/admin_service.dart';
import '../../services/admin_identity.dart';
import '../../services/historical_service.dart';
import '../../services/settings_service.dart';
import '../../services/dual_sync_service.dart';
import '../../theme.dart';

export 'dashboard_home.dart' show DashboardTab;
export '../camera/camera_screen.dart' show CameraTab;
export '../incidents/incidents_screen.dart' show IncidentsTab;
export 'analytics_screen.dart' show AnalyticsTab;
export 'device_screen.dart' show DeviceTab;
export '../map/map_screen.dart' show MapTab;
export '../calendar/calendar_screen.dart' show CalendarTab;
export '../settings/settings_screen.dart' show SettingsTab;

typedef PyroNavigationItem = ({String path, IconData icon, IconData activeIcon, String label});
typedef PyroBottomItem = ({String path, IconData icon, IconData active, String label});

const _navItems = [
  (path: '/dashboard', icon: Icons.dashboard_outlined,       activeIcon: Icons.dashboard,       label: 'Dashboard'),
  (path: '/camera',    icon: Icons.videocam_outlined,        activeIcon: Icons.videocam,        label: 'Camera'),
  (path: '/analytics', icon: Icons.monitor_heart_outlined,   activeIcon: Icons.monitor_heart,   label: 'Monitoring'),
  (path: '/incidents', icon: Icons.warning_amber_outlined,   activeIcon: Icons.warning_amber,   label: 'Events'),
  (path: '/calendar',  icon: Icons.calendar_month_outlined,  activeIcon: Icons.calendar_month,  label: 'Calendar'),
  (path: '/map',       icon: Icons.map_outlined,             activeIcon: Icons.map,             label: 'Map'),
  (path: '/device',    icon: Icons.developer_board_outlined, activeIcon: Icons.developer_board, label: 'Device'),
  (path: '/settings',  icon: Icons.settings_outlined,        activeIcon: Icons.settings,        label: 'Settings'),
  (path: '/admin',     icon: Icons.admin_panel_settings_outlined, activeIcon: Icons.admin_panel_settings, label: 'Admin'),
];

/// Breakpoint above which the persistent desktop sidebar replaces the
/// mobile hamburger + drawer.
const double kDesktopBreakpoint = 980;

/// Used by nested page app bars to open the shell drawer on phones/tablets.
final GlobalKey<ScaffoldState> pyroShellScaffoldKey = GlobalKey<ScaffoldState>();

class MainShell extends StatefulWidget {
  final Widget child;
  const MainShell({super.key, required this.child});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  String? _lastWarningNoticeId;
  bool _remoteThemeApplied = false;
  Timer? _dualSyncRetryTimer;

  bool get _adminIdentity {
    final user = Supabase.instance.client.auth.currentUser;
    return user != null &&
        AdminIdentity.isFixedAdminEmail(user.email) &&
        AdminIdentity.userMetadataMarksAdmin(user.appMetadata);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AdminService.instance.addListener(_onAdminChanged);
    AdminService.instance.refresh();
    HistoricalService.instance.retryPendingSync();
    _dualSyncRetryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => HistoricalService.instance.retryPendingSync(),
    );

    // Fixed administrators are intentionally isolated from homeowner sensor,
    // camera and property services. They only receive the admin console.
    if (!_adminIdentity) {
      SensorService.instance.startListening();
      DeviceService.instance.startListening();
      CameraTelemetryService.instance.startListening();
      SecurityControlService.instance.startListening();
      AccountBootstrapService.instance.ensureRegistrationPersisted();
      NotificationService.loadBfpContact();
      SensorService.instance.addListener(_onSensor);
    }
  }


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      HistoricalService.instance.retryPendingSync();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_adminIdentity && !_remoteThemeApplied) {
      _remoteThemeApplied = true;
      _applySavedTheme();
    }
  }

  Future<void> _applySavedTheme() async {
    try {
      final all = await SettingsService.instance.loadAll();
      final prefs = all['preferences'];
      if (!mounted || prefs is! Map) return;
      final value = prefs['dark_mode'];
      if (value is bool) context.read<ThemeNotifier>().setDark(value);
    } catch (_) {
      // Local SharedPreferences remains the fallback if backend settings are unavailable.
    }
  }

  @override
  void dispose() {
    _dualSyncRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (!_adminIdentity) {
      SensorService.instance.removeListener(_onSensor);
      SensorService.instance.stopListening();
      DeviceService.instance.stopListening();
      CameraTelemetryService.instance.stopListening();
    }
    AdminService.instance.removeListener(_onAdminChanged);
    super.dispose();
  }

  void _onAdminChanged() { if (mounted) setState(() {}); }

  void _onSensor() {
    final r = SensorService.instance.latest;
    if (r == null || !mounted) return;
    if (r.isWarning && !SensorService.instance.alarmActive && r.id != _lastWarningNoticeId) {
      _lastWarningNoticeId = r.id;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF92400E),
        duration: const Duration(seconds: 7),
        content: Row(children: [
          const Icon(Icons.warning_amber, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(child: Text(
            '${r.incidentType} detected — ${r.smokeLevel.toStringAsFixed(0)}% smoke. Warning recorded.',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          )),
        ]),
        action: SnackBarAction(label: 'Dismiss', textColor: Colors.white,
            onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar()),
      ));
    }
    setState(() {});
  }

  void _go(String path) {
    context.go(path);
  }

  Future<void> _logout() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      try {
        await DualSyncService.instance.recordSessionEvent(
          event: _adminIdentity ? 'admin_logout' : 'homeowner_logout',
          admin: _adminIdentity,
        );
      } catch (_) {}
    }
    await Supabase.instance.client.auth.signOut();
    if (mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = _adminIdentity;
    final alarm  = isAdmin ? false : SensorService.instance.alarmActive;
    final user   = Supabase.instance.client.auth.currentUser;
    final name   = user?.userMetadata?['full_name'] as String? ?? 'User';
    final email  = user?.email ?? '';

    return LayoutBuilder(builder: (context, constraints) {
      final isDesktop = constraints.maxWidth >= kDesktopBreakpoint;
      final currentPath = GoRouterState.of(context).matchedLocation;

      return Scaffold(
        key: pyroShellScaffoldKey,
        backgroundColor: Colors.transparent,
        endDrawer: isDesktop ? null : PyroMobileDrawer(
          path: currentPath, name: name, email: email,
          onNav: _go, onLogout: _logout,
        ),
        bottomNavigationBar: isDesktop || isAdmin
            ? null
            : PyroMobileBottomNav(path: currentPath, onNav: _go),
        body: AmbientBackdrop(
          child: Row(children: [
            if (isDesktop)
              PyroDesktopSidebar(path: currentPath, name: name, email: email, onNav: _go, onLogout: _logout),
            Expanded(
              child: Stack(children: [
                widget.child,
                if (alarm)
                  _FireOverlay(onReset: () {
                    SensorService.instance.manualResetAlarm();
                    setState(() {});
                  }),
              ]),
            ),
          ]),
        ),
      );
    });
  }
}

// ── Mobile bottom navigation ────────────────────────────────────────────
class PyroMobileBottomNav extends StatelessWidget {
  const PyroMobileBottomNav({required this.path, required this.onNav, this.customItems});

  final List<PyroBottomItem>? customItems;
  final String path;
  final void Function(String) onNav;

  static const items = [
    (path: '/dashboard', icon: Icons.home_outlined, active: Icons.home, label: 'Home'),
    (path: '/camera', icon: Icons.videocam_outlined, active: Icons.videocam, label: 'Camera'),
    (path: '/device', icon: Icons.shield_outlined, active: Icons.shield, label: 'Controls'),
    (path: '/incidents', icon: Icons.history_outlined, active: Icons.history, label: 'Activity'),
    (path: '/settings', icon: Icons.settings_outlined, active: Icons.settings, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final navigationItems = customItems ?? items;
    var index = navigationItems.indexWhere((item) => item.path == path);
    // Secondary pages such as analytics/map/calendar remain available in the
    // drawer; keep Home highlighted only when no primary destination matches.
    if (index < 0) index = 0;

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        decoration: BoxDecoration(
          color: AppTheme.card(context).withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.border(context)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: NavigationBar(
          height: 66,
          selectedIndex: index,
          backgroundColor: Colors.transparent,
          indicatorColor: AppColors.orange.withValues(alpha: 0.16),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => onNav(navigationItems[i].path),
          destinations: [
            for (final item in navigationItems)
              NavigationDestination(
                icon: Icon(item.icon, size: 21),
                selectedIcon: Icon(item.active, color: AppTheme.brandForeground(context), size: 21),
                label: item.label,
              ),
          ],
        ),
      ),
    );
  }
}

// ── Branded footer block: logo · PyroGuard · tagline · developer ───────
class _BrandFooter extends StatelessWidget {
  final bool compact;
  final bool inverse;
  const _BrandFooter({this.compact = false, this.inverse = false});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const PyroGuardLogo(),
        const SizedBox(width: 9),
        Text('PyroGuard', style: TextStyle(color: inverse ? Colors.white : AppTheme.textPrimary(context), fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 0.2)),
      ]),
      const SizedBox(height: 3),
      Text('Home Monitoring & Security', style: TextStyle(color: inverse ? Colors.white70 : AppTheme.textSecondary(context), fontSize: 10.5, fontWeight: FontWeight.w500)),
      const SizedBox(height: 6),
      Text('Developed by Group 5', style: TextStyle(color: inverse ? Colors.white54 : AppTheme.textSecondary(context).withValues(alpha: .78), fontSize: 9.5)),
    ]);
  }
}

// ── Desktop persistent sidebar ──────────────────────────────────────────
class PyroDesktopSidebar extends StatelessWidget {
  final List<PyroNavigationItem>? items;
  final bool adminWorkspace;
  final String path;
  final String name;
  final String email;
  final void Function(String) onNav;
  final Future<void> Function() onLogout;

  const PyroDesktopSidebar({
    required this.path, required this.name, required this.email,
    required this.onNav, required this.onLogout,
    this.items, this.adminWorkspace = false,
  });

  @override
  Widget build(BuildContext context) {
    final systemOnline = Supabase.instance.client.auth.currentSession != null;
    final hardwareOnline = !adminWorkspace && DeviceService.instance.online && SensorService.instance.realtimeHeartbeat != HeartbeatState.offline;
    final systemColor = systemOnline ? AppColors.green : AppColors.redBright;
    return Container(
      width: 258,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: AppTheme.isDark(context)
            ? AppColors.darkSurface.withValues(alpha: .82)
            : AppColors.maroon.withValues(alpha: .94),
        border: Border(right: BorderSide(color: Colors.white.withValues(alpha: 0.07))),
      ),
      child: Column(children: [
        // Client profile + system-online status, same line
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.orange.withValues(alpha: 0.18),
              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(color: AppColors.orange, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
                Row(children: [
                  Container(width: 6, height: 6, decoration: BoxDecoration(color: systemColor, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(systemOnline ? 'SYSTEM ONLINE' : 'SYSTEM OFFLINE', style: TextStyle(color: systemColor, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.3)),
                ]),
                const SizedBox(height: 2),
                Text(
                  adminWorkspace ? 'ADMINISTRATOR WORKSPACE' : hardwareOnline ? 'HARDWARE CONNECTED' : 'HARDWARE NOT CONNECTED',
                  style: TextStyle(
                    color: hardwareOnline ? AppColors.green : AppColors.amber,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .25,
                  ),
                ),
              ]),
            ),
          ]),
        ),

        const SizedBox(height: 20),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
        const SizedBox(height: 12),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            children: (items ?? _navItems.where((item) => AdminIdentity.isFixedAdminEmail(email) ? item.path == '/admin' : item.path != '/admin').toList()).map((item) {
              final active = path == item.path;
              return Container(
                margin: const EdgeInsets.only(bottom: 3),
                decoration: BoxDecoration(
                  gradient: active ? GlassStyle.brandGradient : null,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(11),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(11),
                    onTap: () => onNav(item.path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                      child: Row(children: [
                        Icon(active ? item.activeIcon : item.icon,
                            color: active ? Colors.white : AppColors.textSecondary, size: 19),
                        const SizedBox(width: 12),
                        Text(item.label, style: TextStyle(
                            color: active ? Colors.white : AppColors.textPrimary,
                            fontWeight: active ? FontWeight.w800 : FontWeight.w500, fontSize: 13.5)),
                      ]),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: onLogout,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                child: Row(children: [
                  Icon(Icons.logout_rounded, color: AppColors.redBright, size: 19),
                  SizedBox(width: 12),
                  Text('Sign Out', style: TextStyle(color: AppColors.redBright, fontWeight: FontWeight.w700, fontSize: 13.5)),
                ]),
              ),
            ),
          ),
        ),

        const SizedBox(height: 16),
        Divider(height: 1, color: Colors.white.withValues(alpha: 0.07)),
        const SizedBox(height: 14),
        const _BrandFooter(inverse: true),
      ]),
    );
  }
}

// ── Mobile drawer ───────────────────────────────────────────────────────
class PyroMobileDrawer extends StatelessWidget {
  final List<PyroNavigationItem>? items;
  final bool adminWorkspace;
  final String path, name, email;
  final void Function(String) onNav;
  final Future<void> Function() onLogout;

  const PyroMobileDrawer({
    required this.path, required this.name, required this.email,
    required this.onNav, required this.onLogout,
    this.items, this.adminWorkspace = false,
  });

  @override
  Widget build(BuildContext context) {
    final systemOnline = Supabase.instance.client.auth.currentSession != null;
    final hardwareOnline = !adminWorkspace && DeviceService.instance.online && SensorService.instance.realtimeHeartbeat != HeartbeatState.offline;
    final systemColor = systemOnline ? AppColors.green : AppColors.redBright;
    return Drawer(
      backgroundColor: AppTheme.surface(context),
      child: SafeArea(
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
            decoration: const BoxDecoration(gradient: GlassStyle.brandGradient),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const PyroGuardLogo(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Text('PyroGuard', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
                      const Spacer(),
                      Container(width: 7, height: 7, margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(color: systemColor, shape: BoxShape.circle)),
                      Text(systemOnline ? 'ONLINE' : 'OFFLINE', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                    ]),
                    Text('Home Monitoring & Security', style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 10.5)),
                  ]),
                ),
              ]),
              const SizedBox(height: 14),
              Text(name,  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700)),
              Text(email, style: const TextStyle(color: Colors.white70, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Row(children: [
                Icon(hardwareOnline ? Icons.sensors : Icons.sensors_off_outlined, color: hardwareOnline ? AppColors.green : AppColors.amber, size: 14),
                const SizedBox(width: 5),
                Text(adminWorkspace ? 'Administrator workspace' : hardwareOnline ? 'Hardware connected' : 'Hardware not connected · waiting for telemetry', style: const TextStyle(color: Colors.white70, fontSize: 9.5, fontWeight: FontWeight.w600)),
              ]),
            ]),
          ),

          const SizedBox(height: 8),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [
                ...(items ?? _navItems.where((item) => AdminIdentity.isFixedAdminEmail(email) ? item.path == '/admin' : item.path != '/admin').toList()).map((item) {
                  final active = path == item.path;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 2),
                    decoration: BoxDecoration(
                      color: active ? AppColors.orange.withValues(alpha: 0.12) : null,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                      leading: Icon(active ? item.activeIcon : item.icon,
                          color: active ? AppTheme.brandForeground(context) : AppTheme.textSecondary(context), size: 20),
                      title: Text(item.label, style: TextStyle(
                          color: active ? AppTheme.brandForeground(context) : AppTheme.textPrimary(context),
                          fontWeight: active ? FontWeight.w700 : FontWeight.w400, fontSize: 14)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      onTap: () { onNav(item.path); Navigator.pop(context); },
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          const Divider(height: 1),
          const SizedBox(height: 4),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              leading: Icon(Icons.logout_rounded, color: AppTheme.dangerForeground(context), size: 20),
              title: Text('Sign Out', style: TextStyle(color: AppTheme.dangerForeground(context), fontWeight: FontWeight.w600, fontSize: 14)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              onTap: onLogout,
            ),
          ),

          const SizedBox(height: 10),
          const _BrandFooter(compact: true),
          const SizedBox(height: 14),
        ]),
      ),
    );
  }
}

// ── Fire Emergency Overlay ────────────────────────────────────────────
class _FireOverlay extends StatefulWidget {
  final VoidCallback onReset;
  const _FireOverlay({required this.onReset});
  @override
  State<_FireOverlay> createState() => _FireOverlayState();
}

class _FireOverlayState extends State<_FireOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.92, end: 1.08).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final r = SensorService.instance.latest;
    return Container(
      decoration: const BoxDecoration(gradient: GlassStyle.emergencyGradient),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            ScaleTransition(scale: _pulse, child: const Icon(Icons.local_fire_department, color: Colors.white, size: 100)),
            const SizedBox(height: 16),
            const Text('FIRE EMERGENCY', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: .4), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Smoke: ${r?.smokeLevel.toStringAsFixed(0) ?? '--'}%  |  Temp: ${r?.temperature.toStringAsFixed(1) ?? '--'}°C  |  Flame: ${r?.flameStatus == true ? "CONFIRMED" : "--"}',
              style: const TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Text('EVACUATE IMMEDIATELY',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, height: 1.5), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            const Text(
              'PyroGuard does not automatically dispatch emergency responders. Use the saved BFP information below and tap CALL BFP to open your phone dialer.',
              style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .18),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(NotificationService.bfpStation?.trim().isNotEmpty == true ? NotificationService.bfpStation! : 'BFP contact not configured', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
                if (NotificationService.bfpPersonnel?.trim().isNotEmpty == true)
                  Text('${NotificationService.bfpPersonnel}${NotificationService.bfpRank?.trim().isNotEmpty == true ? ' · ${NotificationService.bfpRank}' : ''}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                if (NotificationService.bfpPhone.trim().isNotEmpty)
                  Text(NotificationService.bfpPhone, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                if (NotificationService.bfpAddress?.trim().isNotEmpty == true)
                  Text(NotificationService.bfpAddress!, style: const TextStyle(color: Colors.white70, fontSize: 10.5)),
              ]),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  if (NotificationService.bfpPhone.trim().isEmpty) {
                    context.go('/settings');
                    return;
                  }
                  final ok = await NotificationService.callBFP(reading: r);
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the phone dialer. Check the saved BFP number and device calling support.')));
                  }
                },
                icon: Icon(NotificationService.bfpPhone.trim().isEmpty ? Icons.settings_outlined : Icons.phone, color: AppColors.maroon),
                label: Text(NotificationService.bfpPhone.trim().isEmpty ? 'ADD BFP CONTACT IN SETTINGS' : 'CALL BFP NOW', style: const TextStyle(color: AppColors.maroon, fontWeight: FontWeight.w900, fontSize: 15)),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'The CALL BFP action is saved in the audit history. The actual call remains under the user’s control.',
              style: TextStyle(color: Colors.white54, fontSize: 10.5, height: 1.4),
              textAlign: TextAlign.center,
            ),
            if (NotificationService.alarmSoundBlocked) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await NotificationService.retryAlarmSound();
                    setState(() {});
                  },
                  icon: const Icon(Icons.volume_up, color: Colors.white),
                  label: const Text('TAP TO ENABLE ALARM SOUND', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white70, width: 1.2),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextButton(
              onPressed: widget.onReset,
              child: const Text('Reset Alarm (Sensor Cleared)', style: TextStyle(color: Colors.white60, fontSize: 12, decoration: TextDecoration.underline, decorationColor: Colors.white60)),
            ),
          ]),
        ),
      ),
    );
  }
}
