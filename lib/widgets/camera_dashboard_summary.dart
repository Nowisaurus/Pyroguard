import 'package:flutter/material.dart';

import '../services/camera_telemetry_service.dart';
import '../services/sensor_service.dart';
import '../theme.dart';

class CameraDashboardSummary extends StatefulWidget {
  const CameraDashboardSummary({super.key});

  @override
  State<CameraDashboardSummary> createState() => _CameraDashboardSummaryState();
}

class _CameraDashboardSummaryState extends State<CameraDashboardSummary> {
  @override
  void initState() {
    super.initState();
    SensorService.instance.addListener(_refresh);
    CameraTelemetryService.instance.addListener(_refresh);
  }

  @override
  void dispose() {
    SensorService.instance.removeListener(_refresh);
    CameraTelemetryService.instance.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final telemetry = CameraTelemetryService.instance.latest;
    final rssi = telemetry?.wifiRssi;
    final quality = _wifiPercent(rssi);
    final online = telemetry?.isFresh == true && ((telemetry?.status.toLowerCase() ?? '') == 'online');
    final network = (telemetry?.wifiSsid ?? '').trim();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Camera temperature removed: the cameras have no temperature sensor.
        final wifiCard = _wifiCard(rssi: rssi, quality: quality, online: online, ip: telemetry?.cameraIp ?? 'Unknown', network: network);
        // Minimum height keeps it level with neighbours; it can grow with large
        // system text sizes instead of overflowing.
        return ConstrainedBox(
          constraints: BoxConstraints(minHeight: 164, minWidth: constraints.maxWidth, maxWidth: constraints.maxWidth),
          child: wifiCard,
        );
      },
    );
  }

  int _wifiPercent(int? rssi) {
    if (rssi == null || rssi == 0) return 0;
    final value = (2 * (rssi + 100)).clamp(0, 100);
    return value.toInt();
  }

  Widget _wifiCard({required int? rssi, required int quality, required bool online, required String ip, required String network}) => _glassMetric(
    title: 'Wi-Fi Signal',
    subtitle: network.isNotEmpty ? network : 'Camera 1 telemetry',
    icon: online ? Icons.wifi_rounded : Icons.wifi_off_rounded,
    iconColor: online ? AppColors.green : AppColors.amber,
    body: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(online ? 'Connected' : 'Offline / stale', style: TextStyle(fontWeight: FontWeight.w700, color: online ? AppColors.green : AppColors.amber))),
        Text(online && rssi != null ? '$quality%' : '--', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 9),
      ClipRRect(borderRadius: BorderRadius.circular(9), child: LinearProgressIndicator(
        minHeight: 7, value: online ? quality / 100 : 0,
        backgroundColor: Colors.white.withValues(alpha: .10),
        color: online ? AppColors.green : AppColors.amber,
      )),
      const SizedBox(height: 9),
      Text(online ? 'Network: ${network.isEmpty ? 'Not reported' : network}  •  RSSI: $rssi dBm  •  IP: $ip' : 'Waiting for a fresh camera heartbeat',
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
    ]),
  );

  Widget _glassMetric({
    required String title, required String subtitle, required IconData icon,
    required Color iconColor, required Widget body,
  }) => GlassPanel(
    radius: 22, blur: 1.5, borderColor: AppColors.orange.withValues(alpha: .20),
    padding: const EdgeInsets.all(16),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 16, fontWeight: FontWeight.w800)),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.isDark(context) ? AppColors.textSecondary : AppColors.lightTextSecondary, fontSize: 11)),
        ])),
        Icon(icon, color: iconColor, size: 27),
      ]),
      const SizedBox(height: 22),
      body,
    ]),
  );
}
