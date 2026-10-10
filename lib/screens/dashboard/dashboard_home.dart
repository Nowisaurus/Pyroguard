import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/device_service.dart';
import '../../services/sensor_service.dart';
import '../../services/security_control_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import 'shared_app_bar.dart';

class DashboardTab extends StatefulWidget {
  const DashboardTab({super.key});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    SensorService.instance.addListener(_rebuild);
    DeviceService.instance.addListener(_rebuild);
    CameraTelemetryService.instance.addListener(_rebuild);
    SecurityControlService.instance.addListener(_rebuild);
    SecurityControlService.instance.startListening();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    SensorService.instance.removeListener(_rebuild);
    DeviceService.instance.removeListener(_rebuild);
    CameraTelemetryService.instance.removeListener(_rebuild);
    SecurityControlService.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    await Future.wait([
      SensorService.instance.refreshHistory(),
      CameraTelemetryService.instance.refresh(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final sensor = SensorService.instance;
    final device = DeviceService.instance;
    final camera = CameraTelemetryService.instance;
    final latest = sensor.latest;
    final user = Supabase.instance.client.auth.currentUser;
    final name = (user?.userMetadata?['full_name'] as String? ?? 'User')
        .split(' ')
        .first;

    final sensorHeartbeat = sensor.realtimeHeartbeat;
    final systemOnline = Supabase.instance.client.auth.currentSession != null;
    final hardwareOnline = sensorHeartbeat != HeartbeatState.offline && device.online;
    final liveLatest = hardwareOnline ? latest : null;
    final security = SecurityControlService.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PyroAppBar(
        title: 'PyroGuard',
        subtitle: 'Home Security · Hi, $name',
      ),
      body: RefreshIndicator(
            color: AppColors.orange,
            backgroundColor: AppTheme.card(context),
            onRefresh: _refresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                Responsive.horizontalPadding(context),
                14,
                Responsive.horizontalPadding(context),
                88,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SystemHero(
                        platformOnline: systemOnline,
                        hardwareOnline: hardwareOnline,
                        mode: security.mode,
                        latest: latest,
                      ),
                      const SizedBox(height: 12),
                      _SecurityControlsPanel(
                        security: security,
                        hardwareOnline: hardwareOnline,
                      ),
                      const SizedBox(height: 18),
                      _SectionHeader(
                        icon: Icons.monitor_heart_outlined,
                        title: 'Sensor Heartbeat',
                        subtitle: 'Connection health is separate from the sensor reading.',
                      ),
                      const SizedBox(height: 9),
                      _HeartbeatGrid(
                        sensor: sensor,
                        device: device,
                        camera: camera,
                      ),
                      const SizedBox(height: 18),
                      const _SectionHeader(
                        icon: Icons.home_outlined,
                        title: 'Live Home Status',
                        subtitle: 'Realtime transport via Supabase; important snapshots are retained in both Supabase and MySQL.',
                      ),
                      const SizedBox(height: 9),
                      _LiveStatusGrid(
                        latest: liveLatest,
                        camera: camera,
                        alarmActive: sensor.alarmActive,
                      ),
                      const SizedBox(height: 18),
                      const _SectionHeader(
                        icon: Icons.bolt_outlined,
                        title: 'Happening Now',
                        subtitle: 'Latest realtime activity.',
                      ),
                      const SizedBox(height: 9),
                      _HappeningNow(latest: liveLatest, camera: camera),
                      const SizedBox(height: 18),
                      _SectionHeader(
                        icon: Icons.history,
                        title: 'Recent Events',
                        subtitle: sensor.historyApiConfigured
                            ? 'Mirrored event history retained in both Supabase and MySQL.'
                            : 'Sign in and deploy the mysql-history Edge Function to keep both database copies synchronized.',
                      ),
                      const SizedBox(height: 9),
                      _RecentEvents(sensor: sensor),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }
}

class _SystemHero extends StatelessWidget {
  const _SystemHero({
    required this.platformOnline,
    required this.hardwareOnline,
    required this.mode,
    required this.latest,
  });

  final bool platformOnline;
  final bool hardwareOnline;
  final SecurityMode mode;
  final SensorReading? latest;

  @override
  Widget build(BuildContext context) {
    final liveDanger = hardwareOnline && latest?.isCriticalFire == true;
    final liveWarning = hardwareOnline && latest?.isWarning == true;
    final modeColor = switch (mode) {
      SecurityMode.armAway => AppColors.red,
      SecurityMode.armHome => AppColors.orange,
      SecurityMode.disarmed => AppColors.amber,
    };
    final color = liveDanger
        ? AppColors.red
        : liveWarning
            ? AppColors.amber
            : modeColor;
    final foregroundColor = AppTheme.statusForeground(context, color);
    final detail = !platformOnline
        ? 'The application is not connected to Supabase.'
        : !hardwareOnline
            ? 'PyroGuard cloud services are online. The ESP32/camera has not sent a fresh heartbeat yet, so live hardware readings remain unavailable.'
            : liveDanger
                ? 'Critical hazard telemetry is being reported by the connected hardware.'
                : liveWarning
                    ? 'Connected hardware is reporting a condition that requires attention.'
                    : 'Hardware is connected and realtime monitoring is active.';

    return GlassPanel(
      radius: 22,
      padding: const EdgeInsets.all(18),
      borderColor: color.withValues(alpha: 0.35),
      glowColor: color.withValues(alpha: 0.13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PulseDot(color: platformOnline ? AppColors.green : AppColors.redBright, enabled: platformOnline),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 9,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          mode.label,
                          style: TextStyle(
                            color: foregroundColor,
                            fontSize: Responsive.isCompact(context) ? 18 : 21,
                            fontWeight: FontWeight.w900,
                            letterSpacing: .4,
                          ),
                        ),
                        _HeroBadge(
                          label: platformOnline ? 'SYSTEM ONLINE' : 'SYSTEM OFFLINE',
                          color: platformOnline ? AppColors.green : AppColors.redBright,
                        ),
                        _HeroBadge(
                          label: hardwareOnline ? 'HARDWARE CONNECTED' : 'HARDWARE NOT CONNECTED',
                          color: hardwareOnline ? AppColors.green : AppColors.amber,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(detail, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12, height: 1.45)),
                    if (latest != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        hardwareOnline
                            ? 'Latest hardware telemetry: ${_ageText(latest!.createdAt)}'
                            : 'Last stored realtime row: ${_ageText(latest!.createdAt)} · not shown as a live reading while the hardware heartbeat is stale.',
                        style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(liveDanger ? Icons.crisis_alert : Icons.shield_outlined, color: foregroundColor, size: 35),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: .28)),
        ),
        child: Text(label, style: TextStyle(color: AppTheme.statusForeground(context, color), fontSize: 8.8, fontWeight: FontWeight.w900, letterSpacing: .45)),
      );
}

class _SecurityControlsPanel extends StatelessWidget {
  const _SecurityControlsPanel({required this.security, required this.hardwareOnline});
  final SecurityControlService security;
  final bool hardwareOnline;

  Future<void> _mode(BuildContext context, SecurityMode mode) async {
    final ok = await security.setMode(mode);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? (hardwareOnline ? '${mode.label} command saved and sent.' : '${mode.label} saved. It will be applied automatically when the ESP32 reconnects.')
          : 'Could not save the security mode.'),
      backgroundColor: ok ? AppColors.green : AppColors.redBright,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.security_outlined, color: AppTheme.brandForeground(context), size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text('Security Controls', style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 14, fontWeight: FontWeight.w900))),
            if (security.saving) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: 4),
          Text(
            hardwareOnline
                ? 'Door, window and intrusion modes are connected to the realtime controller.'
                : 'You can configure protection now. Commands remain saved in Supabase and are applied when the hardware reconnects.',
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, height: 1.4),
          ),
          const SizedBox(height: 11),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _SecurityModeButton(label: 'DISARM', color: AppColors.amber, selected: security.mode == SecurityMode.disarmed, onTap: () => _mode(context, SecurityMode.disarmed)),
              _SecurityModeButton(label: 'ARM HOME', color: AppColors.orange, selected: security.mode == SecurityMode.armHome, onTap: () => _mode(context, SecurityMode.armHome)),
              _SecurityModeButton(label: 'ARM AWAY', color: AppColors.red, selected: security.mode == SecurityMode.armAway, onTap: () => _mode(context, SecurityMode.armAway)),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < 620;
            final door = _ProtectionSwitch(
              icon: Icons.door_front_door_outlined,
              title: 'Door Protection',
              value: security.doorEnabled,
              onChanged: security.saving ? null : security.setDoorEnabled,
            );
            final window = _ProtectionSwitch(
              icon: Icons.window_outlined,
              title: 'Window Protection',
              value: security.windowEnabled,
              onChanged: security.saving ? null : security.setWindowEnabled,
            );
            final motion = _ProtectionSwitch(
              icon: Icons.directions_run_outlined,
              title: 'Motion Protection',
              value: security.motionEnabled,
              onChanged: security.saving ? null : security.setMotionEnabled,
            );
            if (narrow) return Column(children: [door, window, motion]);
            return Row(children: [Expanded(child: door), const SizedBox(width: 8), Expanded(child: window), const SizedBox(width: 8), Expanded(child: motion)]);
          }),
          const SizedBox(height: 5),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.local_fire_department_outlined, color: AppTheme.dangerForeground(context), size: 15),
            const SizedBox(width: 6),
            Expanded(child: Text('Smoke/gas and flame monitoring remain active even when intrusion protection is DISARMED.', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 9.8, height: 1.35))),
          ]),
        ],
      ),
    );
  }
}

