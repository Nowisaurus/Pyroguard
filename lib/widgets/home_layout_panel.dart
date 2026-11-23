import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'pg_notice.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/room_sensor_service.dart';
import '../theme.dart';
import 'evacuation_guide.dart';
import 'pg_ui.dart';

export 'evacuation_guide.dart' show LayoutItem, kRoomSensors, defaultLayout;

/// Defense panel recommendations (2026-11-21):
///  * where in the house the fire is, with the layout and the way out
///  * the nearest evacuation area
///  * house size and the sensors in each room
///  * the area each room's sensors cover
/// Drawn to scale from `pyroguard_home_layout` (editable so the real floor plan
/// can be entered). The same animated plan pops up during a verified fire.
class HomeLayoutPanel extends StatefulWidget {
  const HomeLayoutPanel({super.key, this.homeLat, this.homeLng});
  final double? homeLat;
  final double? homeLng;

  @override
  State<HomeLayoutPanel> createState() => _HomeLayoutPanelState();
}

/// Typical coverage drawn on the plan. Makerlab lists the flame module's
/// 60° detection angle and 760-1100 nm band but no distance; about 1 m for a
/// lighter flame is the usual figure for these modules.
const double kFlameCoverageM = 1.0;
const double kSmokeCoverageM = 2.0;

class _HomeLayoutPanelState extends State<HomeLayoutPanel> {
  final rooms = RoomSensorService.instance;
  SupabaseClient get _db => Supabase.instance.client;
  HomeLayoutData? _data;
  List<LayoutItem> _items = defaultLayout();
  bool _saved = false;
  bool _dirty = false;
  bool _showDetails = false;

  Map<String, dynamic>? get _home => _data?.home;
  bool get _ownHome => _data?.ownHome ?? false;
  LatLng? get _homePoint => widget.homeLat != null && widget.homeLng != null
      ? LatLng(widget.homeLat!, widget.homeLng!)
      : _data?.homePoint;
  LatLng? get _evacPoint => _data?.evacPoint;
  List<LayoutItem> get _exits => _items.where((i) => i.kind == 'exit').toList();

  @override
  void initState() {
    super.initState();
    rooms.addListener(_changed);
    evacuationYouRoom.addListener(_changed);
    rooms.start();
    _load();
  }

  @override
  void dispose() {
    rooms.removeListener(_changed);
    evacuationYouRoom.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final data = await loadHomeLayout();
    if (!mounted) return;
    setState(() {
      _data = data;
      if (!_dirty) {
        _items = data.items;
        _saved = data.saved;
      }
    });
  }

