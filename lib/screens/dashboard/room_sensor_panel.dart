import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import '../../config/coverage_config.dart';
import '../../services/room_sensor_service.dart';
import '../../theme.dart';

/// Shared read-only room telemetry for homeowner and administrator screens.
/// The panels never invent sensor values for missing or stale readings.
class RoomSensorHealthPanel extends StatelessWidget {
  const RoomSensorHealthPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final service = RoomSensorService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final groups = [
          for (final d in RoomSensorService.controllerIds)
            for (final r in RoomSensorService.roomsFor(d)) (device: d, room: r),
        ];
        final fresh =
            groups.where((g) => service.fresh(g.device, g.room)).length;
        final alerts =
            groups.where((g) => service.alert(g.device, g.room)).length;
        final incomplete = groups
            .where((g) => service.missingFields(g.device, g.room).isNotEmpty)
            .length;
        final muted = AppTheme.textSecondary(context);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.monitor_heart_outlined, color: AppColors.orange),
            const SizedBox(width: 8),
            const Expanded(
                child: Text('Sensor health & diagnostics',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
            IconButton(
                onPressed: service.refresh,
                tooltip: 'Refresh sensor diagnostics',
                icon: const Icon(Icons.refresh)),
          ]),
          Text(
              service.error != null
                  ? 'Telemetry unavailable: verify connection and read permissions'
                  : 'Fresh $fresh/${groups.length}  •  Active alerts $alerts  •  Missing field groups $incomplete',
              style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, bounds) {
            final columns = bounds.maxWidth >= 760 ? 2 : 1;
            final width = (bounds.maxWidth - 10 * (columns - 1)) / columns;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final g in groups)
                SizedBox(
                    width: width,
                    child: _healthRow(context, service, g.device, g.room)),
            ]);
          }),
        ]);
      },
    );
  }

  Widget _healthRow(BuildContext context, RoomSensorService service,
      String controller, String room) {
    final record = service.reading(controller, room);
    final age = service.readingAge(controller, room);
    final fields = service.missingFields(controller, room);
    final isFresh = service.fresh(controller, room);
    final isAlert = service.alert(controller, room);
    final label = RoomSensorService.label(controller, room);
    final state = record == null
        ? 'NO DATA'
        : !isFresh
            ? 'STALE'
            : isAlert
                ? 'ALERT'
                : fields.isNotEmpty
                    ? 'INCOMPLETE'
                    : 'FRESH';
    final color = isAlert
        ? AppColors.redBright
        : isFresh && fields.isEmpty
            ? AppColors.green
            : AppColors.amber;
    final last = age == null
        ? 'Never received'
        : age.isNegative
            ? 'Clock mismatch'
            : '${age.inSeconds}s since sample';
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: GlassStyle.card(
          light: !AppTheme.isDark(context),
          border: color.withValues(alpha: .35)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text('$controller • $label',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800))),
          Text(state,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 3),
        Text('Last sample: $last', style: const TextStyle(fontSize: 11)),
        Text(
            record == null
                ? 'No readings received'
                : fields.isEmpty
                    ? 'Required room sensor fields reported'
                    : 'Not reported: ${fields.join(', ')}',
            style: TextStyle(
                fontSize: 10, color: AppTheme.textSecondary(context))),
      ]),
    );
  }
}

class RoomSensorPanel extends StatelessWidget {
  const RoomSensorPanel(
      {super.key, this.compact = false, this.adminDiagnostics = false});

  final bool compact;
  final bool adminDiagnostics;

