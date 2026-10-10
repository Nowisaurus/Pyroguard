import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../services/sensor_service.dart';
import '../../services/location_service.dart';
import '../../theme.dart';
import '../dashboard/shared_app_bar.dart';

class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  Map<String, dynamic> _home = const {};
  String? _resolvedAddress;
  double? _resolvedLat;
  double? _resolvedLng;
  bool _resolvingAddress = false;
  @override
  void initState() {
    super.initState();
    SensorService.instance.addListener(_rebuild);
    _loadHome();
  }

  @override
  void dispose() {
    SensorService.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (!mounted) return;
    setState(() {});
    _resolveActiveAddress();
  }

  Future<void> _resolveActiveAddress() async {
    final sensorService = SensorService.instance;
    final sensor = sensorService.realtimeHeartbeat == HeartbeatState.offline
        ? null
        : sensorService.latest;
    final user = Supabase.instance.client.auth.currentUser;
    final meta = user?.userMetadata ?? const <String, dynamic>{};
    final homeLat = (_home['latitude'] as num?)?.toDouble() ??
        (meta['home_latitude'] as num?)?.toDouble();
    final homeLng = (_home['longitude'] as num?)?.toDouble() ??
        (meta['home_longitude'] as num?)?.toDouble();
    final lat = sensor?.deviceLat ?? homeLat;
    final lng = sensor?.deviceLng ?? homeLng;
    if (lat == null || lng == null || _resolvingAddress) return;
    if (_resolvedLat == lat && _resolvedLng == lng && _resolvedAddress != null) return;
    _resolvingAddress = true;
    try {
      final address = await LocationService.resolvePlaceName(lat, lng);
      if (!mounted) return;
      setState(() {
        _resolvedAddress = address;
        _resolvedLat = lat;
        _resolvedLng = lng;
      });
    } finally {
      _resolvingAddress = false;
    }
  }

  Future<void> _loadHome() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final row = await Supabase.instance.client.from('homes').select().eq('user_id', uid).maybeSingle();
      if (mounted && row != null) {
        setState(() => _home = Map<String, dynamic>.from(row));
        await _resolveActiveAddress();
      }
    } catch (_) {
      // Signup metadata fallback below keeps the page usable before migration.
    }
  }

  Future<void> _openInMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _openOSM(double lat, double lng) async {
    final uri = Uri.parse('https://www.openstreetmap.org/?mlat=$lat&mlon=$lng&zoom=16');
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final isDark  = AppTheme.isDark(context);
    final sensorService = SensorService.instance;
    final sensor = sensorService.realtimeHeartbeat == HeartbeatState.offline ? null : sensorService.latest;
    final isFire = sensor?.isCriticalFire ?? false;
    final user = Supabase.instance.client.auth.currentUser;
    final meta = user?.userMetadata ?? const <String, dynamic>{};
    final homeLat = (_home['latitude'] as num?)?.toDouble() ?? (meta['home_latitude'] as num?)?.toDouble();
    final homeLng = (_home['longitude'] as num?)?.toDouble() ?? (meta['home_longitude'] as num?)?.toDouble();
    // Live device GPS wins only while the hardware telemetry is fresh.
    final lat = sensor?.deviceLat ?? homeLat;
    final lng = sensor?.deviceLng ?? homeLng;
    final usingDeviceGps = sensor?.deviceLat != null;
    final locTxt = (_resolvedAddress ?? _home['address'] ?? meta['address'] ?? 'Location not set').toString();
    final uName = (meta['full_name'] ?? 'User').toString();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PyroAppBar(
        title: 'Live Map',
        subtitle: isFire ? 'Emergency location ready for response' : 'Registered home / live device location',
      ),
      body: Column(children: [
        // Fire alert banner
        if (isFire)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.red,
            child: const Row(children: [
              Icon(Icons.local_fire_department, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('FIRE DETECTED — Saved home/device location is ready for the manual CALL BFP workflow.',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))),
            ]),
          ),

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

              // Location card
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppTheme.card(context),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: isFire ? AppColors.red.withValues(alpha: 0.4) : AppColors.orange.withValues(alpha: 0.15)),
                  boxShadow: [BoxShadow(color: (isFire ? AppColors.red : AppColors.orange).withValues(alpha: 0.1), blurRadius: 16, offset: const Offset(0, 4))],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: (isFire ? AppColors.red : AppColors.orange).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(isFire ? Icons.local_fire_department : Icons.location_on,
                          color: isFire ? AppColors.red : AppColors.orange, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(isFire ? 'Fire Location' : 'Registered Location',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context))),
                      Text(uName, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context))),
                    ])),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: (isFire ? AppColors.red : AppColors.green).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(isFire ? 'ALERT' : 'SAFE',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900,
                              color: isFire ? AppColors.red : AppColors.green)),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [Icon(Icons.home_work_outlined, size: 15, color: AppTheme.textSecondary(context)), const SizedBox(width: 6), Text('Address', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.textSecondary(context)))]),
                      const SizedBox(height: 4),
                      Text(locTxt, style: TextStyle(fontSize: 13, color: AppTheme.textPrimary(context), height: 1.4)),
                      if (lat != null && lng != null) ...[
                        const SizedBox(height: 8),
                        Row(children: [Icon(Icons.my_location_outlined, size: 15, color: AppTheme.textSecondary(context)), const SizedBox(width: 6), Text('GPS Coordinates', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppTheme.textSecondary(context)))]),
                        const SizedBox(height: 4),
                        Text('${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                            style: TextStyle(fontSize: 12, color: AppTheme.brandForeground(context), fontFamily: 'monospace', fontWeight: FontWeight.w700)),
                      ],
                    ]),
                  ),
                ]),
              ),

              const SizedBox(height: 14),

              // Map preview (static + link)
              if (lat != null && lng != null) ...[
                Container(
                  decoration: BoxDecoration(
                    color: AppTheme.card(context),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.border(context)),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Column(children: [
                    // Real embedded map (OpenStreetMap tiles — no API
                    // key needed), not just a placeholder box.
                    SizedBox(
                      height: 260,
                      child: Stack(
                        children: [
                          FlutterMap(
                            options: MapOptions(
                              initialCenter: LatLng(lat, lng),
                              initialZoom: 16,
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.pyroguard.app',
                              ),
                              MarkerLayer(markers: [
                                Marker(
                                  point: LatLng(lat, lng),
                                  width: 44,
                                  height: 44,
                                  child: Icon(
                                    Icons.location_pin,
                                    color: isFire ? AppColors.red : AppColors.orange,
                                    size: 44,
                                  ),
                                ),
                              ]),
                            ],
                          ),
                          if (isFire)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Container(
                                  color: AppColors.red.withValues(alpha: 0.1),
                                  child: Align(
                                    alignment: Alignment.topCenter,
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 10),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: AppColors.red,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.local_fire_department_outlined, color: Colors.white, size: 16), SizedBox(width: 6), Text('FIRE LOCATION', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12))]),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (usingDeviceGps)
                            Positioned(
                              left: 8, bottom: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('Live device GPS', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
                              ),
                            ),
                        ],
                      ),
                    ),

                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(child: _MapBtn(
                          icon: Icons.map,
                          label: 'Google Maps',
                          color: AppColors.orange,
                          onTap: () => _openInMaps(lat, lng),
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: _MapBtn(
                          icon: Icons.public,
                          label: 'OpenStreetMap',
                          color: AppColors.maroonMid,
                          onTap: () => _openOSM(lat, lng),
                        )),
                      ]),
                    ),
                  ]),
                ),
              ] else ...[
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.card(context),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.orange.withValues(alpha: 0.2)),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.location_off_outlined, size: 60, color: AppTheme.brandForeground(context)),
                    const SizedBox(height: 12),
                    Text('No coordinates saved', style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('Update your location in your profile to enable map tracking.',
                        style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12, height: 1.4), textAlign: TextAlign.center),
                  ]),
                ),
              ],

              const SizedBox(height: 14),

              // Sensor summary
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.border(context)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Live Sensor Status', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary(context))),
                  const SizedBox(height: 10),
                  Row(children: [
                    _SensorChip(label: 'Smoke', value: '${sensor?.smokeLevel.toStringAsFixed(0) ?? '--'}%', color: sensor?.smokeLevel != null && sensor!.smokeLevel >= 70 ? AppColors.red : AppColors.orange),
                    const SizedBox(width: 8),
                    _SensorChip(label: 'Temp', value: '${sensor?.temperature.toStringAsFixed(1) ?? '--'}°C', color: AppColors.orange),
                    const SizedBox(width: 8),
                    _SensorChip(label: 'Flame', value: sensor?.flameStatus == true ? 'YES' : 'None', color: sensor?.flameStatus == true ? AppColors.red : AppColors.green),
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    'The saved home pin is stored with your setup and shown during emergency review. PyroGuard does not claim automatic BFP dispatch.',
                    style: TextStyle(fontSize: 10, color: AppTheme.textSecondary(context), height: 1.4),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _MapBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _MapBtn({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: AppTheme.statusForeground(context, color), size: 16),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: AppTheme.statusForeground(context, color), fontWeight: FontWeight.w800, fontSize: 12)),
      ]),
    ),
  );
}

class _SensorChip extends StatelessWidget {
  final String label, value;
  final Color color;
  const _SensorChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(children: [
        Text(label, style: TextStyle(fontSize: 9, color: AppTheme.textSecondary(context), fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: AppTheme.statusForeground(context, color))),
      ]),
    ),
  );
}
