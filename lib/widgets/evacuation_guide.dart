import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide Path; // latlong2 also has a Path class
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/indoor_locator.dart';
import '../services/room_sensor_service.dart';
import '../theme.dart';

/// Home floor layout + animated evacuation route, shared by the Map page
/// (Home Layout panel) and the verified-fire pop-up.
/// Positions and sizes are in meters from the top-left corner of the house.
class LayoutItem {
  LayoutItem({
    required this.key,
    required this.kind,
    required this.label,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.controller,
    this.room,
    this.doorX,
    this.doorY,
  });
  final String key;
  final String kind; // room | exit
  String label;
  double x, y, w, h;
  final String? controller;
  final String? room;

  /// Doorway of a walled room (just outside it). Null for open-plan zones.
  double? doorX, doorY;
  Offset? get door => doorX == null || doorY == null ? null : Offset(doorX!, doorY!);

  double get area => w * h;
  Offset get center => Offset(x + w / 2, y + h / 2);
  Rect get rect => Rect.fromLTWH(x, y, w, h);
  bool contains(Offset p) => p.dx >= x - .05 && p.dx <= x + w + .05 && p.dy >= y - .05 && p.dy <= y + h + .05;

  Map<String, dynamic> toRow() => {
        'item_key': key,
        'kind': kind,
        'label': label,
        'x_m': x,
        'y_m': y,
        'w_m': w,
        'h_m': h,
        'controller_id': controller,
        'room_key': room,
        'door_x_m': doorX,
        'door_y_m': doorY,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  static LayoutItem fromRow(Map<String, dynamic> r) => LayoutItem(
        key: '${r['item_key']}',
        kind: '${r['kind']}',
        label: '${r['label']}',
        x: (r['x_m'] as num).toDouble(),
        y: (r['y_m'] as num).toDouble(),
        w: (r['w_m'] as num).toDouble(),
        h: (r['h_m'] as num).toDouble(),
        controller: r['controller_id'] as String?,
        room: r['room_key'] as String?,
        doorX: (r['door_x_m'] as num?)?.toDouble(),
        doorY: (r['door_y_m'] as num?)?.toDouble(),
      );
}

/// Sensors installed in each room (from the firmware pin map).
const Map<String, List<String>> kRoomSensors = {
  'entrance': ['DHT22 temp/humidity', 'MQ-2 smoke/gas', 'IR flame', 'Buzzer', 'Reed switch (Entrance door)', 'Camera 1 + pan/tilt'],
  'sala': ['DHT22 temp/humidity', 'MQ-2 smoke/gas', 'IR flame', 'Buzzer', 'Reed switch (Sala window)'],
  'kitchen': ['DHT22 temp/humidity', 'MQ-2 smoke/gas', 'IR flame', 'Buzzer', 'Reed switch (Fire exit door)'],
  'bedroom': ['DHT22 temp/humidity', 'MQ-2 smoke/gas', 'IR flame', 'Buzzer', 'Reed switch (Bedroom window)'],
};

/// The team's floor plan drawing (assets/images/floorplan.png), cropped so the
/// inside top-left corner of the house is at [kPlanOffsetM] and 1 m = 100 px
/// (scaled from the car in the drawing, about 4.3 m long).
const kFloorPlanAsset = 'assets/images/floorplan.png';
const kPlanOffsetM = Offset(1.10, 1.17);
const kPlanSizeM = Size(9.70, 13.60); // full drawing incl. garage and garden

/// The house from the floor plan drawing (inside measurements, meters):
/// open kitchen / dining / sala with the entrance, plus the walled bedroom
/// and bathroom. Exits: main door (front) and the side door (fire exit).
List<LayoutItem> defaultLayout() => [
      LayoutItem(key: 'kitchen', kind: 'room', label: 'Kitchen', x: 0, y: 0, w: 7.52, h: 1.94,
          controller: 'ESP32-002', room: 'kitchen'),
      LayoutItem(key: 'bedroom', kind: 'room', label: 'Bedroom', x: 0, y: 2.04, w: 2.93, h: 3.0,
          controller: 'ESP32-002', room: 'bedroom', doorX: 3.25, doorY: 3.74),
      LayoutItem(key: 'bathroom', kind: 'room', label: 'Bathroom', x: 0, y: 5.17, w: 2.93, h: 2.47,
          doorX: 3.25, doorY: 6.29),
      LayoutItem(key: 'dining', kind: 'room', label: 'Dining', x: 3.06, y: 1.94, w: 4.46, h: 2.06),
      LayoutItem(key: 'entrance', kind: 'room', label: 'Entrance', x: 3.06, y: 4.0, w: 1.6, h: 3.64,
          controller: 'ESP32-001', room: 'entrance'),
      LayoutItem(key: 'sala', kind: 'room', label: 'Sala', x: 4.66, y: 4.0, w: 2.86, h: 3.64,
          controller: 'ESP32-001', room: 'sala'),
      LayoutItem(key: 'exit_main', kind: 'exit', label: 'Main door', x: 3.31, y: 7.55, w: .83, h: .3),
      LayoutItem(key: 'exit_side', kind: 'exit', label: 'Side door (fire exit)', x: 0, y: .9, w: .25, h: .8),
    ];

class HomeLayoutData {
  HomeLayoutData({required this.items, required this.saved, this.home, this.ownHome = false});
  final List<LayoutItem> items;
  final bool saved;
  final Map<String, dynamic>? home;
  final bool ownHome;