  @override
  Widget build(BuildContext context) {
    final service = RoomSensorService.instance;
    final muted = AppTheme.textSecondary(context);
    final primary = AppTheme.textPrimary(context);
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.sensors_outlined,
                color: AppColors.orange, size: 19),
            const SizedBox(width: 8),
            Expanded(
                child: Text('Room Sensor Coverage',
                    style: TextStyle(
                        fontSize: compact ? 14 : 17,
                        fontWeight: FontWeight.w800,
                        color: primary))),
            IconButton(
              tooltip: 'View stored room sensor history',
              // Centered window that always fits inside the screen, with its
              // OWN solid background (no longer see-through, independent of
              // the theme's translucent sheet colour).
              onPressed: () => showDialog<void>(
                context: context,
                barrierColor: Colors.black.withValues(alpha: .55),
                builder: (ctx) => Dialog(
                  backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : Colors.white,
                  surfaceTintColor: Colors.transparent,
                  insetPadding: const EdgeInsets.all(20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: const _RoomHistorySheet(),
                  ),
                ),
              ),
              icon: const Icon(Icons.history, size: 19),
            ),
            IconButton(
              tooltip: 'Refresh room sensors',
              visualDensity: VisualDensity.compact,
              onPressed: () => service.refresh(),
              icon: const Icon(Icons.refresh, size: 19),
            ),
          ]),
          Text(
              'Batch 1 (ESP32-001): ${CoverageConfig.controllerCoverage(CoverageConfig.batchOneController)}  •  '
              'Batch 2 (ESP32-002): ${CoverageConfig.controllerCoverage(CoverageConfig.batchTwoController)}',
              style: TextStyle(fontSize: 11, color: muted)),
          if (adminDiagnostics) ...[
            const SizedBox(height: 10),
            _AdminFireSnapshot(service: service),
          ],
          if (service.error != null)
            const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Unable to retrieve room telemetry',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.amber))),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, bounds) {
            final columns = bounds.maxWidth >= 1000
                ? 4
                : bounds.maxWidth >= 540
                    ? 2
                    : 1;
            final width = (bounds.maxWidth - 10 * (columns - 1)) / columns;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final controller in RoomSensorService.controllerIds)
                for (final room in RoomSensorService.roomsFor(controller))
                  SizedBox(
                      width: width,
                      child: _RoomCard(
                          controller: controller,
                          room: room,
                          roomLabel: RoomSensorService.label(controller, room),
                          compact: compact,
                          adminDiagnostics: adminDiagnostics)),
            ]);
          }),
        ],
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard(
      {required this.controller,
      required this.room,
      required this.roomLabel,
      required this.compact,
      required this.adminDiagnostics});
  final String controller;
  final String room;
  final String roomLabel;
  final bool compact;
  final bool adminDiagnostics;

  @override
  Widget build(BuildContext context) {
    final service = RoomSensorService.instance;
    final record = service.reading(controller, room);
    final fresh = service.fresh(controller, room);
    final alert = service.alert(controller, room);
    final fault = service.sensorFault(controller, room);
    final missing = service.missingFields(controller, room);
    final hasReading = record != null;
    final status = !hasReading
        ? 'NO DATA'
        : !fresh
            ? 'STALE'
            : alert
                ? 'ALERT'
                : fault
                    ? 'CHECK SENSOR'
                    : missing.isNotEmpty
                    ? 'INCOMPLETE'
                    : 'FRESH';
    final color = alert
        ? AppColors.redBright
        : fresh && missing.isEmpty && !fault
            ? AppColors.green
            : AppColors.amber;
    final muted = AppTheme.textSecondary(context);
    final primary = AppTheme.textPrimary(context);
    const entries =
        <({String label, String field, String unit, IconData icon})>[
      (
        label: 'Temperature',
        field: 'temperature',
        unit: ' °C',
        icon: Icons.thermostat_outlined
      ),
      (
        label: 'Humidity',
        field: 'humidity',
        unit: ' %',
        icon: Icons.water_drop_outlined
      ),
      (
        label: 'Smoke / gas',
        field: 'smoke_raw',
        unit: '',
        icon: Icons.cloud_outlined
      ),
      (
        label: 'Smoke status',
        field: 'smoke_status',
        unit: '',
        icon: Icons.warning_amber_outlined
      ),
      (
        label: 'Flame',
        field: 'flame_detected',
        unit: '',
        icon: Icons.local_fire_department_outlined
      ),
      (
        label: 'Buzzer',
        field: 'buzzer_active',
        unit: '',
        icon: Icons.notifications_active_outlined
      ),
    ];
    return Container(
      padding: EdgeInsets.all(compact ? 11 : 14),
      decoration: GlassStyle.card(
          light: !AppTheme.isDark(context),
          border: color.withValues(alpha: .28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(roomLabel,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: primary)),
                Text('${CoverageConfig.batchName(controller)} • $controller',
                    style: TextStyle(fontSize: 10, color: muted)),
              ])),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(8)),
              child: Text(status,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: color))),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, b) {
          final cellWidth =
              b.maxWidth >= 225 ? (b.maxWidth - 8) / 2 : b.maxWidth;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final sensor in entries)
              SizedBox(
                  width: cellWidth,
                  child: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                        color: const Color(0xFFFFF9F5).withValues(
                            alpha: AppTheme.isDark(context) ? .20 : .24),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppTheme.border(context))),
                    child: Row(children: [
                      Icon(sensor.icon, size: 15, color: muted),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(sensor.label,
                                style: TextStyle(fontSize: 9.5, color: muted)),
                            const SizedBox(height: 2),
                            Text(
                                !hasReading || !fresh
                                    ? '—'
                                    : service.value(
                                        controller, room, sensor.field,
                                        unit: sensor.unit),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w800,
                                    color: primary)),
                          ])),
                    ]),
                  )),
          ]);
        }),
        const SizedBox(height: 9),
        Row(children: [
          Icon(Icons.schedule_outlined, size: 12, color: muted),
          const SizedBox(width: 5),
          Expanded(
              child: Text(
                  !hasReading
                      ? 'Awaiting first reading'
                      : 'Last sample: ${DateTime.tryParse('${record['sampled_at'] ?? ''}')?.toLocal().toString().split('.').first ?? 'Unknown'}',
                  style: TextStyle(fontSize: 10, color: muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
        ]),
        if (adminDiagnostics && hasReading && missing.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('Missing: ${missing.join(', ')}',
              maxLines: 2,
              style: const TextStyle(fontSize: 10, color: AppColors.amber)),
        ],
      ]),
    );
  }
}

