import 'package:flutter/material.dart';
import '../../widgets/pg_notice.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/location_service.dart';
import '../../services/room_sensor_service.dart';
import '../../theme.dart';
import '../../widgets/home_layout_panel.dart';
import '../../widgets/pg_ui.dart';
import '../dashboard/shared_app_bar.dart';

/// Live Map: the registered home on a real street map with its real address,
/// the live state of every room (from the room sensors), and the home floor
/// plan with the evacuation route. The fire history moved to Events.
class MapTab extends StatefulWidget {
  const MapTab({super.key});
  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  final _rooms = RoomSensorService.instance;
  final _map = MapController();
  Map<String, dynamic> _home = const {};
  bool _ownHome = false;
  String? _gpsAddress;
  bool _loadingHome = true;
  static final _time = DateFormat('h:mm:ss a');

  @override
  void initState() {
    super.initState();
    _rooms.addListener(_changed);
    _rooms.start();
    _loadHome();
  }

  @override
  void dispose() {
    _rooms.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  SupabaseClient get _db => Supabase.instance.client;

  double? get _lat => (_home['latitude'] as num?)?.toDouble() ??
      double.tryParse('${_db.auth.currentUser?.userMetadata?['home_latitude'] ?? ''}');
  double? get _lng => (_home['longitude'] as num?)?.toDouble() ??
      double.tryParse('${_db.auth.currentUser?.userMetadata?['home_longitude'] ?? ''}');

  Future<void> _loadHome() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    try {
      var row = await _db.from('homes').select().eq('user_id', uid).maybeSingle();
      _ownHome = row != null;
      if (row == null) {
        final m = await _db.from('pyroguard_home_members').select('home_id')
            .eq('user_id', uid).eq('membership_status', 'approved').limit(1);
        if (m.isNotEmpty) row = await _db.from('homes').select().eq('id', m.first['home_id']).maybeSingle();
      }
      if (row != null) _home = Map<String, dynamic>.from(row);
    } catch (_) {}
    if (mounted) setState(() => _loadingHome = false);
    final lat = _lat, lng = _lng;
    if (lat != null && lng != null) {
      try {
        final a = await LocationService.resolvePlaceName(lat, lng);
        if (mounted) setState(() => _gpsAddress = a);
      } catch (_) {}
    }
  }