  LatLng? get homePoint {
    final lat = (home?['latitude'] as num?)?.toDouble(), lng = (home?['longitude'] as num?)?.toDouble();
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  LatLng? get evacPoint {
    final lat = (home?['evac_latitude'] as num?)?.toDouble(), lng = (home?['evac_longitude'] as num?)?.toDouble();
    return lat == null || lng == null ? null : LatLng(lat, lng);
  }

  String get evacName {
    final n = '${home?['evac_name'] ?? ''}'.trim();
    return n.isEmpty ? 'the evacuation area' : n;
  }

  /// "350 m away · about 6 min walk"
  String? evacDistance([LatLng? from]) {
    final h = from ?? homePoint, e = evacPoint;
    if (h == null || e == null) return null;
    final m = const Distance().as(LengthUnit.Meter, h, e);
    final minutes = math.max(1, (m * 1.3 / 1.2 / 60).round());
    return '${m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km'} away · about $minutes min walk';
  }
}

/// Saved layout (or the sample) plus the home row (address, evacuation area).
Future<HomeLayoutData> loadHomeLayout() async {
  final db = Supabase.instance.client;
  final uid = db.auth.currentUser?.id ?? '';
  var items = defaultLayout();
  var saved = false;
  try {
    final rows = await db.from('pyroguard_home_layout').select().order('item_key');
    final list = [for (final r in rows as List) LayoutItem.fromRow(Map<String, dynamic>.from(r as Map))];
    if (list.isNotEmpty) {
      items = list;
      saved = true;
    }
  } catch (_) {}
  Map<String, dynamic>? home;
  var own = false;
  try {
    var row = await db.from('homes').select().eq('user_id', uid).maybeSingle();
    own = row != null;
    if (row == null) {
      final m = await db.from('pyroguard_home_members').select('home_id')
          .eq('user_id', uid).eq('membership_status', 'approved').limit(1);
      if (m.isNotEmpty) row = await db.from('homes').select().eq('id', m.first['home_id']).maybeSingle();
    }
    home = row == null ? null : Map<String, dynamic>.from(row);
  } catch (_) {}
  return HomeLayoutData(items: items, saved: saved, home: home, ownHome: own);
}

/// 2 = verified/confirmed fire, 1 = smoke or flame warning, 0 = clear.
int liveHazard(LayoutItem room) {
  final s = RoomSensorService.instance;
  if (room.controller == null || room.room == null) return 0;
  final v = s.verifiedFireEmergency;
  if (v != null && v.controller == room.controller && v.room == room.room) return 2;
  if (!s.fresh(room.controller!, room.room!)) return 0;
  final r = s.reading(room.controller!, room.room!);
  if (r == null) return 0;
  if (RoomSensorService.confirmedFire(r)) return 2;
  if ('${r['smoke_status']}'.toUpperCase() == 'ALARM' || r['flame_detected'] == true) return 1;
  return 0;
}

// ── Route planning ──────────────────────────────────────────────────────
bool _crosses(List<Offset> path, Iterable<LayoutItem> blocked, LayoutItem? start) {
  for (var i = 0; i < path.length - 1; i++) {
    for (var t = .05; t <= .97; t += .03) {
      final p = Offset.lerp(path[i], path[i + 1], t)!;
      for (final b in blocked) {
        if (start != null && b.key == start.key) continue; // leaving your own room is fine
        if (b.rect.deflate(.05).contains(p)) return true;
      }
    }
  }
  return false;
}

double _length(List<Offset> p) {
  var d = 0.0;
  for (var i = 0; i < p.length - 1; i++) {
    d += (p[i + 1] - p[i]).distance;
  }
  return d;
}

class EvacRoute {
  EvacRoute(this.room, this.exit, this.path, this.clear);
  final LayoutItem room;
  final LayoutItem exit;
  final List<Offset> path; // meters
  final bool clear; // does not pass through a room with fire
}

/// Best route from each room to an exit: through the room's door (walled
/// rooms), never through another walled room, and avoiding rooms with fire
/// and exits next to the fire.
Map<String, EvacRoute> planRoutes(List<LayoutItem> items, Map<String, int> hazard) {
  final rooms = items.where((i) => i.kind == 'room').toList();
  final exits = items.where((i) => i.kind == 'exit').toList();
  final fire = rooms.where((r) => (hazard[r.key] ?? 0) > 0).toList();
  final walled = rooms.where((r) => r.door != null).toList();
  final out = <String, EvacRoute>{};
  for (final r in rooms) {
    EvacRoute? best;
    var bestScore = double.infinity;
    final head = [r.center, if (r.door != null) r.door!];
    final from = head.last;
    for (final e in exits) {
      final exitInFire = fire.any((f) => f.key != r.key && f.rect.inflate(.3).contains(e.center));
      final t = e.center;
      for (final tail in [
        [t],
        [Offset(t.dx, from.dy), t],
        [Offset(from.dx, t.dy), t],
      ]) {
        final path = [...head, ...tail];
        // Walls: after the doorway a route may not cut through any walled
        // room (not even back through your own).
        final throughWall = _crosses(path.sublist(head.length - 1), walled, null);
        final clear = !exitInFire && !_crosses(path, fire, r);
        // Prefer straight corridors over diagonal shortcuts across furniture.
        final diagonal = tail.length == 1 && (from.dx - t.dx).abs() > .4 && (from.dy - t.dy).abs() > .4;
        final score = _length(path) + (clear ? 0 : 1000) + (throughWall ? 100 : 0) + (diagonal ? 2.0 : 0);
        if (best == null || score < bestScore) {
          best = EvacRoute(r, e, path, clear);
          bestScore = score;
        }
      }
    }
    if (best != null) out[r.key] = best;
  }
  return out;
}

/// Written steps for the guide.
List<String> evacuationSteps(List<LayoutItem> items, Map<String, int> hazard, Map<String, EvacRoute> routes,
    {String? evacName, String? evacDistance, String? youRoom}) {
  final rooms = items.where((i) => i.kind == 'room').toList();
  final fire = rooms.where((r) => (hazard[r.key] ?? 0) > 0).toList();
  final steps = <String>[];
  LayoutItem? you;
  for (final r in rooms) {
    if (r.key == youRoom) you = r;
  }
  final yourRoute = you == null ? null : routes[you.key];
  if (you != null && yourRoute != null) {
    final inFire = fire.any((f) => f.key == you.key);
    if (fire.isNotEmpty) {
      steps.add('${fire.any((f) => hazard[f.key] == 2) ? 'FIRE' : 'SMOKE / FLAME WARNING'} in the '
          '${fire.map((f) => f.label).join(' and ')}.');
    }
    steps.add([
      'You are in the ${you.label}.',
      if (inFire) 'Leave now and stay low under the smoke.',
      if (you.door != null) 'Go out through the ${you.label.toLowerCase()} door,',
      '${you.door != null ? 'then ' : ''}follow the green line to the ${yourRoute.exit.label}.',
      if (!yourRoute.clear) 'Careful: the way passes near the fire; cover your nose and move fast.',
    ].join(' '));
    steps.add(evacName == null
        ? 'Once outside, move away from the house and call the BFP.'
        : 'Once outside, go to $evacName${evacDistance == null ? '' : ' ($evacDistance)'} and call the BFP.');
    return steps;
  }
  if (fire.isEmpty) {
    steps.add('No fire detected. The green lines show the nearest exit from each room.');
  } else {
    final level = fire.any((f) => hazard[f.key] == 2) ? 'FIRE' : 'SMOKE / FLAME WARNING';
    steps.add('$level in the ${fire.map((f) => f.label).join(' and ')}. Do not go near this area.');
    for (final r in rooms) {
      final route = routes[r.key];
      if (route == null) continue;
      final inFire = fire.any((f) => f.key == r.key);
      steps.add(inFire
          ? 'If you are in the ${r.label}: leave now through the ${route.exit.label}. Stay low under the smoke.'
          : 'From the ${r.label}: use the ${route.exit.label}${route.clear ? '' : ' (careful: path passes near the fire)'}.');
    }
  }
  steps.add(evacName == null
      ? 'Once outside, move away from the house and call the BFP.'
      : 'Once outside, go to $evacName${evacDistance == null ? '' : ' ($evacDistance)'} and call the BFP.');
  return steps;
}

// ── Animated floor plan ─────────────────────────────────────────────────
/// The floor plan drawing with live overlays: rooms with fire / warning
/// pulsing, a FIRE marker, a YOU marker for the selected room, and moving
/// green arrows along the safe route to the exit.
class EvacuationPlanView extends StatefulWidget {
  const EvacuationPlanView({
    super.key,
    required this.items,
    required this.hazard,
    this.onTapItem,
    this.flameRangeM,
    this.smokeRangeM,
    this.youRoom,
    this.animate = true,
  });
  final List<LayoutItem> items;
  final Map<String, int> hazard;
  final void Function(LayoutItem item)? onTapItem;
  final double? flameRangeM;
  final double? smokeRangeM;
  final String? youRoom;
  final bool animate;

