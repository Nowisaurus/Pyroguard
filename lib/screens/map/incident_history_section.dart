import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/room_sensor_service.dart';
import '../../theme.dart';
import '../../widgets/pg_ui.dart';

/// Panel suggestion (2026-11-21): "a historical timeline of those that got
/// burned in that area ... can you see the prone area?"
///
/// Shows on one map:
///  * this home's own PyroGuard incidents (confirmed fire / smoke / flame
///    readings from `pyroguard_room_sensor_readings`), and
///  * past fires in the surrounding area (`pyroguard_area_incidents`):
///    the team's researched Malabon / Caloocan fire history (news & BFP
///    reports) plus entries added by residents,
/// with red zones where incidents cluster (fire-prone), a fire-risk level
/// for the home, and a timeline grouped by year. Tap an entry for details.
class IncidentHistorySection extends StatefulWidget {
  const IncidentHistorySection({super.key, required this.homeLat, required this.homeLng});
  final double homeLat;
  final double homeLng;

  @override
  State<IncidentHistorySection> createState() => _IncidentHistorySectionState();
}

class _HistoryItem {
  _HistoryItem({
    required this.when,
    required this.type,
    required this.title,
    required this.source,
    required this.point,
    this.areaId,
    this.mine = false,
    this.home = false,
    this.city,
    this.alarm,
    this.details,
    this.reference,
    this.monthOnly = false,
    this.approxLocation = false,
    this.verified = true,
  });
  final DateTime when;
  final String type; // FIRE, SMOKE, FLAME, GAS_LEAK, ELECTRICAL, OTHER
  final String title; // location (area records) or room (this home)
  final String source; // PyroGuard, BFP, News, Resident, Barangay
  final LatLng point;
  final int? areaId; // set for area incidents
  final bool mine; // added by this user (can delete)
  final bool home; // this home's own PyroGuard incident
  final String? city;
  final String? alarm;
  final String? details;
  final String? reference;
  final bool monthOnly;
  final bool approxLocation;
  final bool verified;

  _HistoryItem asFire() => _HistoryItem(
      when: when, type: 'FIRE', title: title, source: source, point: point, mine: mine, home: home);
}