class _RoomHistorySheet extends StatefulWidget {
  const _RoomHistorySheet();
  @override
  State<_RoomHistorySheet> createState() => _RoomHistorySheetState();
}

class _RoomHistorySheetState extends State<_RoomHistorySheet> {
  String controller = RoomSensorService.controllerIds.first;
  String room = 'entrance';
  final List<Map<String, dynamic>> records = [];
  bool busy = false;
  bool hasMore = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _reset() {
    records.clear();
    hasMore = true;
    error = null;
    _load();
  }

  Future<void> _load() async {
    if (busy || !hasMore) return;
    setState(() => busy = true);
    try {
      final cursor = records.isEmpty
          ? null
          : DateTime.tryParse('${records.last['sampled_at'] ?? ''}');
      final page = await RoomSensorService.instance.historyPage(
        controller: controller,
        room: room,
        before: cursor,
      );
      if (!mounted) return;
      setState(() {
        records.addAll(page);
        hasMore = page.length == 100;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Unable to load history: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return SafeArea(
        child: SizedBox(
      // Fits inside the window: 85% of its height (minus the dialog margins),
      // never taller than 820 px.
      height: ((screenH - 40) * .85).clamp(320.0, 820.0).toDouble(),
      child: Padding(
          padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 16, wide ? 24 : 16, 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                  child: Text('Recorded sensor history',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 18))),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close)),
            ]),
            Wrap(spacing: 12, children: [
              DropdownButton<String>(
                  value: controller,
                  items: [
                    for (final id in RoomSensorService.controllerIds)
                      DropdownMenuItem(
                          value: id,
                          child: Text('${CoverageConfig.batchName(id)} • $id'))
                  ],
                  onChanged: busy
                      ? null
                      : (v) {
                          if (v != null) {
                            setState(() {
                              controller = v;
                              room = RoomSensorService.roomsFor(v).first;
                            });
                            _reset();
                          }
                        }),
              DropdownButton<String>(
                  value: room,
                  items: [
                    for (final r in RoomSensorService.roomsFor(controller))
                      DropdownMenuItem(
                          value: r,
                          child: Text(RoomSensorService.label(controller, r)))
                  ],
                  onChanged: busy
                      ? null
                      : (v) {
                          if (v != null) {
                            setState(() => room = v);
                            _reset();
                          }
                        }),
            ]),
            if (error != null)
              Text(error!, style: const TextStyle(color: AppColors.redBright)),
            if (records.isNotEmpty) ...[
              const SizedBox(height: 8),
              _LoadedTemperatureTrend(records: records),
              const SizedBox(height: 8),
            ],
            Expanded(
                child: records.isEmpty && !busy
                    ? const Center(
                        child: Text('No saved readings for this room'))
                    : ListView.builder(
                        itemCount: records.length,
                        itemBuilder: (context, index) {
                          final r = records[index];
                          return ListTile(
                            dense: true,
                            title: Text('${r['sampled_at'] ?? 'Unknown time'}',
                                style: const TextStyle(fontSize: 12)),
                            subtitle: Text(
                                'Temp ${r['temperature'] ?? '—'} °C  •  '
                                'Humidity ${r['humidity'] ?? '—'}%  •  '
                                'Smoke ${r['smoke_raw'] ?? '—'}  •  '
                                'Flame ${r['flame_detected'] ?? '—'}  •  '
                                'Buzzer ${r['buzzer_active'] ?? '—'}',
                                style: const TextStyle(fontSize: 11)),
                          );
                        })),
            if (busy) const LinearProgressIndicator(),
            if (hasMore)
              Align(
                  alignment: Alignment.center,
                  child: TextButton(
                      onPressed: busy ? null : _load,
                      child: const Text('Load more readings'))),
            const Text(
                'History loads in pages; there is no fixed overall reading cap.',
                style: TextStyle(fontSize: 10)),
          ])),
    ));
  }
}

