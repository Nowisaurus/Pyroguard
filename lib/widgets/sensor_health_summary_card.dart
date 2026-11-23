import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/room_sensor_service.dart';
import '../theme.dart';
import 'pg_ui.dart';
import 'sensor_health_panel.dart';

/// Dashboard card: which sensors are working and which are damaged, at a
/// glance. Tap for the full Sensor Health panel on the Monitoring page.
class SensorHealthSummaryCard extends StatefulWidget {
  const SensorHealthSummaryCard({super.key});

  @override
  State<SensorHealthSummaryCard> createState() => _SensorHealthSummaryCardState();
}

class _SensorHealthSummaryCardState extends State<SensorHealthSummaryCard> {
  final rooms = RoomSensorService.instance;

  @override
  void initState() {
    super.initState();
    rooms.addListener(_changed);
    rooms.start();
  }

  @override
  void dispose() {
    rooms.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);

    var total = 0, ok = 0, damaged = 0;
    final rows = <({String device, String room, List<SensorHealthStatus> states})>[];
    for (final device in RoomSensorService.controllerIds) {
      for (final room in RoomSensorService.roomsFor(device)) {
        final states = [for (final k in SensorHealth.kinds) SensorHealth.of(rooms, device, room, k)];
        for (final h in states) {
          total++;
          if (h == SensorHealthStatus.ok) ok++;
          if (SensorHealth.needsAttention(h)) damaged++;
        }
        rows.add((device: device, room: room, states: states));
      }
    }
    final notReporting = total - ok - damaged;
    final badge = damaged > 0
        ? ('$damaged DAMAGED', AppColors.red)
        : notReporting > 0
            ? ('$notReporting NOT REPORTING', AppColors.amber)
            : ('ALL WORKING', AppColors.green);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.go('/analytics'),
      child: PgCard(
        accent: damaged > 0 ? AppColors.red : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PgHeader(
            icon: Icons.health_and_safety_outlined,
            title: 'Sensor Health',
            subtitle: '$ok working · $damaged damaged · $notReporting not reporting · tap for details',
            actions: [PgBadge(badge.$1, color: badge.$2)],
          ),
          const SizedBox(height: 8),
          Row(children: [
            const SizedBox(width: 96),
            for (final k in SensorHealth.kinds)
              Expanded(
                child: Text(SensorHealth.shortNames[k]!,
                    style: TextStyle(color: secondary, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
          ]),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(
                  width: 96,
                  child: Text(RoomSensorService.label(r.device, r.room),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 12.5)),
                ),
                for (final h in r.states)
                  Expanded(
                    child: Row(children: [
                      PgDot(SensorHealth.style(h).color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(SensorHealth.style(h).text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.statusForeground(context, SensorHealth.style(h).color),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
