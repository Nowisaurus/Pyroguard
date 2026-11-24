import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../widgets/pg_notice.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import '../../services/sensor_service.dart';
import '../../services/room_sensor_service.dart';
import '../../services/dual_controller_sensor_service.dart';
import '../../services/device_service.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/camera_motion_service.dart';
import '../../services/security_activity_service.dart';
import '../../config/camera_network_config.dart';
import '../../config/coverage_config.dart';
import '../../services/notification_service.dart';
import '../../services/incident_report_service.dart';
import '../../widgets/evacuation_guide.dart';
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
  String? _dismissedFireEpisode;
  String? _dismissedWarningEpisode;
  String? _lastWarningNoticeId;
  DateTime? _lastWarningNoticeAt;
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
    // "View" on a notification (in-app or phone) opens its page.
    NotificationService.onOpenRoute = (route) {
      if (mounted) _go(route);
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => NotificationService.openPendingRoute());
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
      DualControllerSensorService.instance.start();
      DualControllerSensorService.instance.addListener(_onSensor);
      RoomSensorService.instance.start();
      RoomSensorService.instance.addListener(_onRoomSensor);
      SensorService.instance.startListening();
      DeviceService.instance.startListening();
      CameraTelemetryService.instance.startListening();
      SecurityControlService.instance.startListening();
      AccountBootstrapService.instance.ensureRegistrationPersisted();
      NotificationService.loadBfpContact();
      SensorService.instance.addListener(_onSensor);
      // Camera 1 motion keeps being watched while the app is open, so an
      // armed home is alerted even when the camera screen is closed.
      _cameraOneMotion.attach(CameraMotionMonitor.cameraOneIp());
      // Door/window OPEN/CLOSE and ARM/DISARM from both batches, with alerts.
      SecurityActivityService.instance.start(notify: true);
      CameraNetworkConfig.instance.addListener(_cameraOneAddressChanged);
      CameraTelemetryService.instance.addListener(_cameraOneAddressChanged);
      CameraNetworkConfig.instance.load();
    }
  }

  final CameraMotionMonitor _cameraOneMotion =
      CameraMotionMonitor.forCamera(CoverageConfig.cameraOne);

  void _cameraOneAddressChanged() {
    _cameraOneMotion.setIp(CameraMotionMonitor.cameraOneIp());
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
    NotificationService.onOpenRoute = null;
    _dualSyncRetryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (!_adminIdentity) {
      RoomSensorService.instance.removeListener(_onRoomSensor);
      if (_sirenEpisode != null) NotificationService.stopFireAlarm();
      DualControllerSensorService.instance.removeListener(_onSensor);
      DualControllerSensorService.instance.stop();
      SensorService.instance.removeListener(_onSensor);
      SensorService.instance.stopListening();
      DeviceService.instance.stopListening();
      CameraTelemetryService.instance.stopListening();
      SecurityControlService.instance.stopListening();
      CameraNetworkConfig.instance.removeListener(_cameraOneAddressChanged);
      CameraTelemetryService.instance.removeListener(_cameraOneAddressChanged);
      _cameraOneMotion.detach();
      SecurityActivityService.instance.stop();
    }
    AdminService.instance.removeListener(_onAdminChanged);
    super.dispose();
  }

  void _onAdminChanged() { if (mounted) setState(() {}); }
  // The fire siren follows the SAME rule as the BFP card: two consecutive
  // fresh readings from one room in which the controller confirmed smoke AND
  // flame (RoomSensorService.verifiedFireEmergency). Nothing else starts it.
  String? _sirenEpisode;
  void _onRoomSensor() {
    final fire = RoomSensorService.instance.verifiedFireEmergency;
    final episode = fire == null ? null : '${fire.controller}/${fire.room}';
    if (episode != _sirenEpisode) {
      if (episode == null) {
        NotificationService.stopFireAlarm();
      } else if (fire != null && episode != _dismissedFireEpisode) {
        NotificationService.triggerFireAlarm(SensorReading.fromMap({
          ...fire.reading,
          'device_id': fire.controller,
          'alert_status': 'CRITICAL',
          'severity_level': 2,
          'incident_type': 'Fire Detected - ${RoomSensorService.label(fire.controller, fire.room)}',
          'updated_at': fire.reading['received_at'] ?? fire.reading['sampled_at'],
        }));
      }
      _sirenEpisode = episode;
    }
    if (mounted) setState(() {});
  }

  void _onSensor() {
    final r = SensorService.instance.latest;
    if (!mounted) return;
    if (r == null) { setState(() {}); return; }
    final noticeKey = r.incidentType;
    final quiet = _lastWarningNoticeAt != null &&
        DateTime.now().difference(_lastWarningNoticeAt!) < const Duration(minutes: 5) &&
        noticeKey == _lastWarningNoticeId;
    // The old single-reading warning pop-up is replaced by the verified
    // warning banner (two consecutive room readings), to avoid false alarms.
    const legacyWarningSnackBar = false;
    if (legacyWarningSnackBar && SensorService.instance.warningActive && !SensorService.instance.alarmActive && !quiet) {
      _lastWarningNoticeId = noticeKey;
      _lastWarningNoticeAt = DateTime.now();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: const Color(0xFF92400E),
        duration: const Duration(seconds: 7),
        content: Row(children: [
          const Icon(Icons.warning_amber, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(child: Text(
            '${r.incidentType}. Not a confirmed fire - check the area.',
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
    // Never use the legacy latched alarm flag to display BFP assistance.
    // Only repeated, recent, room-specific physical measurements qualify.
    final verifiedFire = isAdmin
        ? null
        : RoomSensorService.instance.verifiedFireEmergency;
    if (verifiedFire == null) _dismissedFireEpisode = null;
    final fireEpisode = verifiedFire == null ? null : '${verifiedFire.controller}/${verifiedFire.room}';
    final alarm = verifiedFire != null && fireEpisode != _dismissedFireEpisode;
    // Smoke or flame in two consecutive readings, but not a confirmed fire:
    // a warning banner only (no evacuation pop-up for one-sensor readings).
    final warning = isAdmin || verifiedFire != null ? null : RoomSensorService.instance.verifiedWarning;
    final warningEpisode = warning == null ? null : '${warning.controller}/${warning.room}';
    if (warning == null) _dismissedWarningEpisode = null;
    // The floor plan guide pops up as soon as a warning is verified; after
    // "Area checked" it shrinks to the banner, which can reopen it.
    final warningPopup = warning != null && warningEpisode != _dismissedWarningEpisode;
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
                if (warning != null && !warningPopup)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: SafeArea(
                      child: Material(
                        color: const Color(0xFF92400E),
                        borderRadius: BorderRadius.circular(12),
                        elevation: 6,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                          child: Row(children: [
                            Expanded(
                              child: Text(
                                'Warning: ${'${warning.reading['smoke_status']}'.toUpperCase() == 'ALARM' ? 'smoke' : 'flame'} '
                                'in the ${RoomSensorService.label(warning.controller, warning.room)}. '
                                'Not a confirmed fire yet - please check the area.',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(() => _dismissedWarningEpisode = null),
                              child: const Text('Show exit guide', style: TextStyle(color: Colors.white)),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                if (warningPopup)
                  _WarningOverlay(
                    warning: warning!,
                    onOpenMap: () {
                      setState(() => _dismissedWarningEpisode = warningEpisode);
                      _go('/map');
                    },
                    onClose: () => setState(() => _dismissedWarningEpisode = warningEpisode),
                  ),
                if (alarm)
                  _FireOverlay(fire: verifiedFire, onClose: () {
                    // Closing the card acknowledges this episode: siren off too.
                    NotificationService.stopFireAlarm();
                    setState(() => _dismissedFireEpisode = fireEpisode);
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
  const PyroMobileBottomNav({super.key, required this.path, required this.onNav, this.customItems});

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

  const PyroDesktopSidebar({super.key, 
    required this.path, required this.name, required this.email,
    required this.onNav, required this.onLogout,
    this.items, this.adminWorkspace = false,
  });

  @override
  Widget build(BuildContext context) {
    final systemOnline = Supabase.instance.client.auth.currentSession != null;
    final hardwareOnline = !adminWorkspace && (DeviceService.instance.online || SensorService.instance.realtimeHeartbeat != HeartbeatState.offline);
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
        // Persistent branding stays visible while the navigation list scrolls.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Row(children: [
            const PyroGuardLogo(),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PyroGuard', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 18)),
                Text(adminWorkspace ? 'Admin Console' : 'Home Security',
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ])),
          ]),
        ),
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
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
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
                            color: active ? Colors.white : Colors.white70, size: 19),
                        const SizedBox(width: 12),
                        Text(item.label, style: TextStyle(
                            color: active ? Colors.white : Colors.white.withValues(alpha: .92),
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

  const PyroMobileDrawer({super.key, 
    required this.path, required this.name, required this.email,
    required this.onNav, required this.onLogout,
    this.items, this.adminWorkspace = false,
  });

  @override
  Widget build(BuildContext context) {
    final systemOnline = Supabase.instance.client.auth.currentSession != null;
    final hardwareOnline = !adminWorkspace && (DeviceService.instance.online || SensorService.instance.realtimeHeartbeat != HeartbeatState.offline);
    final systemColor = systemOnline ? AppColors.green : AppColors.redBright;
    return Drawer(
      backgroundColor: AppColors.maroon,
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

// ── Confirmed multi-sensor emergency assistance ──────────────────────
// Displayed only while two successive fresh room readings meet the defined
// multi-sensor threshold. The app never auto-calls emergency responders.
class _FireOverlay extends StatefulWidget {
  final VerifiedRoomFire fire;
  final VoidCallback onClose;
  const _FireOverlay({required this.fire, required this.onClose});

  @override
  State<_FireOverlay> createState() => _FireOverlayState();
}

class _FireOverlayState extends State<_FireOverlay> {
  bool _calling = false;
  bool _reporting = false;

  /// Downloads the BFP incident report (PDF with camera photos and
  /// verification code) for this fire.
  Future<void> _downloadReport() async {
    final fire = widget.fire;
    setState(() => _reporting = true);
    try {
      final inc = await IncidentReportService.latestIncident(
          controller: fire.controller, room: fire.room, days: 2);
      if (inc == null) {
        if (mounted) {
          PgNotice.show('The readings are still being saved. Try again in a few seconds.', kind: PgNoticeKind.warning);
        }
        return;
      }
      await IncidentReportService.download(inc);
    } catch (e) {
      if (mounted) {
        PgNotice.show('Could not create the PDF: $e', kind: PgNoticeKind.error);
      }
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    NotificationService.loadBfpContact().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final fire = widget.fire;
    final row = fire.reading;
    final temperature = row['temperature'] is num
        ? '${(row['temperature'] as num).toStringAsFixed(1)} °C'
        : 'NOT REPORTED';
    final smoke = '${row['smoke_status'] ?? 'UNKNOWN'}';
    final flame = row['flame_detected'] == true ? 'DETECTED' : 'NOT DETECTED';
    final station = NotificationService.bfpStation?.trim().isNotEmpty == true
        ? NotificationService.bfpStation!
        : 'BFP contact not configured';
    final phone = NotificationService.bfpPhone.trim();

    return Positioned.fill(
      child: Material(
        color: const Color(0x99160C0C),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.card(context).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppColors.red.withValues(alpha: .5)),
                    boxShadow: [BoxShadow(
                      color: Colors.black.withValues(alpha: .22),
                      blurRadius: 32, offset: const Offset(0, 12),
                    )],
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Align(alignment: Alignment.topRight, child: IconButton(
                      tooltip: 'Dismiss BFP assistance card',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.onClose,
                    )),
                    Image.asset('assets/images/logo_phoenix.png',
                        width: 56, height: 56, fit: BoxFit.contain),
                    const SizedBox(height: 12),
                    const Text('Verified multi-sensor fire warning',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
                    const SizedBox(height: 7),
                    Text('${fire.controller}  •  ${RoomSensorService.label(fire.controller, fire.room)}',
                      style: TextStyle(fontSize: 13,
                        color: AppTheme.textSecondary(context))),
                    const SizedBox(height: 14),
                    // The evacuation guide comes FIRST: where the fire is,
                    // where you are, and the animated safe route to the exit.
                    EvacuationGuideCard(controller: fire.controller, room: fire.room),
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.red.withValues(alpha: .08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Recent verified sensor readings',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 7),
                        Text('Smoke: $smoke  •  Flame: $flame'),
                        Text('Temperature: $temperature'),
                        const SizedBox(height: 5),
                        const Text('If you see smoke, fire, or immediate danger, evacuate and contact emergency services.',
                          style: TextStyle(fontSize: 12)),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    Align(alignment: Alignment.centerLeft,
                      child: Text(station, style: const TextStyle(fontWeight: FontWeight.w800))),
                    if (phone.isNotEmpty) Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(phone,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                    if (NotificationService.bfpAddress?.trim().isNotEmpty == true)
                      Align(alignment: Alignment.centerLeft,
                        child: Text(NotificationService.bfpAddress!,
                          style: TextStyle(fontSize: 12,
                            color: AppTheme.textSecondary(context)))),
                    const SizedBox(height: 16),
                    SizedBox(width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _calling ? null : () async {
                          setState(() => _calling = true);
                          try {
                            await NotificationService.loadBfpContact();
                            if (!context.mounted) return;
                            if (NotificationService.bfpPhone.trim().isEmpty ||
                                !NotificationService.bfpConfirmedByUser) {
                              PgNotice.show('Confirm a valid BFP contact in Settings first.', kind: PgNoticeKind.warning);
                              return;
                            }
                            final ok = await NotificationService.callBFP(
                              deviceIdOverride: fire.controller);
                            if (!ok && context.mounted) {
                              PgNotice.show('Phone dialer could not be opened. Use the displayed phone number or a telephone.', kind: PgNoticeKind.error);
                            }
                          } finally {
                            if (mounted) setState(() => _calling = false);
                          }
                        },
                        icon: const Icon(Icons.call_outlined),
                        label: Text(_calling ? 'Opening dialer…' : 'Call BFP'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.red,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _reporting ? null : _downloadReport,
                        icon: _reporting
                            ? const SizedBox(width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.picture_as_pdf_outlined),
                        label: Text(_reporting ? 'Preparing report…' : 'Incident report for BFP (PDF)'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.statusForeground(context, AppColors.red),
                          side: BorderSide(color: AppColors.red.withValues(alpha: .6)),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity,
                      child: TextButton.icon(
                        onPressed: () {
                          widget.onClose();
                          context.go('/map');
                        },
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('Open full floor plan and map'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.statusForeground(context, AppColors.green),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('Opens your device dialer; it does not automatically place a call or dispatch responders. '
                         'You can close this card; active sensor warnings remain visible in Monitoring.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11,
                        color: AppTheme.textSecondary(context))),
                  ]),
                  ),
                ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pop-up for a verified smoke OR flame warning (two consecutive readings):
/// shows the floor plan with the room marked and the safe way out, so the
/// family knows where to go while they check the area.
class _WarningOverlay extends StatelessWidget {
  const _WarningOverlay({required this.warning, required this.onClose, required this.onOpenMap});
  final VerifiedRoomFire warning;
  final VoidCallback onClose;
  final VoidCallback onOpenMap;

  @override
  Widget build(BuildContext context) {
    final r = warning.reading;
    final smoke = '${r['smoke_status'] ?? ''}'.toUpperCase();
    final what = r['flame_detected'] == true && ['ALARM', 'FIRE', 'DANGER', 'CRITICAL'].contains(smoke)
        ? 'Smoke and flame'
        : r['flame_detected'] == true
            ? 'Flame'
            : 'Smoke';
    final room = RoomSensorService.label(warning.controller, warning.room);
    final temp = r['temperature'] is num ? '${(r['temperature'] as num).toStringAsFixed(1)} °C' : '-';

    return Positioned.fill(
      child: Material(
        color: const Color(0x88160C0C),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      decoration: BoxDecoration(
                        color: AppTheme.card(context).withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: AppColors.amber.withValues(alpha: .6)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .22), blurRadius: 32, offset: const Offset(0, 12))],
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(color: AppColors.amber.withValues(alpha: .16), borderRadius: BorderRadius.circular(11)),
                            child: Icon(Icons.warning_amber_rounded, color: AppTheme.warningForeground(context)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('$what detected in the $room',
                                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: AppTheme.textPrimary(context))),
                              Text('Not a confirmed fire yet · ${warning.controller} · $temp',
                                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary(context))),
                            ]),
                          ),
                          IconButton(tooltip: 'Close', onPressed: onClose, icon: const Icon(Icons.close_rounded)),
                        ]),
                        const SizedBox(height: 10),
                        Text(
                          'Check the $room carefully. If you see smoke or fire, leave right away using the route below.',
                          style: TextStyle(fontSize: 12.5, color: AppTheme.textPrimary(context), height: 1.35),
                        ),
                        const SizedBox(height: 12),
                        EvacuationGuideCard(controller: warning.controller, room: warning.room, level: 1),
                        const SizedBox(height: 14),
                        Row(children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: onOpenMap,
                              icon: const Icon(Icons.map_outlined, size: 18),
                              label: const Text('Full map'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              style: FilledButton.styleFrom(backgroundColor: AppColors.orange, foregroundColor: Colors.white),
                              onPressed: onClose,
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: const Text('Area checked'),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
