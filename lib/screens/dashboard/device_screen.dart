import 'dart:ui';
import 'package:flutter/material.dart';
import '../../widgets/door_window_activity_panel.dart';
import '../../widgets/cost_estimate_panel.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/camera_service.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/main_esp_service.dart';
import '../../services/sensor_service.dart';
import '../../services/device_service.dart';
import '../../services/dual_controller_sensor_service.dart';
import '../../config/pyroguard_config.dart';
import '../../services/security_control_service.dart';
import '../../theme.dart';
import 'dashboard_models.dart';
import 'dashboard_repository.dart';
import 'controller_detail_card.dart';
import 'room_sensor_panel.dart';
import '../../services/room_sensor_service.dart';

class DeviceTab extends StatefulWidget {
  const DeviceTab({super.key});

  @override
  State<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<DeviceTab> {
  DashboardSnapshot? _dualSnapshot;
  final _dualRepository = DashboardRepository(Supabase.instance.client);
  Future<void> _loadDual() async {
    try { final data = await _dualRepository.load(); if (mounted) setState(() => _dualSnapshot = data); }
    catch (e) { debugPrint("Device status: $e"); }
  }
  final mainEsp = MainEspService.instance;
  final cameraTelemetry = CameraTelemetryService.instance;
  final camera = CameraService.instance;

  @override
  void initState() {
    super.initState();
    _loadDual();
    RoomSensorService.instance.start();
    RoomSensorService.instance.addListener(_refresh);
    mainEsp.addListener(_refresh);
    cameraTelemetry.addListener(_refresh);
    SensorService.instance.addListener(_refresh);
    DeviceService.instance.addListener(_refresh);
    SecurityControlService.instance.addListener(_refresh);
    DeviceService.instance.startListening();
    DualControllerSensorService.instance.addListener(_refresh);
    DualControllerSensorService.instance.start();
    SecurityControlService.instance.startListening();
    mainEsp.startPolling();
    cameraTelemetry.startListening();
    cameraTelemetry.refresh();
    camera.getStatus();
  }

  @override
  void dispose() {
    RoomSensorService.instance.removeListener(_refresh);
    mainEsp.removeListener(_refresh);
    cameraTelemetry.removeListener(_refresh);
    SensorService.instance.removeListener(_refresh);
    DeviceService.instance.removeListener(_refresh);
    SecurityControlService.instance.removeListener(_refresh);
    mainEsp.stopPolling();
    DualControllerSensorService.instance.removeListener(_refresh);
    DualControllerSensorService.instance.stop();
    cameraTelemetry.stopListening();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mainHeartbeatOnline = DeviceService.instance.online;
    final hardwareOnline = mainEsp.online || mainHeartbeatOnline ||
        SensorService.instance.realtimeHeartbeat != HeartbeatState.offline;
    final cam = cameraTelemetry.latest;
    final dualSensors = DualControllerSensorService.instance;
    final secondarySensors = dualSensors.isFresh(PyroGuardConfig.secondaryControllerDeviceId) ? dualSensors.latest(PyroGuardConfig.secondaryControllerDeviceId) : null;
    final security = SecurityControlService.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('System Connections'),
        backgroundColor: AppTheme.bg(context).withValues(alpha: AppTheme.isDark(context) ? .73 : .77),
        flexibleSpace: ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: const SizedBox.expand())),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.orange.withValues(alpha: .15))),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () async {
              await _loadDual();
              await RoomSensorService.instance.refresh();
              await DualControllerSensorService.instance.refresh();
              await mainEsp.refresh();
              await cameraTelemetry.refresh();
              await camera.getStatus();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadDual();
          await DualControllerSensorService.instance.refresh();
          await mainEsp.refresh();
          await cameraTelemetry.refresh();
          await camera.getStatus();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 40),
          children: [
            const RoomSensorPanel(),
            const SizedBox(height: 14),
            const CostEstimatePanel(),
            const SizedBox(height: 14),
            ControllerDetailCard(controller: _dualSnapshot?.main, title: 'Main ESP32 (ESP32-001) — Detailed Sensors'),
            const SizedBox(height: 12),
            ControllerDetailCard(controller: _dualSnapshot?.secondary, title: 'Secondary ESP32 (ESP32-002) — Detailed Sensors'),
            const SizedBox(height: 14),
            _securityControls(security, hardwareOnline),
            const SizedBox(height: 14),
            const DoorWindowActivityPanel(),
            const SizedBox(height: 14),
            _deviceCard(
              title: 'ESP32 Controller 1 — Sensors + Camera 1 Microservo',
              subtitle: 'DHT22 • MQ-2 • Flame sensor • Supabase telemetry',
              icon: Icons.developer_board,
              online: (_dualSnapshot?.main.connected ?? false) || hardwareOnline,
              rows: [
                ('Controller ID', PyroGuardConfig.mainDeviceId),
                ('Assigned camera', 'pyroguard_camera_001'),
                ('Motor', 'Pan servo GPIO 13 • Tilt servo GPIO 14'),
                ('Local IP', mainEsp.ip),
                ('Direct /status', mainEsp.online ? 'Reachable' : 'Not connected'),
                ('Supabase heartbeat', _dualSnapshot?.main.heartbeatFresh == true ? 'Fresh' : 'No fresh hardware heartbeat'),
                ('Supabase table', SensorService.instance.activeTable ?? 'Detecting...'),
              ],
              error: mainEsp.lastError,
            ),
            const SizedBox(height: 14),
            _deviceCard(
              title: 'ESP32 Controller 2 — Batch 2 Sensors',
              subtitle: 'Independent board • own heartbeat • Kitchen & Bedroom',
              icon: Icons.developer_board_outlined,
              online: _dualSnapshot?.secondary.connected ?? false,
              rows: [
                ('Controller ID', PyroGuardConfig.secondaryControllerDeviceId),
                ('Camera', 'None — Kitchen & Bedroom use sensors only'),
                ('Status', secondarySensors == null ? 'No fresh secondary telemetry' : 'Secondary telemetry fresh'),
              ],
              error: dualSensors.lastError,
            ),
            const SizedBox(height: 14),
            _deviceCard(
              title: 'Camera 1 — DFR1154 ESP32-S3 (two-way audio)',
              subtitle: 'OV3660 • Motion • Built-in mic • SPK audio',
              icon: Icons.videocam,
              online: cameraTelemetry.online || camera.lastStatus?.wifiConnected == true,
              rows: [
                ('Local IP', cameraTelemetry.cameraIp),
                ('Supabase telemetry', cam == null ? 'No record loaded' : 'Connected'),
                ('Camera', camera.lastStatus?.cameraReady == true ? 'Ready' : (cam != null ? 'Telemetry online' : '--')),
                ('Microphone', camera.lastStatus?.micReady == true ? 'Ready' : '--'),
                ('Speaker', camera.lastStatus?.speakerReady == true ? 'Ready' : '--'),
                ('Wi-Fi RSSI', cam == null ? '--' : '${cam.wifiRssi} dBm'),
                ('Pan / Tilt', cam == null ? '--' : '${cam.panAngle}° / ${cam.tiltAngle}° (virtual)'),
              ],
              error: cameraTelemetry.lastError ?? camera.lastError,
            ),
            const SizedBox(height: 14),
            GlassPanel(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.hub_outlined, color: AppTheme.brandForeground(context)),
                    const SizedBox(width: 8),
                    const Text('How the system communicates', style: TextStyle(fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 12),
                  _flow('Main ESP32 → Supabase', 'latest sensor telemetry + realtime updates'),
                  _flow('ESP32-S3 Camera → Supabase', 'camera heartbeat + realtime motion telemetry'),
                  _flow('Telemetry → Supabase + MySQL', 'the same important sensor/event records are retained in both backends'),
                  _flow('Flutter → Supabase', 'authentication, realtime state, settings, commands and mirrored history'),
                  _flow('Flutter → Supabase Edge Function → MySQL', 'mirrors important sensor, event, camera, settings and audit records'),
                  _flow('Flutter → Main ESP32', 'local GET /status on the same Wi-Fi'),
                  _flow('Flutter ↔ ESP32-S3 Camera', 'live MJPEG, snapshot, mic, speaker and Push-to-Talk on the same Wi-Fi'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Direct ESP32/camera controls use local HTTP, so the phone/PC running PyroGuard must be able to reach the same LAN. Supabase provides auth/realtime state and its own durable record copy; the mysql-history Edge Function mirrors the same important records into MySQL.',
                style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _securityControls(SecurityControlService security, bool hardwareOnline) {
    Future<void> setMode(SecurityMode mode) async {
      final ok = await security.setMode(mode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? (hardwareOnline ? '${mode.label} saved.' : '${mode.label} saved. It will apply automatically when hardware reconnects.')
            : 'Could not save security command.'),
        backgroundColor: ok ? AppColors.green : AppColors.redBright,
      ));
    }

    Widget modeButton(String label, SecurityMode mode, Color color) {
      final selected = security.mode == mode;
      return OutlinedButton(
        onPressed: security.saving ? null : () => setMode(mode),
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? color.withValues(alpha: .13) : null,
          side: BorderSide(color: selected ? color : AppTheme.border(context)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
        child: Text(label, style: TextStyle(color: selected ? color : AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 10.5)),
      );
    }

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.shield_outlined, color: AppTheme.brandForeground(context)),
          const SizedBox(width: 8),
          Expanded(child: Text('ARM / DISARM CONTROLS', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 13))),
          Text(hardwareOnline ? 'CONNECTED' : 'WAITING FOR HARDWARE', style: TextStyle(color: hardwareOnline ? AppColors.green : AppColors.amber, fontSize: 9, fontWeight: FontWeight.w900)),
        ]),
        const SizedBox(height: 8),
        Text('Security settings are stored even while the ESP32 is offline. Door/window commands are queued in Supabase and can be consumed by the controller when it connects.', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5, height: 1.4)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          modeButton('DISARM', SecurityMode.disarmed, AppColors.amber),
          modeButton('ARM HOME', SecurityMode.armHome, AppColors.orange),
          modeButton('ARM AWAY', SecurityMode.armAway, AppColors.red),
        ]),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.door_front_door_outlined, color: AppTheme.brandForeground(context)),
          title: const Text('Door Protection'),
          subtitle: const Text('Arm/disarm the monitored door contact for intrusion rules.'),
          value: security.doorEnabled,
          onChanged: security.saving ? null : security.setDoorEnabled,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.window_outlined, color: AppTheme.brandForeground(context)),
          title: const Text('Window Protection'),
          subtitle: const Text('Arm/disarm the monitored window contact for intrusion rules.'),
          value: security.windowEnabled,
          onChanged: security.saving ? null : security.setWindowEnabled,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(Icons.directions_run_outlined, color: AppTheme.brandForeground(context)),
          title: const Text('Interior Motion Protection'),
          subtitle: const Text('ARM HOME can keep perimeter protection while treating normal interior movement differently.'),
          value: security.motionEnabled,
          onChanged: security.saving ? null : security.setMotionEnabled,
        ),
        const SizedBox(height: 5),
        Text('Smoke/gas and flame safety monitoring is never disabled by DISARM.', style: TextStyle(color: AppTheme.dangerForeground(context), fontSize: 10, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _deviceCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool online,
    required List<(String, String)> rows,
    String? error,
  }) =>
      GlassPanel(
        padding: const EdgeInsets.all(16),
        glowColor: online ? AppColors.green : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: (online ? AppColors.green : AppColors.amber).withValues(alpha: .12), borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, color: online ? AppTheme.safeForeground(context) : AppTheme.warningForeground(context)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context))),
                  ]),
                ),
                Text(online ? 'ONLINE' : 'NOT CONNECTED', style: TextStyle(color: online ? AppTheme.safeForeground(context) : AppTheme.warningForeground(context), fontSize: 10, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 14),
            ...rows.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(child: Text(r.$1, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)))),
                    Flexible(child: Text(r.$2, textAlign: TextAlign.end, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
                  ]),
                )),
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(error, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 10)),
            ],
          ],
        ),
      );

  Widget _flow(String title, String body) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.chevron_right_rounded, size: 18, color: AppTheme.brandForeground(context))),
          const SizedBox(width: 6),
          Expanded(child: RichText(text: TextSpan(style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)), children: [
            TextSpan(text: '$title: ', style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700)),
            TextSpan(text: body),
          ]))),
        ]),
      );
}
