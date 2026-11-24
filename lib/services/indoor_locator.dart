import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/evacuation_guide.dart';

enum LocatorState { off, searching, located, imprecise, away, denied }

/// Puts the user on the floor plan automatically from the phone's live GPS.
///
/// How: the home pin (homes.latitude / longitude) is the middle of the
/// house; the floor plan's top is north. Each GPS fix is turned into metres
/// east / north of the pin and placed on the plan; the room under that
/// point becomes "YOU". If the person corrects it once by tapping their real
/// room, that offset is remembered so later fixes land in the right place.
///
/// Limits (said plainly in the UI): indoor GPS is usually accurate to about
/// 5-20 m, and this house is about 7.5 x 7.6 m, so a room is chosen only
/// when the fix is good enough; otherwise the user is asked to tap.
class IndoorLocator extends ChangeNotifier {
  IndoorLocator._();
  static final instance = IndoorLocator._();

  /// A fix must be at least this accurate to choose a room.
  static const double roomAccuracyM = 12;

  /// Farther than this from the home pin = not at home.
  static const double awayM = 40;

  static const _prefDx = 'pyroguard.locator.dx', _prefDy = 'pyroguard.locator.dy';

  StreamSubscription<Position>? _sub;
  double? _homeLat, _homeLng;
  List<LayoutItem> _items = const [];
  Offset _calib = Offset.zero;
  DateTime? _manualAt;
  Offset? _raw; // plan metres before calibration

  LocatorState state = LocatorState.off;
  Offset? pointM; // calibrated position on the plan (metres)
  double? accuracyM;
  double? distanceFromHomeM;
  String? roomKey;

  bool get running => _sub != null;