  @override
  State<EvacuationPlanView> createState() => _EvacuationPlanViewState();
}

class _EvacuationPlanViewState extends State<EvacuationPlanView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _anim.repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final routes = planRoutes(items, widget.hazard);
    // Whole drawing always visible: never wider than 560 px and never taller
    // than about 70% of the screen, centered in its panel.
    final aspect = kPlanSizeM.width / kPlanSizeM.height;
    final maxW = [560.0, MediaQuery.sizeOf(context).height * .70 * aspect].reduce((a, b) => a < b ? a : b);
    return Center(
      child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(builder: (context, c) {
        final scale = c.maxWidth / kPlanSizeM.width;
        Offset toM(Offset px) => px / scale - kPlanOffsetM;
        return GestureDetector(
          onTapUp: widget.onTapItem == null
              ? null
              : (d) {
                  final m = toM(d.localPosition);
                  for (final i in [...items.where((i) => i.kind == 'exit'), ...items.where((i) => i.kind == 'room')]) {
                    if (i.contains(m)) {
                      widget.onTapItem!(i);
                      return;
                    }
                  }
                },
          child: Stack(fit: StackFit.expand, children: [
            // The team's floor plan drawing (white paper, also in dark mode).
            Container(color: Colors.white, child: Image.asset(kFloorPlanAsset, fit: BoxFit.fill)),
            AnimatedBuilder(
              animation: _anim,
              builder: (context, _) => CustomPaint(
                painter: _PlanPainter(
                  items: items,
                  hazard: widget.hazard,
                  routes: routes,
                  scale: scale,
                  t: _anim.value,
                  flameR: widget.flameRangeM,
                  smokeR: widget.smokeRangeM,
                  youRoom: widget.youRoom,
                ),
              ),
            ),
          ]),
        );
      }),
      ),
      ),
      ),
    );
  }
}