class _IncidentHistorySectionState extends State<IncidentHistorySection> {
  static const _proneRadiusM = 500.0;
  static const _distance = Distance();
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static const _monthsLong = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December'
  ];

  final _map = MapController();
  int _days = 0; // 30, 365, 1825, 0 = all time
  String _city = 'All'; // All, or a city name from the records
  bool _loading = true;
  String? _error;
  bool _pickMode = false;
  List<_HistoryItem> _all = const [];

  LatLng get _home => LatLng(widget.homeLat, widget.homeLng);

  List<String> get _cities {
    final set = <String>{for (final i in _all) if (i.city != null && i.city!.isNotEmpty) i.city!};
    return set.toList()..sort();
  }

  /// Items shown in the map and timeline (city filter applied).
  List<_HistoryItem> get _items =>
      _city == 'All' ? _all : _all.where((i) => i.home || i.city == _city).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final db = Supabase.instance.client;
    final uid = db.auth.currentUser?.id;
    final since = _days == 0
        ? DateTime.utc(2000)
        : DateTime.now().toUtc().subtract(Duration(days: _days));
    final items = <_HistoryItem>[];
    String? error;
    try {
      // 1) This home's own hazard readings -> grouped into incidents.
      final rows = await db
          .from('pyroguard_room_sensor_readings')
          .select('controller_device_id,room_key,fire_confirmed,smoke_status,flame_detected,received_at')
          .or('fire_confirmed.eq.true,smoke_status.eq.ALARM,flame_detected.eq.true')
          .gte('received_at', since.toIso8601String())
          .order('received_at', ascending: true)
          .limit(1000);
      final lastByRoom = <String, DateTime>{};
      final openIndexByRoom = <String, int>{};
      for (final raw in rows as List) {
        final r = Map<String, dynamic>.from(raw as Map);
        final when = DateTime.tryParse('${r['received_at']}')?.toLocal();
        if (when == null) continue;
        final controller = '${r['controller_device_id'] ?? ''}';
        final room = '${r['room_key'] ?? ''}';
        final key = '$controller/$room';
        final type = r['fire_confirmed'] == true
            ? 'FIRE'
            : '${r['smoke_status']}'.toUpperCase() == 'ALARM'
                ? 'SMOKE'
                : 'FLAME';
        final last = lastByRoom[key];
        lastByRoom[key] = when;
        // Readings less than 10 minutes apart in the same room = one incident.
        if (last != null && when.difference(last).inMinutes < 10 && openIndexByRoom[key] != null) {
          final i = openIndexByRoom[key]!;
          if (type == 'FIRE' && items[i].type != 'FIRE') items[i] = items[i].asFire();
          continue;
        }
        openIndexByRoom[key] = items.length;
        items.add(_HistoryItem(
          when: when,
          type: type,
          title: '${RoomSensorService.label(controller, room)} (this home)',
          source: 'PyroGuard',
          point: _home,
          home: true,
        ));
      }
    } catch (e) {
      error = 'Home history unavailable: $e';
    }
    try {
      // 2) Past fires in the area (shared history for every account).
      var q = db.from('pyroguard_area_incidents').select(
          'id,reported_by,latitude,longitude,occurred_on,incident_type,description,source,'
          'city,location_text,alarm_level,details,reference,date_precision,location_approx,verified');
      if (_days != 0) {
        q = q.gte('occurred_on', since.toIso8601String().substring(0, 10));
      }
      final rows = await q.order('occurred_on', ascending: false).limit(500);
      for (final raw in rows as List) {
        final r = Map<String, dynamic>.from(raw as Map);
        final lat = (r['latitude'] as num?)?.toDouble();
        final lng = (r['longitude'] as num?)?.toDouble();
        final when = DateTime.tryParse('${r['occurred_on']}');
        if (lat == null || lng == null || when == null) continue;
        String? text(String k) {
          final v = '${r[k] ?? ''}'.trim();
          return v.isEmpty ? null : v;
        }

        final desc = text('description');
        items.add(_HistoryItem(
          when: when,
          type: '${r['incident_type'] ?? 'FIRE'}',
          title: text('location_text') ?? desc ?? 'Reported incident',
          source: '${r['source'] ?? 'Resident'}',
          point: LatLng(lat, lng),
          areaId: (r['id'] as num?)?.toInt(),
          mine: uid != null && r['reported_by'] == uid,
          city: text('city'),
          alarm: text('alarm_level'),
          details: text('details') ?? (text('location_text') != null ? desc : null),
          reference: text('reference'),
          monthOnly: r['date_precision'] == 'month',
          approxLocation: r['location_approx'] == true,
          verified: r['verified'] != false,
        ));
      }
    } catch (e) {
      error = '${error == null ? '' : '$error\n'}Area history unavailable: $e';
    }
    items.sort((a, b) => b.when.compareTo(a.when));
    if (!mounted) return;
    setState(() {
      _all = items;
      _error = error;
      _loading = false;
      if (_city != 'All' && !_cities.contains(_city)) _city = 'All';
    });
  }

  /// Incidents (home + area) within 500 m of the home.
  int get _nearbyCount =>
      _items.where((i) => _distance.as(LengthUnit.Meter, _home, i.point) <= _proneRadiusM).length;

  ({String label, Color color, String hint}) get _risk {
    final n = _nearbyCount;
    if (n >= 3) {
      return (label: 'HIGH', color: AppColors.red,
          hint: '$n incidents within 500 m of your home: fire-prone area. Keep exits clear and check sensors monthly.');
    }
    if (n >= 1) {
      return (label: 'MODERATE', color: AppColors.amber,
          hint: '$n incident${n == 1 ? '' : 's'} within 500 m of your home in this period.');
    }
    return (label: 'LOW', color: AppColors.green, hint: 'No recorded incidents within 500 m of your home in this period.');
  }

  Color _typeColor(String type) => switch (type) {
        'FIRE' => AppColors.red,
        'SMOKE' || 'GAS_LEAK' => AppColors.orange,
        'FLAME' => AppColors.amber,
        'ELECTRICAL' => AppColors.amber,
        _ => AppColors.maroonMid,
      };

  IconData _typeIcon(String type) => switch (type) {
        'FIRE' || 'FLAME' => Icons.local_fire_department_rounded,
        'SMOKE' => Icons.cloud_rounded,
        'GAS_LEAK' => Icons.gas_meter_outlined,
        'ELECTRICAL' => Icons.electrical_services_rounded,
        _ => Icons.report_gmailerrorred_rounded,
      };

  String _date(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';
  String _itemDate(_HistoryItem i) =>
      i.monthOnly ? '${_monthsLong[i.when.month - 1]} ${i.when.year}' : _date(i.when);

  String _away(_HistoryItem i) {
    final m = _distance.as(LengthUnit.Meter, _home, i.point);
    return m < 1000 ? '${m.round()} m away' : '${(m / 1000).toStringAsFixed(1)} km away';
  }

  /// Short one-line meta: date · alarm · city (or source).
  String _meta(_HistoryItem i) => [
        _itemDate(i),
        if (i.alarm != null) i.alarm!,
        if (i.home) 'PyroGuard sensors' else (i.city ?? i.source),
      ].join(' · ');

  void _fitAll() {
    final pts = [_home, for (final i in _items) i.point];
    if (pts.length < 2) {
      _map.move(_home, 15);
      return;
    }
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.all(36),
      maxZoom: 16,
    ));
  }

  Future<void> _addAt(LatLng point) async {
    setState(() => _pickMode = false);
    final desc = TextEditingController();
    final place = TextEditingController();
    var type = 'FIRE';
    var source = 'BFP';
    var date = DateTime.now();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Add past incident'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Map point: ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary(ctx))),
              const SizedBox(height: 10),
              TextField(
                controller: place,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Location (street / barangay)'),
              ),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final t in const ['FIRE', 'SMOKE', 'GAS_LEAK', 'ELECTRICAL', 'OTHER'])
                  ChoiceChip(
                    label: Text(t.replaceAll('_', ' ')),
                    selected: type == t,
                    onSelected: (_) => setD(() => type = t),
                  ),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final s in const ['BFP', 'Barangay', 'News', 'Resident'])
                  ChoiceChip(
                    label: Text(s),
                    selected: source == s,
                    onSelected: (_) => setD(() => source = s),
                  ),
              ]),
              const SizedBox(height: 10),
              OutlinedButton(
                child: Text('Date: ${_date(date)}'),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null) setD(() => date = picked);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: desc,
                maxLength: 300,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'What happened? (e.g. "Residential fire, 2nd alarm")',
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        );
      }),
    );
    if (saved != true) return;
    try {
      await Supabase.instance.client.from('pyroguard_area_incidents').insert({
        'latitude': point.latitude,
        'longitude': point.longitude,
        'occurred_on': date.toIso8601String().substring(0, 10),
        'incident_type': type,
        'source': source,
        'description': desc.text.trim(),
        if (place.text.trim().isNotEmpty) 'location_text': place.text.trim(),
      });
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save the incident: $e')));
      }
    }
  }

  Future<void> _delete(_HistoryItem item) async {
    if (item.areaId == null) return;
    try {
      await Supabase.instance.client.from('pyroguard_area_incidents').delete().eq('id', item.areaId!);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      }
    }
  }

  /// Full details of one incident in a bottom sheet.
  void _showDetails(_HistoryItem i) {
    final c = _typeColor(i.type);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppTheme.isDark(context) ? AppColors.darkCard : Colors.white,
      builder: (ctx) {
        final primary = AppTheme.textPrimary(ctx);
        final secondary = AppTheme.textSecondary(ctx);
        Widget row(IconData icon, String label, String value) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 100, child: Text(label, style: TextStyle(color: secondary, fontSize: 12.5))),
                Expanded(
                  child: Text(value,
                      style: TextStyle(color: primary, fontSize: 13, fontWeight: FontWeight.w600, height: 1.35)),
                ),
              ]),
            );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * .8),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  PgDot(c, size: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(i.title, style: TextStyle(color: primary, fontSize: 16, fontWeight: FontWeight.w800)),
                      Text(_meta(i), style: TextStyle(color: secondary, fontSize: 12.5)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 16),
                if (i.details != null) ...[
                  Text(i.details!, style: TextStyle(color: primary, fontSize: 13.5, height: 1.45)),
                  const SizedBox(height: 16),
                ],
                row(Icons.event_rounded, 'Date', _itemDate(i)),
                row(Icons.place_outlined, 'Location',
                    [i.title, if (i.city != null) i.city!].join(', ')),
                if (i.alarm != null) row(Icons.campaign_outlined, 'Alarm level', i.alarm!),
                row(Icons.social_distance_rounded, 'Distance', i.home ? 'At your home' : '${_away(i)} from your home'),
                row(Icons.source_outlined, 'Source', i.reference ?? i.source),
                if (i.approxLocation || (i.areaId != null && !i.home))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      i.approxLocation
                          ? 'Map point is approximate: the exact barangay is still to be confirmed.'
                          : 'Map point marks the barangay / street, not the exact house.',
                      style: TextStyle(color: secondary, fontSize: 11.5),
                    ),
                  ),
                if (!i.verified)
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.amber.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.amber.withValues(alpha: .45)),
                    ),
                    child: Text('Source to confirm: no exact news article matched this date yet.',
                        style: TextStyle(color: AppTheme.statusForeground(ctx, AppColors.amber), fontSize: 12)),
                  ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    child: OutlinedButton(
                      child: const Text('Show on map'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _map.move(i.point, 16);
                      },
                    ),
                  ),
                  if (i.mine) ...[
                    const SizedBox(width: 10),
                    TextButton(
                      child: const Text('Delete'),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _delete(i);
                      },
                    ),
                  ],
                ]),
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
      );

  @override
  Widget build(BuildContext context) {
    final risk = _risk;
    final items = _items;
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final areaCount = items.where((i) => !i.home).length;
    final homeCount = items.where((i) => i.home).length;

    // Timeline rows grouped by year.
    final rows = <Widget>[];
    int? year;
    for (final i in items) {
      if (i.when.year != year) {
        year = i.when.year;
        final n = items.where((x) => x.when.year == year).length;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(children: [
            Text('$year', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(width: 8),
            Expanded(child: Divider(color: AppTheme.border(context), height: 1)),
            const SizedBox(width: 8),
            Text('$n incident${n == 1 ? '' : 's'}', style: TextStyle(color: secondary, fontSize: 11)),
          ]),
        ));
      }
      final c = _typeColor(i.type);
      rows.add(InkWell(
        onTap: () => _showDetails(i),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 4), child: PgDot(c)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(i.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 2),
                Text(_meta(i), style: TextStyle(color: secondary, fontSize: 11.5)),
                if (i.details != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(i.details!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: secondary, fontSize: 11.5)),
                  ),
              ]),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(i.home ? 'Home' : _away(i).replaceAll(' away', ''),
                  style: TextStyle(color: secondary, fontSize: 11)),
            ),
          ]),
        ),
      ));
    }

    return PgCard(
      padding: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: PgHeader(
            icon: Icons.history,
            title: 'Fire Incident History',
            subtitle: 'Past fires around your home from BFP and news reports, plus incidents detected by your PyroGuard sensors.',
            actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20))],
          ),
        ),
        // Filters: period and area on ONE line (scrolls sideways if narrow).
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            for (final d in const [(30, 'Last 30 days'), (365, 'Last year'), (1825, 'Last 5 years'), (0, 'All time')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _chip(d.$2, _days == d.$1, () {
                  setState(() => _days = d.$1);
                  _load();
                }),
              ),
            if (_cities.isNotEmpty) ...[
              Container(
                width: 1,
                height: 26,
                margin: const EdgeInsets.only(left: 4, right: 12),
                color: AppTheme.border(context),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _chip('All areas', _city == 'All', () => setState(() => _city = 'All')),
              ),
              for (final c in _cities)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _chip(c, _city == c, () => setState(() => _city = c)),
                ),
            ],
          ]),
        ),
        // Summary: counts + area risk.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Row(children: [
            Expanded(
              child: Text(
                '$areaCount area incident${areaCount == 1 ? '' : 's'} · $homeCount at your home\n${risk.hint}',
                style: TextStyle(color: secondary, fontSize: 12, height: 1.4),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: risk.color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(99),
                border: Border.all(color: risk.color.withValues(alpha: .5)),
              ),
              child: Text('Risk: ${risk.label}',
                  style: TextStyle(
                      color: AppTheme.statusForeground(context, risk.color),
                      fontWeight: FontWeight.w800,
                      fontSize: 12)),
            ),
          ]),
        ),
        // Map
        SizedBox(
          height: 320,
          child: Stack(children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: _home,
                initialZoom: 14,
                onTap: (_, point) {
                  if (_pickMode) _addAt(point);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.pyroguard.app',
                ),
                // Overlapping translucent circles get darker = fire-prone zone.
                CircleLayer(circles: [
                  CircleMarker(
                    point: _home,
                    radius: _proneRadiusM,
                    useRadiusInMeter: true,
                    color: risk.color.withValues(alpha: .06),
                    borderColor: risk.color.withValues(alpha: .6),
                    borderStrokeWidth: 1.5,
                  ),
                  for (final i in items.where((i) => !i.home))
                    CircleMarker(
                      point: i.point,
                      radius: 150,
                      useRadiusInMeter: true,
                      color: _typeColor(i.type).withValues(alpha: .14),
                      borderColor: Colors.transparent,
                    ),
                ]),
                MarkerLayer(markers: [
                  for (final i in items.where((i) => !i.home))
                    Marker(
                      point: i.point,
                      width: 28,
                      height: 28,
                      child: GestureDetector(
                        onTap: () => _showDetails(i),
                        child: Tooltip(
                          message: '${i.title}\n${_meta(i)}',
                          child: Container(
                            decoration: BoxDecoration(
                              color: _typeColor(i.type),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                            ),
                            child: Icon(_typeIcon(i.type), size: 15, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  Marker(
                    point: _home,
                    width: 44,
                    height: 44,
                    child: Tooltip(
                      message: 'Your home: $homeCount PyroGuard incident${homeCount == 1 ? '' : 's'}',
                      child: const Icon(Icons.home, color: AppColors.orange, size: 34),
                    ),
                  ),
                ]),
              ],
            ),
            Positioned(
              right: 8,
              top: 8,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _pickMode ? AppColors.maroonMid : AppColors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () => setState(() => _pickMode = !_pickMode),
                child: Text(_pickMode ? 'Cancel' : 'Add past incident'),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _MapButton(icon: Icons.home_outlined, tooltip: 'Center on home', onTap: () => _map.move(_home, 15)),
                const SizedBox(height: 6),
                _MapButton(icon: Icons.zoom_out_map, tooltip: 'Show all incidents', onTap: _fitAll),
              ]),
            ),
            if (_pickMode)
              Positioned(
                left: 8,
                bottom: 8,
                right: 60,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('Tap the map where the past fire happened.',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                ),
              ),
            if (_loading)
              const Positioned(
                left: 0, right: 0, top: 0,
                child: LinearProgressIndicator(color: AppColors.orange),
              ),
          ]),
        ),
        // Timeline
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Text('Timeline', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
            const SizedBox(width: 6),
            Text('(${items.length}) · tap an entry for details', style: TextStyle(color: secondary, fontSize: 11.5)),
          ]),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 11)),
          ),
        if (!_loading && items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'No incidents in this period. Choose "All time" or add a past fire with "Add past incident".',
              style: TextStyle(color: secondary, fontSize: 12),
            ),
          ),
        // Timeline scrolls inside its own box so the page stays tidy.
        if (items.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 10),
              children: rows,
            ),
          ),
      ]),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: AppTheme.isDark(context) ? AppColors.darkCard : Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        child: IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 20, color: AppTheme.textPrimary(context)),
          onPressed: onTap,
        ),
      );
}