class _SecurityModeButton extends StatelessWidget {
  const _SecurityModeButton({required this.label, required this.color, required this.selected, required this.onTap});
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color.withValues(alpha: .14) : AppTheme.card(context).withValues(alpha: .32),
          side: BorderSide(color: selected ? color : AppTheme.border(context)),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        ),
        child: Text(label, style: TextStyle(color: selected ? AppTheme.statusForeground(context, color) : AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 10.5)),
      );
}

class _ProtectionSwitch extends StatelessWidget {
  const _ProtectionSwitch({required this.icon, required this.title, required this.value, required this.onChanged});
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.card(context).withValues(alpha: .42),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border(context)),
        ),
        child: SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          secondary: Icon(icon, color: value ? AppTheme.brandForeground(context) : AppTheme.textSecondary(context), size: 18),
          title: Text(title, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 10.5, fontWeight: FontWeight.w800)),
          value: value,
          onChanged: onChanged,
        ),
      );
}

class _HeartbeatGrid extends StatelessWidget {
  const _HeartbeatGrid({
    required this.sensor,
    required this.device,
    required this.camera,
  });

  final SensorService sensor;
  final DeviceService device;
  final CameraTelemetryService camera;

  @override
  Widget build(BuildContext context) {
    final health = device.latest;
    final controllerState = health?.heartbeatState ?? HeartbeatState.offline;

    // Individual component health comes only from device_heartbeats. A fresh
    // SAFE value in sensor_readings is not used as proof that the MQ-2 itself
    // is still online. This is the deliberate reading-vs-heartbeat split.
    HeartbeatState componentState(bool? ok) {
      if (health == null || ok == null || ok == false) {
        return HeartbeatState.offline;
      }
      return health.heartbeatState;
    }

    final rows = <_HeartbeatData>[
      _HeartbeatData(
        'Main Controller',
        Icons.memory_outlined,
        controllerState,
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Door Sensor',
        Icons.door_front_door_outlined,
        componentState(health?.doorOk),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Window Sensor',
        Icons.window_outlined,
        componentState(health?.windowOk),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Motion Sensor',
        Icons.directions_run_outlined,
        componentState(health?.pirOk),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Smoke Sensor',
        Icons.cloud_outlined,
        componentState(health?.mq2Ok),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Flame Sensor',
        Icons.local_fire_department_outlined,
        componentState(health?.flameOk),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'Temp / Humidity',
        Icons.thermostat_outlined,
        componentState(health?.dht22Ok),
        health?.reportedAt,
      ),
      _HeartbeatData(
        'AI Camera',
        Icons.videocam_outlined,
        camera.latest == null
            ? HeartbeatState.offline
            : camera.online
                ? HeartbeatState.online
                : HeartbeatState.offline,
        camera.latest?.createdAt,
      ),
    ];


    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1050 ? 4 : width >= 720 ? 3 : width >= 400 ? 2 : 1;
        return GridView.count(
          crossAxisCount: columns,
          crossAxisSpacing: 9,
          mainAxisSpacing: 9,
          childAspectRatio: width < 400 ? 2.8 : width < 620 ? 1.35 : 1.55,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: rows.map((e) => _HeartbeatCard(data: e)).toList(),
        );
      },
    );
  }
}