class _PlanPainter extends CustomPainter {
  _PlanPainter({
    required this.items,
    required this.hazard,
    required this.routes,
    required this.scale,
    required this.t,
    required this.flameR,
    required this.smokeR,
    required this.youRoom,
  });
  final List<LayoutItem> items;
  final Map<String, int> hazard;
  final Map<String, EvacRoute> routes;
  final double scale, t;
  final double? flameR, smokeR;
  final String? youRoom;

  static const _ink = Color(0xFF1F2937);
  static const _green = Color(0xFF15803D);
  static const _you = Color(0xFF1D4ED8);

  Offset px(Offset m) => (m + kPlanOffsetM) * scale;
  Rect rpx(LayoutItem i) => Rect.fromPoints(px(Offset(i.x, i.y)), px(Offset(i.x + i.w, i.y + i.h)));

  void chip(Canvas c, String s, Offset at, {Color bg = Colors.white, Color fg = _ink, double size = 10.5}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: fg, fontSize: size, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 200);
    final r = RRect.fromRectAndRadius(
        Rect.fromCenter(center: at, width: tp.width + 10, height: tp.height + 5), const Radius.circular(6));
    c.drawRRect(r, Paint()..color = bg.withValues(alpha: .92));
    tp.paint(c, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pulse = .30 + .22 * math.sin(t * math.pi * 2).abs();
    final rooms = items.where((i) => i.kind == 'room').toList();

    for (final r in rooms) {
      final rect = rpx(r);
      final h = hazard[r.key] ?? 0;
      if (h > 0) {
        canvas.drawRect(rect, Paint()..color = (h == 2 ? AppColors.red : AppColors.amber).withValues(alpha: pulse));
      } else if (r.key == youRoom) {
        canvas.drawRect(rect, Paint()..color = _you.withValues(alpha: .10));
      }
      if (h == 0 && (flameR != null || smokeR != null) && r.controller != null) {
        canvas.save();
        canvas.clipRect(rect);
        if (smokeR != null) {
          canvas.drawCircle(rect.center, smokeR! * scale, Paint()..color = Colors.blueGrey.withValues(alpha: .08));
        }
        if (flameR != null) {
          canvas.drawCircle(rect.center, flameR! * scale, Paint()..color = AppColors.orange.withValues(alpha: .10));
        }
        canvas.restore();
      }
      canvas.drawRect(
          rect,
          Paint()
            ..color = (h > 0 ? AppColors.red : const Color(0xFF94A3B8)).withValues(alpha: h > 0 ? .9 : .45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = h > 0 ? 2.5 : 1);
      chip(canvas, r.label, rect.topLeft + Offset(_textW(r.label) / 2 + 9, 11));
    }

    // Routes: only yours when you picked a room; otherwise all, faded.
    for (final route in routes.values) {
      final mine = youRoom == null || route.room.key == youRoom;
      if (youRoom != null && !mine) continue;
      final pts = route.path.map(px).toList();
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      final color = (route.clear ? _green : AppColors.amber).withValues(alpha: youRoom == null ? .75 : 1);
      final dash = Paint()
        ..color = color
        ..strokeWidth = youRoom == null ? 3 : 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (final m in path.computeMetrics()) {
        const on = 10.0, off = 7.0;
        var d = -(1 - t) * (on + off);
        while (d < m.length) {
          final a = math.max(0.0, d), b = math.min(m.length, d + on);
          if (b > a) canvas.drawPath(m.extractPath(a, b), dash);
          d += on + off;
        }
        final end = m.getTangentForOffset(m.length);
        if (end != null) _arrowHead(canvas, end, color, youRoom == null ? 9 : 13);
      }
    }

    // Exits.
    for (final e in items.where((i) => i.kind == 'exit')) {
      final rect = rpx(e).inflate(3);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = _green);
      final below = rect.center.dy > size.height * .6;
      final left = rect.center.dx < size.width * .2;
      chip(canvas, 'EXIT', rect.center + Offset(left ? 24 : 0, below ? 16 : 0), bg: _green, fg: Colors.white, size: 10);
    }

    // FIRE marker(s).
    for (final r in rooms.where((r) => (hazard[r.key] ?? 0) > 0)) {
      final c = rpx(r).center;
      final h = hazard[r.key]!;
      final radius = 16 + 6 * math.sin(t * math.pi * 2).abs();
      canvas.drawCircle(c, radius + 6, Paint()..color = AppColors.red.withValues(alpha: .25));
      canvas.drawCircle(c, radius, Paint()..color = h == 2 ? AppColors.red : AppColors.amber);
      final tp = TextPainter(
        text: TextSpan(
            text: h == 2 ? 'FIRE' : 'SMOKE',
            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }

    // YOU marker.
    if (youRoom != null) {
      final r = rooms.where((r) => r.key == youRoom);
      if (r.isNotEmpty) {
        final hasFire = (hazard[r.first.key] ?? 0) > 0;
        final c = rpx(r.first).center + Offset(0, hasFire ? 34 : 0);
        canvas.drawCircle(c, 15, Paint()..color = Colors.white);
        canvas.drawCircle(c, 12, Paint()..color = _you);
        final tp = TextPainter(
          text: const TextSpan(text: 'YOU', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w900)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // 1 m scale bar.
    final y = size.height - 8;
    canvas.drawLine(Offset(8, y), Offset(8 + scale, y), Paint()..color = _ink..strokeWidth = 2);
    chip(canvas, '1 m', Offset(8 + scale / 2, y - 9), size: 9);
  }

  double _textW(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _arrowHead(Canvas c, ui.Tangent tan, Color color, double len) {
    final a = tan.angle; // counter-clockwise; the direction is (cos(-a), sin(-a))
    final p = tan.position;
    final dir = Offset(math.cos(-a), math.sin(-a));
    final left = Offset(math.cos(-a + 2.6), math.sin(-a + 2.6));
    final right = Offset(math.cos(-a - 2.6), math.sin(-a - 2.6));
    final path = Path()
      ..moveTo(p.dx + dir.dx * 3, p.dy + dir.dy * 3)
      ..lineTo(p.dx + left.dx * len, p.dy + left.dy * len)
      ..lineTo(p.dx + right.dx * len, p.dy + right.dy * len)
      ..close();
    c.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PlanPainter old) => true;
}

// ── Where the user is ───────────────────────────────────────────────────
/// The room the user said they are in (kept while the app is open).
final ValueNotifier<String?> evacuationYouRoom = ValueNotifier<String?>(null);

/// "Where are you?" chips: the guide then shows only that person's route.
class WhereAreYouChips extends StatelessWidget {
  const WhereAreYouChips({super.key, required this.items});
  final List<LayoutItem> items;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
        valueListenable: evacuationYouRoom,
        builder: (context, you, _) => Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Where are you?',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context))),
          for (final r in items.where((i) => i.kind == 'room'))
            ChoiceChip(
              label: Text(r.label),
              selected: you == r.key,
              visualDensity: VisualDensity.compact,
              onSelected: (on) => evacuationYouRoom.value = on ? r.key : null,
            ),
        ]),
      );
}

// ── Pop-up guide for a verified fire ────────────────────────────────────
/// Shown inside the verified-fire alert: the floor plan with the burning
/// room, where you are and your safe route to the exit, plus the evacuation
/// area. Appears only for a verified fire (smoke AND flame confirmed in two
/// consecutive fresh readings).
class EvacuationGuideCard extends StatefulWidget {
  const EvacuationGuideCard({super.key, required this.controller, required this.room, this.level = 2});
  final String controller;
  final String room;

  /// 2 = confirmed fire, 1 = smoke or flame warning.
  final int level;

  @override
  State<EvacuationGuideCard> createState() => _EvacuationGuideCardState();
}

class _EvacuationGuideCardState extends State<EvacuationGuideCard> {
  HomeLayoutData? _data;

  @override
  void initState() {
    super.initState();
    RoomSensorService.instance.addListener(_changed);
    evacuationYouRoom.addListener(_changed);
    loadHomeLayout().then((d) {
      if (!mounted) return;
      setState(() => _data = d);
      // Live GPS puts the user on the plan automatically.
      IndoorLocator.instance.start(homeLat: d.homePoint?.latitude, homeLng: d.homePoint?.longitude, items: d.items);
    });
  }

  @override
  void dispose() {
    RoomSensorService.instance.removeListener(_changed);
    evacuationYouRoom.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator(color: AppColors.orange));
    }
    final rooms = data.items.where((i) => i.kind == 'room');
    final hazard = {for (final r in rooms) r.key: liveHazard(r)};
    for (final r in rooms) {
      if (r.controller == widget.controller && r.room == widget.room) {
        hazard[r.key] = (hazard[r.key] ?? 0) > widget.level ? hazard[r.key]! : widget.level;
      }
    }
    final you = evacuationYouRoom.value;
    final routes = planRoutes(data.items, hazard);
    final steps = evacuationSteps(data.items, hazard, routes,
        evacName: data.evacPoint == null ? null : data.evacName, evacDistance: data.evacDistance(), youRoom: you);
    final secondary = AppTheme.textSecondary(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Evacuation guide', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppTheme.textPrimary(context))),
      const SizedBox(height: 6),
      LiveLocationBar(items: data.items),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: EvacuationPlanView(
          items: data.items,
          hazard: hazard,
          youRoom: you,
          onTapItem: (i) {
            if (i.kind == 'room') IndoorLocator.instance.userPicked(i.key);
          },
        ),
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 20,
              child: Text('${i + 1}.', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: secondary)),
            ),
            Expanded(
              child: Text(steps[i],
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: i == 0 ? FontWeight.w800 : FontWeight.w500,
                      color: i == 0 ? AppTheme.dangerForeground(context) : AppTheme.textPrimary(context))),
            ),
          ]),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          you == null
              ? 'Your room is found from your phone\'s location. If it is not shown, tap the room you are in.'
              : 'Wrong room? Tap the right one once and the app learns it.',
          style: TextStyle(fontSize: 11, color: secondary),
        ),
      ),
    ]);
  }
}