  /// Starts (or retargets) live tracking for this home and layout.
  Future<void> start({required double? homeLat, required double? homeLng, required List<LayoutItem> items}) async {
    _homeLat = homeLat;
    _homeLng = homeLng;
    _items = items;
    if (homeLat == null || homeLng == null) {
      state = LocatorState.off;
      notifyListeners();
      return;
    }
    if (_sub != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _calib = Offset(prefs.getDouble(_prefDx) ?? 0, prefs.getDouble(_prefDy) ?? 0);
    } catch (_) {}
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        state = LocatorState.denied;
        notifyListeners();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        state = LocatorState.denied;
        notifyListeners();
        return;
      }
      state = LocatorState.searching;
      notifyListeners();
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
      ).listen(_onFix, onError: (_) {
        state = LocatorState.denied;
        notifyListeners();
      });
    } catch (_) {
      state = LocatorState.denied;
      notifyListeners();
    }
  }

  void updateItems(List<LayoutItem> items) {
    _items = items;
    if (_raw != null) _place();
  }

  Rect get _houseRect {
    final rooms = _items.where((i) => i.kind == 'room');
    if (rooms.isEmpty) return const Rect.fromLTWH(0, 0, 7.5, 7.6);
    var r = Rect.fromLTWH(rooms.first.x, rooms.first.y, rooms.first.w, rooms.first.h);
    for (final i in rooms) {
      r = r.expandToInclude(Rect.fromLTWH(i.x, i.y, i.w, i.h));
    }
    return r;
  }

  void _onFix(Position p) {
    final lat0 = _homeLat, lng0 = _homeLng;
    if (lat0 == null || lng0 == null) return;
    final east = (p.longitude - lng0) * 111320 * math.cos(lat0 * math.pi / 180);
    final north = (p.latitude - lat0) * 110540;
    distanceFromHomeM = math.sqrt(east * east + north * north);
    accuracyM = p.accuracy;
    final c = _houseRect.center;
    _raw = Offset(c.dx + east, c.dy - north); // plan y grows southward
    _place();
  }

  void _place() {
    final raw = _raw;
    if (raw == null) return;
    pointM = raw + _calib;
    final acc = accuracyM ?? 999;
    if ((distanceFromHomeM ?? 0) > awayM + acc) {
      state = LocatorState.away;
      roomKey = null;
    } else if (acc > roomAccuracyM) {
      state = LocatorState.imprecise;
      roomKey = null;
    } else {
      state = LocatorState.located;
      roomKey = _roomAt(pointM!);
    }
    // A room the person tapped in the last 2 minutes wins over GPS.
    final manualFresh = _manualAt != null && DateTime.now().difference(_manualAt!) < const Duration(minutes: 2);
    if (!manualFresh && state == LocatorState.located && roomKey != null && evacuationYouRoom.value != roomKey) {
      evacuationYouRoom.value = roomKey;
    }
    notifyListeners();
  }

  String? _roomAt(Offset pt) {
    final rooms = _items.where((i) => i.kind == 'room').toList();
    for (final r in rooms) {
      if (Rect.fromLTWH(r.x, r.y, r.w, r.h).contains(pt)) return r.key;
    }
    // Just outside the walls (GPS drift): nearest room within 2 m.
    String? best;
    var bestD = 2.0;
    for (final r in rooms) {
      final rect = Rect.fromLTWH(r.x, r.y, r.w, r.h);
      final dx = math.max(0.0, math.max(rect.left - pt.dx, pt.dx - rect.right));
      final dy = math.max(0.0, math.max(rect.top - pt.dy, pt.dy - rect.bottom));
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < bestD) {
        bestD = d;
        best = r.key;
      }
    }
    return best;
  }

  /// The user tapped the room they are really in. Used as the answer for
  /// 2 minutes and, with a usable fix, saved as the GPS correction.
  Future<void> userPicked(String? key) async {
    evacuationYouRoom.value = key;
    _manualAt = key == null ? null : DateTime.now();
    final raw = _raw;
    if (key == null || raw == null || (accuracyM ?? 999) > 25 || state == LocatorState.away) return;
    final room = _items.where((i) => i.key == key).firstOrNull;
    if (room == null) return;
    _calib = Offset(room.x + room.w / 2, room.y + room.h / 2) - raw;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefDx, _calib.dx);
      await prefs.setDouble(_prefDy, _calib.dy);
    } catch (_) {}
    _place();
  }

  String label(List<LayoutItem> items) {
    String roomName(String? k) => items.where((i) => i.key == k).firstOrNull?.label ?? 'a room';
    final acc = accuracyM == null ? '' : ' (±${accuracyM!.round()} m)';
    return switch (state) {
      LocatorState.off => 'Live location needs the home pin. Set it on the Map page.',
      LocatorState.searching => 'Finding your location…',
      LocatorState.located => 'Live location: you are in the ${roomName(roomKey)}$acc',
      LocatorState.imprecise => 'GPS is not precise enough indoors right now$acc. Tap your room.',
      LocatorState.away =>
        'You are away from home (${((distanceFromHomeM ?? 0) / 1000).toStringAsFixed(distanceFromHomeM! < 1000 ? 2 : 1)} km).',
      LocatorState.denied => 'Location is off or not allowed. Turn it on, or tap your room.',
    };
  }
}

/// Status line + room chips. GPS picks the room; chips correct it.
class LiveLocationBar extends StatelessWidget {
  const LiveLocationBar({super.key, required this.items});
  final List<LayoutItem> items;

  @override
  Widget build(BuildContext context) {
    final loc = IndoorLocator.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([loc, evacuationYouRoom]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final dark = theme.brightness == Brightness.dark;
        final color = switch (loc.state) {
          LocatorState.located => const Color(0xFF16A34A),
          LocatorState.away => const Color(0xFF3B82F6),
          LocatorState.searching => const Color(0xFFF97316),
          _ => const Color(0xFFF59E0B),
        };
        final you = evacuationYouRoom.value;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(loc.state == LocatorState.located ? Icons.my_location : Icons.location_searching, size: 17, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(loc.label(items),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: dark ? Colors.white : const Color(0xFF1F1410))),
            ),
          ]),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final r in items.where((i) => i.kind == 'room'))
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    avatar: you == r.key && loc.state == LocatorState.located && loc.roomKey == r.key
                        ? const Icon(Icons.gps_fixed, size: 14)
                        : null,
                    label: Text(r.label),
                    selected: you == r.key,
                    visualDensity: VisualDensity.compact,
                    onSelected: (on) => loc.userPicked(on ? r.key : null),
                  ),
                ),
            ]),
          ),
        ]);
      },
    );
  }
}