class _HeartbeatCard extends StatelessWidget {
  const _HeartbeatCard({required this.data});
  final _HeartbeatData data;

  @override
  Widget build(BuildContext context) {
    final color = _heartbeatColor(context, data.state);
    final foregroundColor = AppTheme.statusForeground(context, color);
    final label = data.lastSeen == null && data.state == HeartbeatState.offline ? 'NOT CONNECTED' : _heartbeatLabel(data.state);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: GlassStyle.card(
        light: !AppTheme.isDark(context),
        border: color.withValues(alpha: 0.24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(data.icon, color: foregroundColor, size: 19),
              const Spacer(),
              _MiniPulse(color: color, active: data.state == HeartbeatState.online),
            ],
          ),
          const Spacer(),
          Text(
            data.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textPrimary(context),
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(color: foregroundColor, fontWeight: FontWeight.w900, fontSize: 11),
          ),
          Text(
            data.lastSeen == null ? 'No heartbeat yet' : _ageText(data.lastSeen!),
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

class _LiveStatusGrid extends StatelessWidget {
  const _LiveStatusGrid({
    required this.latest,
    required this.camera,
    required this.alarmActive,
  });

  final SensorReading? latest;
  final CameraTelemetryService camera;
  final bool alarmActive;

  @override
  Widget build(BuildContext context) {
    final motion = latest?.motionDetected ?? camera.latest?.motionDetected;
    final smokeSafe = latest == null
        ? null
        : latest!.isCriticalFire || latest!.isWarning
            ? false
            : true;

    final cards = <_StatusData>[
      _StatusData(
        'Door',
        latest == null ? 'NOT CONNECTED' : latest!.doorStatus,
        latest == null ? 'Waiting for ESP32/reed-switch telemetry' : (latest!.doorStatus == 'CLOSED' ? 'Secure' : 'Realtime contact state'),
        Icons.door_front_door_outlined,
        latest == null ? AppColors.amber : (latest!.doorStatus == 'OPEN' ? AppColors.amber : AppColors.green),
      ),
      _StatusData(
        'Window',
        latest == null ? 'NOT CONNECTED' : latest!.windowStatus,
        latest == null ? 'Waiting for ESP32/reed-switch telemetry' : (latest!.windowStatus == 'CLOSED' ? 'Secure' : 'Realtime contact state'),
        Icons.window_outlined,
        latest == null ? AppColors.amber : (latest!.windowStatus == 'OPEN' ? AppColors.amber : AppColors.green),
      ),
      _StatusData(
        'Motion',
        motion == null ? 'NOT CONNECTED' : motion ? 'DETECTED' : 'NONE',
        motion == null ? 'Waiting for motion/camera telemetry' : (motion == true ? 'Activity detected' : 'Area clear'),
        Icons.directions_run_outlined,
        motion == null ? AppColors.amber : (motion == true ? AppColors.amber : AppColors.green),
      ),
      _StatusData(
        'Temperature',
        latest == null ? '--' : '${latest!.temperature.toStringAsFixed(1)}°C',
        latest == null ? 'Waiting for hardware telemetry' : 'Live DHT22 reading',
        Icons.thermostat_outlined,
        latest != null && latest!.temperature >= 45 ? AppColors.red : AppColors.green,
      ),
      _StatusData(
        'Humidity',
        latest == null ? '--' : '${latest!.humidity.toStringAsFixed(0)}%',
        latest == null ? 'Waiting for hardware telemetry' : 'Live DHT22 reading',
        Icons.water_drop_outlined,
        AppColors.maroonMid,
      ),
      _StatusData(
        'Smoke / Gas',
        latest == null ? '--' : latest!.smokeStatus.toUpperCase(),
        latest == null
            ? 'Waiting for hardware telemetry'
            : 'MQ-2 raw ${latest!.smokeRaw} · ${smokeSafe == true ? 'Reading SAFE' : 'Reading needs attention'}',
        Icons.cloud_outlined,
        smokeSafe == null
            ? AppTheme.textSecondary(context)
            : smokeSafe
                ? AppColors.green
                : latest!.isCriticalFire
                    ? AppColors.red
                    : AppColors.amber,
      ),
      _StatusData(
        'Flame',
        latest == null ? '--' : latest!.flameStatus ? 'DETECTED' : 'NONE',
        latest == null ? 'Waiting for flame-sensor telemetry' : (latest!.flameStatus ? 'Flame sensor triggered' : 'No flame reported'),
        Icons.local_fire_department_outlined,
        latest == null ? AppColors.amber : (latest!.flameStatus ? AppColors.red : AppColors.green),
      ),
      _StatusData(
        'Camera',
        camera.online ? 'ONLINE' : 'NOT CONNECTED',
        camera.latest == null ? 'Waiting for ESP32-S3 camera heartbeat' : _ageText(camera.latest!.createdAt),
        Icons.videocam_outlined,
        camera.online ? AppColors.green : AppColors.redBright,
      ),
      _StatusData(
        'Alarm',
        alarmActive ? 'ON' : 'OFF',
        alarmActive ? 'Emergency alarm active' : 'Alarm is idle',
        alarmActive ? Icons.notifications_active : Icons.notifications_none,
        alarmActive ? AppColors.red : AppColors.green,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 900 ? 3 : width >= 560 ? 2 : 1;
        return GridView.count(
          crossAxisCount: columns,
          crossAxisSpacing: 9,
          mainAxisSpacing: 9,
          childAspectRatio: width < 560 ? 3.0 : 2.0,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: cards.map((e) => _StatusCard(data: e)).toList(),
        );
      },
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.data});
  final _StatusData data;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = AppTheme.statusForeground(context, data.color);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: GlassStyle.card(
        light: !AppTheme.isDark(context),
        border: data.color.withValues(alpha: 0.18),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: data.color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(data.icon, color: foregroundColor, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.label,
                  style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5),
                ),
                const SizedBox(height: 2),
                Text(
                  data.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textSecondary(context),
                    fontSize: 9.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HappeningNow extends StatelessWidget {
  const _HappeningNow({required this.latest, required this.camera});
  final SensorReading? latest;
  final CameraTelemetryService camera;

  @override
  Widget build(BuildContext context) {
    final live = latest?.heartbeatState != HeartbeatState.offline;
    late final Color color;
    late final IconData icon;
    late final String title;
    late final String detail;

    if (latest == null || !live) {
      color = AppTheme.textSecondary(context);
      icon = Icons.sensors_off_outlined;
      title = 'Waiting for realtime telemetry';
      detail = 'No fresh sensor heartbeat is available right now.';
    } else if (latest!.isCriticalFire) {
      color = AppColors.red;
      icon = Icons.crisis_alert;
      title = 'Critical fire / smoke alert';
      detail = '${latest!.smokeStatus} · MQ-2 ${latest!.smokeRaw} · Flame ${latest!.flameStatus ? 'DETECTED' : 'NONE'}';
    } else if (latest!.isWarning) {
      color = AppColors.amber;
      icon = Icons.warning_amber_outlined;
      title = latest!.incidentType;
      detail = 'Smoke ${latest!.smokeLevel.toStringAsFixed(0)}% · MQ-2 ${latest!.smokeRaw}';
    } else if (latest!.motionDetected == true || camera.latest?.motionDetected == true) {
      color = AppColors.amber;
      icon = Icons.directions_run_outlined;
      title = 'Motion detected';
      detail = 'A realtime motion event is active.';
    } else if (latest!.doorStatus == 'OPEN') {
      color = AppColors.amber;
      icon = Icons.door_front_door_outlined;
      title = 'Front door opened';
      detail = 'Door contact reports OPEN.';
    } else if (latest!.windowStatus == 'OPEN') {
      color = AppColors.amber;
      icon = Icons.window_outlined;
      title = 'Window opened';
      detail = 'Window contact reports OPEN.';
    } else {
      color = AppColors.green;
      icon = Icons.check_circle_outline;
      title = 'Everything looks normal';
      detail = 'No unusual realtime activity detected.';
    }

    final foregroundColor = AppTheme.statusForeground(context, color);

    return GlassPanel(
      radius: 18,
      padding: const EdgeInsets.all(15),
      borderColor: color.withValues(alpha: 0.28),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: foregroundColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(color: foregroundColor, fontWeight: FontWeight.w800, fontSize: 13)),
                const SizedBox(height: 3),
                Text(detail,
                    style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11.5)),
              ],
            ),
          ),
          if (latest != null)
            Text(
              _timeText(latest!.createdAt),
              style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10),
            ),
        ],
      ),
    );
  }
}