  /// Owner sets the real home pin and address (tap map or use phone GPS).
  Future<void> _editLocation() async {
    if (!_ownHome || _home['id'] == null) {
      PgNotice.show('Only the home owner can change the home location.', kind: PgNoticeKind.warning);
      return;
    }
    var point = LatLng(_lat ?? 14.6510, _lng ?? 120.9674);
    final address = TextEditingController(text: '${_home['address'] ?? ''}');
    final barangay = TextEditingController(text: '${_home['barangay'] ?? ''}');
    final city = TextEditingController(text: '${_home['city'] ?? ''}');
    final dialogMap = MapController();
    var busy = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        Future<void> fill(LatLng p) async {
          setD(() {
            point = p;
            busy = true;
          });
          try {
            address.text = await LocationService.resolvePlaceName(p.latitude, p.longitude);
          } catch (_) {}
          setD(() => busy = false);
        }

        return AlertDialog(
          backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Home location'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Tap the exact house on the map, or use this phone\'s GPS while at home.',
                    style: TextStyle(color: AppTheme.textSecondary(ctx), fontSize: 12)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 240,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: FlutterMap(
                      mapController: dialogMap,
                      options: MapOptions(initialCenter: point, initialZoom: 17, onTap: (_, p) => fill(p)),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.pyroguard.app',
                        ),
                        MarkerLayer(markers: [
                          Marker(point: point, width: 40, height: 40,
                              child: const Icon(Icons.location_on, color: AppColors.red, size: 38)),
                        ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            final pos = await LocationService.getCurrentPosition();
                            final p = LatLng(pos.latitude, pos.longitude);
                            dialogMap.move(p, 18);
                            await fill(p);
                          } catch (e) {
                            if (ctx.mounted) {
                              PgNotice.show('GPS not available: $e', kind: PgNoticeKind.error);
                            }
                          }
                        },
                  child: Text(busy ? 'Finding address...' : 'Use my current location'),
                ),
                const SizedBox(height: 8),
                TextField(controller: address, maxLines: 2, decoration: const InputDecoration(labelText: 'House no., street, subdivision')),
                Row(children: [
                  Expanded(child: TextField(controller: barangay, decoration: const InputDecoration(labelText: 'Barangay'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: city, decoration: const InputDecoration(labelText: 'City'))),
                ]),
                const SizedBox(height: 6),
                Text('${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
                    style: TextStyle(color: AppTheme.textSecondary(ctx), fontSize: 11.5, fontFamily: 'monospace')),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: busy ? null : () => Navigator.pop(ctx, true), child: const Text('Save location')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _db.from('homes').update({
        'latitude': point.latitude,
        'longitude': point.longitude,
        'address': address.text.trim().isEmpty ? null : address.text.trim(),
        'barangay': barangay.text.trim().isEmpty ? null : barangay.text.trim(),
        'city': city.text.trim().isEmpty ? null : city.text.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _home['id']);
      await _loadHome();
      try {
        _map.move(point, 17);
      } catch (_) {}
    } catch (e) {
      if (mounted) PgNotice.show('Could not save: $e', kind: PgNoticeKind.error);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Latest reading time over all rooms (for the "Live" label).
  DateTime? get _lastUpdate {
    DateTime? best;
    for (final c in RoomSensorService.controllerIds) {
      for (final r in RoomSensorService.roomsFor(c)) {
        final t = DateTime.tryParse('${_rooms.reading(c, r)?['received_at'] ?? ''}')?.toLocal();
        if (t != null && (best == null || t.isAfter(best))) best = t;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final fire = _rooms.verifiedFireEmergency;
    final lat = _lat, lng = _lng;
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final last = _lastUpdate;
    final live = last != null && DateTime.now().difference(last).inSeconds < 90;
    final registered = [
      '${_home['address'] ?? ''}'.trim(),
      '${_home['barangay'] ?? ''}'.trim(),
      '${_home['city'] ?? ''}'.trim(),
    ].where((s) => s.isNotEmpty).join(', ');

    // Live room states.
    final roomStates = <(String, String, String, Color)>[];
    for (final c in RoomSensorService.controllerIds) {
      for (final r in RoomSensorService.roomsFor(c)) {
        final row = _rooms.reading(c, r);
        final fresh = _rooms.fresh(c, r);
        String state;
        Color color;
        if (fire != null && fire.controller == c && fire.room == r) {
          state = 'FIRE';
          color = AppColors.red;
        } else if (!fresh || row == null) {
          state = 'Offline';
          color = AppColors.maroonMid;
        } else if ('${row['smoke_status']}'.toUpperCase() == 'ALARM' || row['flame_detected'] == true) {
          state = 'Warning';
          color = AppColors.amber;
        } else {
          state = 'Safe';
          color = AppColors.green;
        }
        final temp = row?['temperature'] is num ? '${(row!['temperature'] as num).toStringAsFixed(1)} °C' : '--';
        roomStates.add((RoomSensorService.label(c, r), state, temp, color));
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PyroAppBar(
        title: 'Live Map',
        subtitle: fire != null
            ? 'FIRE in ${RoomSensorService.label(fire.controller, fire.room)} - follow the evacuation guide'
            : 'Home location, live room status and evacuation guide',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 96),
        children: [
          // Location + live map
          PgCard(
            accent: fire != null ? AppColors.red : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PgHeader(
                icon: Icons.location_on_outlined,
                title: fire != null ? 'Fire location' : 'Home location',
                actions: [
                  PgBadge(live ? 'LIVE · ${_time.format(last)}' : 'NO LIVE DATA',
                      color: live ? AppColors.green : AppColors.maroonMid),
                  const SizedBox(width: 6),
                  if (_ownHome) TextButton(onPressed: _editLocation, child: const Text('Edit')),
                ],
              ),
              const SizedBox(height: 8),
              if (_loadingHome) const LinearProgressIndicator(color: AppColors.orange),
              Text(registered.isEmpty ? 'Address not set' : registered,
                  style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 13.5, height: 1.35)),
              if (_gpsAddress != null && _gpsAddress != registered)
                Text('Map address: $_gpsAddress', style: TextStyle(color: secondary, fontSize: 12)),
              if (lat != null && lng != null)
                Text('GPS ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                    style: TextStyle(color: AppTheme.brandForeground(context), fontSize: 12, fontFamily: 'monospace')),
              const SizedBox(height: 10),
              if (lat == null || lng == null)
                PgTile(
                  child: Text(
                    _ownHome
                        ? 'No location saved yet. Tap Edit to pin the house on the map.'
                        : 'The home owner has not saved the home location yet.',
                    style: TextStyle(color: secondary, fontSize: 12.5),
                  ),
                )
              else ...[
                SizedBox(
                  height: 260,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: FlutterMap(
                      mapController: _map,
                      options: MapOptions(initialCenter: LatLng(lat, lng), initialZoom: 17),
                      children: [
                        TileLayer(
                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.pyroguard.app',
                        ),
                        if (fire != null)
                          CircleLayer(circles: [
                            CircleMarker(
                              point: LatLng(lat, lng),
                              radius: 60,
                              useRadiusInMeter: true,
                              color: AppColors.red.withValues(alpha: .18),
                              borderColor: AppColors.red,
                              borderStrokeWidth: 2,
                            ),
                          ]),
                        MarkerLayer(markers: [
                          Marker(
                            point: LatLng(lat, lng),
                            width: 42,
                            height: 42,
                            child: Icon(Icons.location_on, color: fire != null ? AppColors.red : AppColors.orange, size: 40),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _open('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
                      child: const Text('Open in Google Maps'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _open('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng'),
                      child: const Text('Directions'),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          // Live room status
          PgCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const PgHeader(icon: Icons.sensors_outlined, title: 'Live room status'),
              const SizedBox(height: 8),
              LayoutBuilder(builder: (context, b) {
                final w = b.maxWidth >= 520 ? (b.maxWidth - 24) / 4 : (b.maxWidth - 8) / 2;
                return Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in roomStates)
                    SizedBox(
                      width: w,
                      child: PgTile(
                        color: s.$4,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.$1, style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
                          const SizedBox(height: 2),
                          Text(s.$2,
                              style: TextStyle(
                                  color: AppTheme.statusForeground(context, s.$4), fontWeight: FontWeight.w900, fontSize: 13)),
                          Text(s.$3, style: TextStyle(color: secondary, fontSize: 11.5)),
                        ]),
                      ),
                    ),
                ]);
              }),
            ]),
          ),
          const SizedBox(height: 14),
          // Floor plan + evacuation guide (live)
          HomeLayoutPanel(homeLat: lat, homeLng: lng),
        ],
      ),
    );
  }
}