  Future<void> _setEvacuation() async {
    final home = _homePoint;
    if (!_ownHome || _home == null) {
      PgNotice.show('Only the home owner can set the evacuation area.', kind: PgNoticeKind.warning);
      return;
    }
    LatLng picked = _evacPoint ?? home ?? const LatLng(14.6620, 120.9570);
    final name = TextEditingController(text: '${_home?['evac_name'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Evacuation area'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                controller: name,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'Name (e.g. Barangay covered court)',
                                  ),
              ),
              Text('Tap the map to place the evacuation area.',
                  style: TextStyle(color: AppTheme.textSecondary(ctx), fontSize: 12)),
              const SizedBox(height: 8),
              SizedBox(
                height: 260,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: FlutterMap(
                    options: MapOptions(
                      initialCenter: picked,
                      initialZoom: 16,
                      onTap: (_, p) => setD(() => picked = p),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.pyroguard.app',
                      ),
                      MarkerLayer(markers: [
                        if (home != null)
                          Marker(point: home, width: 36, height: 36,
                              child: const Icon(Icons.home_outlined, color: AppColors.orange, size: 30)),
                        Marker(point: picked, width: 36, height: 36,
                            child: const Icon(Icons.flag_outlined, color: AppColors.green, size: 30)),
                      ]),
                    ],
                  ),
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await _db.from('homes').update({
        'evac_name': name.text.trim().isEmpty ? null : name.text.trim(),
        'evac_latitude': picked.latitude,
        'evac_longitude': picked.longitude,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _home!['id']);
      await _load();
    } catch (e) {
      if (mounted) {
        PgNotice.show('Could not save: $e', kind: PgNoticeKind.error);
      }
    }
  }

  // ── Layout editing ────────────────────────────────────────────────
  Future<void> _saveLayout() async {
    final uid = _db.auth.currentUser?.id;
    try {
      await _db.from('pyroguard_home_layout').upsert(
        [for (final i in _items) {...i.toRow(), 'user_id': uid}],
        onConflict: 'user_id,item_key',
      );
      final keep = _items.map((i) => i.key).toList();
      final existing = await _db.from('pyroguard_home_layout').select('item_key');
      for (final r in existing as List) {
        final k = '${(r as Map)['item_key']}';
        if (!keep.contains(k)) await _db.from('pyroguard_home_layout').delete().eq('item_key', k);
      }
      _saved = true;
      _dirty = false;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) PgNotice.show('Could not save: $e', kind: PgNoticeKind.error);
    }
  }

  Future<void> _editItem(LayoutItem item) async {
    final label = TextEditingController(text: item.label);
    final f = {
      'x': TextEditingController(text: item.x.toStringAsFixed(1)),
      'y': TextEditingController(text: item.y.toStringAsFixed(1)),
      'w': TextEditingController(text: item.w.toStringAsFixed(1)),
      'h': TextEditingController(text: item.h.toStringAsFixed(1)),
    };
    Widget field(String k, String text) => Expanded(
          child: TextField(
            controller: f[k],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: text, suffixText: 'm'),
          ),
        );
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : Colors.white,
        surfaceTintColor: Colors.transparent,
        title: Text(item.kind == 'room' ? 'Room size and position' : 'Exit door position'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: label, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            Row(children: [field('w', 'Width'), const SizedBox(width: 10), field('h', 'Length')]),
            const SizedBox(height: 8),
            Row(children: [field('x', 'From left wall'), const SizedBox(width: 10), field('y', 'From top wall')]),
            const SizedBox(height: 8),
            Text('Measure from the top-left corner of the house. Use the floor plan measurements.',
                style: TextStyle(color: AppTheme.textSecondary(ctx), fontSize: 11.5)),
          ]),
        ),
        actions: [
          if (item.kind == 'exit')
            TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'ok'), child: const Text('Apply')),
        ],
      ),
    );
    if (result == 'delete') {
      setState(() {
        _items.remove(item);
        _dirty = true;
      });
      return;
    }
    if (result != 'ok') return;
    double read(String k, double old) =>
        (double.tryParse(f[k]!.text.replaceAll(',', '.')) ?? old).clamp(0, 200).toDouble();
    setState(() {
      _dirty = true;
      item.label = label.text.trim().isEmpty ? item.label : label.text.trim();
      item.x = read('x', item.x);
      item.y = read('y', item.y);
      item.w = math.max(.2, read('w', item.w));
      item.h = math.max(.2, read('h', item.h));
    });
  }

  void _addExit() {
    final n = _exits.length + 1;
    final item = LayoutItem(key: 'exit_${DateTime.now().millisecondsSinceEpoch}', kind: 'exit',
        label: 'Exit $n', x: 0, y: 0, w: 1, h: .4);
    setState(() {
      _items.add(item);
      _dirty = true;
    });
    _editItem(item);
  }

  // ── UI ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final roomsList = _items.where((i) => i.kind == 'room').toList();
    final hazard = {for (final r in roomsList) r.key: liveHazard(r)};
    final fire = roomsList.where((r) => (hazard[r.key] ?? 0) > 0).toList();
    final routes = planRoutes(_items, hazard);
    final evacText = _data?.evacDistance(_homePoint);
    final you = evacuationYouRoom.value;
    final steps = evacuationSteps(_items, hazard, routes,
        evacName: _evacPoint == null ? null : _data!.evacName, evacDistance: evacText, youRoom: you);
    final houseW = _items.fold<double>(0, (m, i) => math.max(m, i.x + i.w));
    final houseH = _items.fold<double>(0, (m, i) => math.max(m, i.y + i.h));
    final floorArea = roomsList.fold<double>(0, (s, r) => s + r.area);
    final sensorCount = roomsList.fold<int>(0, (s, r) => s + (kRoomSensors[r.room]?.length ?? 0));
    const flameR = kFlameCoverageM;
    const smokeR = kSmokeCoverageM;

    return PgCard(
      accent: fire.isEmpty ? null : AppColors.red,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PgHeader(
          icon: Icons.home_work_outlined,
          title: 'Home Layout & Evacuation',
          subtitle: 'Your floor plan with live sensor status. Tap the room you are in to see your own way out; '
              'the fire and the safe route update automatically.',
          actions: [
            TextButton(onPressed: _addExit, child: const Text('Add exit')),
            FilledButton(
              onPressed: _saveLayout,
              style: FilledButton.styleFrom(
                backgroundColor: _dirty ? AppColors.orange : AppColors.maroonMid,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(_dirty ? 'Save' : 'Saved'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        PgTile(
          color: fire.isEmpty ? AppColors.green : AppColors.red,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(steps[i],
                    style: TextStyle(
                        color: i == 0 && fire.isNotEmpty ? AppTheme.dangerForeground(context) : primary,
                        fontWeight: i == 0 ? FontWeight.w800 : FontWeight.w500,
                        fontSize: 12.5)),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        WhereAreYouChips(items: _items),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: EvacuationPlanView(
            items: _items,
            hazard: hazard,
            youRoom: you,
            onTapItem: (i) {
              if (i.kind == 'room') {
                evacuationYouRoom.value = i.key;
              } else {
                _editItem(i);
              }
            },
            flameRangeM: flameR,
            smokeRangeM: smokeR,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 14, runSpacing: 4, children: [
          _legend(AppColors.red, 'Fire'),
          _legend(AppColors.amber, 'Warning'),
          _legend(AppColors.green, 'Safe route to exit'),
          _legend(const Color(0xFF1D4ED8), 'You'),
          _legend(AppColors.orange.withValues(alpha: .45), 'Flame sensor ${flameR.toStringAsFixed(1)} m'),
          _legend(Colors.blueGrey.withValues(alpha: .45), 'Smoke sensor ${smokeR.toStringAsFixed(1)} m'),
        ]),
        const SizedBox(height: 12),
        // Evacuation area
        PgTile(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_evacPoint == null ? 'Nearest evacuation area: not set' : 'Nearest evacuation area: ${_data!.evacName}',
                    style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
                Text(evacText ?? 'Set the barangay evacuation area (covered court, school or open space).',
                    style: TextStyle(color: secondary, fontSize: 11.5)),
              ]),
            ),
            TextButton(onPressed: _setEvacuation, child: Text(_evacPoint == null ? 'Set' : 'Change')),
          ]),
        ),
        if (_homePoint != null && _evacPoint != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 190,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints([_homePoint!, _evacPoint!]),
                    padding: const EdgeInsets.all(40),
                    maxZoom: 17,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.pyroguard.app',
                  ),
                  PolylineLayer(polylines: [
                    Polyline(points: [_homePoint!, _evacPoint!], color: AppColors.green, strokeWidth: 4),
                  ]),
                  MarkerLayer(markers: [
                    Marker(point: _homePoint!, width: 30, height: 30,
                        child: const Icon(Icons.home_outlined, color: AppColors.orange, size: 28)),
                    Marker(point: _evacPoint!, width: 30, height: 30,
                        child: const Icon(Icons.flag_outlined, color: AppColors.green, size: 28)),
                  ]),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        // House size & sensors (collapsible to keep the page tidy)
        InkWell(
          onTap: () => setState(() => _showDetails = !_showDetails),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(
                child: Text(
                  'House ${houseW.toStringAsFixed(1)} × ${houseH.toStringAsFixed(1)} m · ${floorArea.toStringAsFixed(1)} m² · '
                  '${roomsList.length} rooms · $sensorCount sensors',
                  style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
              ),
              Icon(_showDetails ? Icons.expand_less : Icons.expand_more, color: secondary),
            ]),
          ),
        ),
        if (_showDetails)
          for (final r in roomsList)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: PgTile(
                onTap: () => _editItem(r),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(r.label, style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12.5))),
                    Text('${r.w.toStringAsFixed(1)} × ${r.h.toStringAsFixed(1)} m · ${r.area.toStringAsFixed(1)} m²',
                        style: TextStyle(color: secondary, fontSize: 11.5)),
                  ]),
                  const SizedBox(height: 3),
                  Text('${kRoomSensors[r.room]?.length ?? 0} sensors: ${(kRoomSensors[r.room] ?? const <String>[]).join(', ')}',
                      style: TextStyle(color: secondary, fontSize: 11.5)),
                  Text(
                    'Flame sensor covers about '
                    '${(math.min(1.0, math.pi * flameR * flameR / math.max(r.area, .1)) * 100).round()}% of this room '
                    '(${flameR.toStringAsFixed(1)} m range, typical for a 60° flame module)',
                    style: TextStyle(color: secondary, fontSize: 11.5),
                  ),
                ]),
              ),
            ),
      ]),
    );
  }

  Widget _legend(Color c, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 11, height: 11, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11)),
      ]);
}