class _RecentEvents extends StatelessWidget {
  const _RecentEvents({required this.sensor});
  final SensorService sensor;

  @override
  Widget build(BuildContext context) {
    if (sensor.historyLoading && sensor.history.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(color: AppColors.orange)),
      );
    }

    if (!sensor.historyApiConfigured) {
      return _InfoPanel(
        icon: Icons.storage_outlined,
        title: 'Dual-database sync function unavailable',
        detail:
            'Realtime monitoring can continue through Supabase. Deploy mysql-history and configure its MySQL secrets so important records are retained in both databases.',
      );
    }

    if (sensor.historyError != null && sensor.history.isEmpty) {
      return _InfoPanel(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load mirrored history',
        detail: sensor.historyError!,
      );
    }

    if (sensor.history.isEmpty) {
      return const _InfoPanel(
        icon: Icons.history_toggle_off_outlined,
        title: 'No historical events yet',
        detail: 'Realtime data is separate; permanent events will appear here after they are written to MySQL.',
      );
    }

    return GlassPanel(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Column(
        children: sensor.history.take(8).map((r) => _HistoryRow(reading: r)).toList(),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.reading});
  final SensorReading reading;

  @override
  Widget build(BuildContext context) {
    final color = reading.isCriticalFire
        ? AppColors.red
        : reading.isWarning
            ? AppColors.amber
            : AppColors.green;
    final foregroundColor = AppTheme.statusForeground(context, color);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.border(context).withValues(alpha: 0.5))),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reading.incidentType,
                  style: TextStyle(color: foregroundColor, fontWeight: FontWeight.w700, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  'Smoke ${reading.smokeStatus} · ${reading.smokeRaw} · ${reading.temperature.toStringAsFixed(1)}°C',
                  style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10),
                ),
              ],
            ),
          ),
          Text(
            _dateTimeText(reading.createdAt),
            textAlign: TextAlign.right,
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 9.5),
          ),
        ],
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => GlassPanel(
        radius: 18,
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.brandForeground(context), size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: AppTheme.textPrimary(context),
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5)),
                  const SizedBox(height: 4),
                  Text(detail,
                      style: TextStyle(
                          color: AppTheme.textSecondary(context),
                          fontSize: 10.5,
                          height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.brandForeground(context), size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: AppTheme.textPrimary(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w900)),
                Text(subtitle,
                    style: TextStyle(
                        color: AppTheme.textSecondary(context),
                        fontSize: 10.5,
                        height: 1.35)),
              ],
            ),
          ),
        ],
      );
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, required this.enabled});
  final Color color;
  final bool enabled;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (_, __) => Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            boxShadow: widget.enabled
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.10 + _controller.value * 0.18),
                      blurRadius: 12 + _controller.value * 12,
                      spreadRadius: _controller.value * 3,
                    ),
                  ]
                : const [],
          ),
          child: Icon(
            widget.enabled ? Icons.shield : Icons.shield_outlined,
            color: widget.color,
            size: 24,
          ),
        ),
      );
}