/// Admin-only latest-sample analytics. Never extrapolates historical events or
/// infers an alarm from an uncalibrated MQ-2 raw ADC value.
class _AdminFireSnapshot extends StatelessWidget {
  const _AdminFireSnapshot({required this.service});
  final RoomSensorService service;

  @override
  Widget build(BuildContext context) {
    final groups = [
      for (final id in RoomSensorService.controllerIds)
        for (final room in RoomSensorService.roomsFor(id)) (id: id, room: room),
    ];
    final fresh = groups.where((g) => service.fresh(g.id, g.room)).length;
    final signals = groups.where((g) => service.alert(g.id, g.room)).length;
    final missing = groups
        .where((g) => service.missingFields(g.id, g.room).isNotEmpty)
        .length;
    final stale = groups
        .where((g) =>
            service.reading(g.id, g.room) != null &&
            !service.fresh(g.id, g.room))
        .length;
    final temps = [
      for (final g in groups)
        if (service.fresh(g.id, g.room) &&
            service.reading(g.id, g.room)?['temperature'] is num)
          (
            label:
                '${CoverageConfig.batchName(g.id)} / ${RoomSensorService.label(g.id, g.room)}',
            value: (service.reading(g.id, g.room)!['temperature'] as num)
                .toDouble()
          ),
    ];
    final secondary = AppTheme.textSecondary(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Fire-safety sensor operations',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(spacing: 16, runSpacing: 6, children: [
          _metric('Fresh groups', '$fresh/${groups.length}', AppColors.green),
          _metric('Active signals', '$signals', AppColors.redBright),
          _metric('Stale groups', '$stale', AppColors.amber),
          _metric('Incomplete groups', '$missing', AppColors.amber),
        ]),
        const SizedBox(height: 10),
        Text('Latest verified temperatures (°C)',
            style: TextStyle(color: secondary, fontSize: 11)),
        if (temps.isEmpty)
          Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: AppColors.maroonMid.withValues(alpha: .05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.border(context))),
              child: Row(children: [
                const Icon(Icons.show_chart, size: 18, color: AppColors.orange),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(
                        service.error != null
                            ? 'Telemetry unavailable'
                            : 'No fresh temperatures to graph',
                        style: TextStyle(color: secondary, fontSize: 11))),
              ]))
        else
          for (final entry in temps)
            Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Row(children: [
                  SizedBox(
                      width: 125,
                      child: Text(entry.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10))),
                  Expanded(
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: (entry.value / 70).clamp(0.0, 1.0),
                            minHeight: 7,
                            color: AppColors.orange,
                            backgroundColor:
                                AppColors.orange.withValues(alpha: .12),
                          ))),
                  const SizedBox(width: 8),
                  Text('${entry.value.toStringAsFixed(1)}°',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ])),
        if (temps.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text('Temperature scale: 0–70°C (display only)',
                  style: TextStyle(fontSize: 10, color: secondary))),
      ]),
    );
  }

  Widget _metric(String label, String value, Color color) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, color: color, size: 8),
        const SizedBox(width: 5),
        Text('$label: $value',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
      ]);
}

/// Plots only temperature measurements actually returned by the paginated
/// historical query; it does not invent zero readings for missing timestamps.
class _LoadedTemperatureTrend extends StatelessWidget {
  const _LoadedTemperatureTrend({required this.records});
  final List<Map<String, dynamic>> records;

  @override
  Widget build(BuildContext context) {
    final points = [
      for (final row in records.reversed)
        if (row['temperature'] is num) (row['temperature'] as num).toDouble(),
    ];
    if (points.isEmpty) {
      return const Text('No recorded temperatures in loaded history',
          style: TextStyle(fontSize: 11));
    }
    final lowest = points.reduce((a, b) => a < b ? a : b);
    final highest = points.reduce((a, b) => a > b ? a : b);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Recorded temperature trend · ${points.length} loaded readings',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 11)),
        const SizedBox(height: 6),
        SizedBox(
            height: 85,
            width: double.infinity,
            child: CustomPaint(painter: _TemperatureLines(points))),
        Text(
            'Range ${lowest.toStringAsFixed(1)}–${highest.toStringAsFixed(1)} °C · '
            'Shows loaded pages only',
            style: const TextStyle(fontSize: 10)),
      ]),
    );
  }
}

class _TemperatureLines extends CustomPainter {
  const _TemperatureLines(this.values);
  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final min = values.reduce((a, b) => a < b ? a : b);
    final max = values.reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs() < .001 ? 1.0 : max - min;
    final paint = Paint()
      ..color = AppColors.orange
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1
          ? size.width / 2
          : i * size.width / (values.length - 1);
      final y = size.height - 8 - (values[i] - min) / span * (size.height - 16);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TemperatureLines oldDelegate) =>
      !listEquals(oldDelegate.values, values);
}