class _MiniPulse extends StatelessWidget {
  const _MiniPulse({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          if (active) ...[
            const SizedBox(width: 4),
            Icon(Icons.monitor_heart_outlined, color: AppTheme.statusForeground(context, color), size: 13),
          ],
        ],
      );
}

class _HeartbeatData {
  const _HeartbeatData(this.name, this.icon, this.state, this.lastSeen);
  final String name;
  final IconData icon;
  final HeartbeatState state;
  final DateTime? lastSeen;
}

class _StatusData {
  const _StatusData(this.label, this.value, this.sub, this.icon, this.color);
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final Color color;
}

Color _heartbeatColor(BuildContext context, HeartbeatState state) {
  switch (state) {
    case HeartbeatState.online:
      return AppColors.green;
    case HeartbeatState.delayed:
      return AppColors.amber;
    case HeartbeatState.offline:
      return AppColors.redBright;
  }
}

String _heartbeatLabel(HeartbeatState state) {
  switch (state) {
    case HeartbeatState.online:
      return 'ONLINE';
    case HeartbeatState.delayed:
      return 'DELAYED';
    case HeartbeatState.offline:
      return 'OFFLINE';
  }
}

String _ageText(DateTime timestamp) {
  final diff = DateTime.now().difference(timestamp.toLocal());
  if (diff.inSeconds < 5) return 'just now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

String _timeText(DateTime timestamp) {
  final local = timestamp.toLocal();
  final hour12 = local.hour == 0 ? 12 : local.hour > 12 ? local.hour - 12 : local.hour;
  final amPm = local.hour >= 12 ? 'PM' : 'AM';
  return '$hour12:${local.minute.toString().padLeft(2, '0')} $amPm';
}

String _dateTimeText(DateTime timestamp) {
  final local = timestamp.toLocal();
  return '${local.month}/${local.day}/${local.year}\n${_timeText(local)}';
}
