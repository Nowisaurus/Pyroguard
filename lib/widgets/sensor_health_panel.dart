import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/room_sensor_service.dart';
import '../theme.dart';
import 'pg_ui.dart';

/// Health of one room sensor, worked out from its latest live reading.
/// Shared by the Device page panel and the dashboard summary card.
enum SensorHealthStatus { ok, warming, fault, noSignal, offline, noData }

class SensorHealth {
  static const kinds = ['DHT22', 'MQ2', 'FLAME'];
  static const shortNames = {'DHT22': 'Temp', 'MQ2': 'Smoke', 'FLAME': 'Flame'};

  static SensorHealthStatus of(RoomSensorService rooms, String device, String room, String kind) {
    final r = rooms.reading(device, room);
    if (r == null) return SensorHealthStatus.noData;
    if (!rooms.fresh(device, room)) return SensorHealthStatus.offline;
    switch (kind) {
      case 'DHT22':
        return r['temperature'] == null || r['humidity'] == null ? SensorHealthStatus.fault : SensorHealthStatus.ok;
      case 'MQ2':
        final status = '${r['smoke_status'] ?? ''}'.toUpperCase();
        final raw = (r['smoke_raw'] as num?)?.toDouble();
        if (status == 'WARMUP') return SensorHealthStatus.warming;
        if (status == 'FAULT' && raw != null && raw < 155) return SensorHealthStatus.noSignal;
        if (status == 'FAULT' || r['smoke_fault'] == true) return SensorHealthStatus.fault;
        return SensorHealthStatus.ok;
      default:
        return r['flame_fault'] == true ? SensorHealthStatus.fault : SensorHealthStatus.ok;
    }
  }

  static bool needsAttention(SensorHealthStatus h) =>
      h == SensorHealthStatus.fault || h == SensorHealthStatus.noSignal;

  static ({String text, Color color, IconData icon}) style(SensorHealthStatus h) => switch (h) {
        SensorHealthStatus.ok => (text: 'Working', color: AppColors.green, icon: Icons.check_circle_rounded),
        SensorHealthStatus.warming => (text: 'Warming up', color: AppColors.amber, icon: Icons.hourglass_bottom_rounded),
        SensorHealthStatus.fault => (text: 'Damaged / check', color: AppColors.red, icon: Icons.error_rounded),
        SensorHealthStatus.noSignal => (text: 'Damaged: no signal', color: AppColors.red, icon: Icons.power_off_rounded),
        SensorHealthStatus.offline => (text: 'Board offline', color: AppColors.maroonMid, icon: Icons.cloud_off_rounded),
        SensorHealthStatus.noData => (text: 'No data yet', color: AppColors.maroonMid, icon: Icons.help_outline_rounded),
      };
}

/// Panel suggestion (2026-11-21): "You can see if a sensor is OK or damaged
/// ... not only on the Arduino Serial Monitor", "what's the primary
/// maintenance I need to check, for budget purposes ... every 2 years", and
/// "only the damaged sensor needs to be replaced".
///
///  * Health per room sensor (DHT22, MQ-2, flame) from the live readings.
///  * Maintenance: install date per sensor -> replacement due date.
///  * Device log: recent hardware events, like the Serial Monitor, in the app.
class SensorHealthPanel extends StatefulWidget {
  const SensorHealthPanel({super.key});

  @override
  State<SensorHealthPanel> createState() => _SensorHealthPanelState();
}


class _SensorHealthPanelState extends State<SensorHealthPanel> {
  static const _sensors = ['DHT22', 'MQ2', 'FLAME'];
  static const _names = {'DHT22': 'Temperature / humidity (DHT22)', 'MQ2': 'Smoke / gas (MQ-2)', 'FLAME': 'Flame (IR)'};
  /// Recommended replacement interval in months (panel: "every 2 years").
  static const _lifeMonths = {'DHT22': 24, 'MQ2': 24, 'FLAME': 24};
  static final _date = DateFormat('MMM d, yyyy');
  static final _logTime = DateFormat('MM-dd HH:mm:ss');

  final rooms = RoomSensorService.instance;
  Map<String, Map<String, dynamic>> _maint = {}; // key device/room/kind
  List<Map<String, dynamic>> _log = const [];
  String? _maintError;
  Timer? _logTimer;

  @override
  void initState() {
    super.initState();
    rooms.addListener(_changed);
    rooms.start();
    _loadMaintenance();
    _loadLog();
    _logTimer = Timer.periodic(const Duration(seconds: 10), (_) => _loadLog());
  }

  @override
  void dispose() {
    rooms.removeListener(_changed);
    _logTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _k(String device, String room, String kind) => '$device/$room/$kind';

  Future<void> _loadMaintenance() async {
    try {
      final rows = await Supabase.instance.client.from('pyroguard_sensor_maintenance').select();
      final map = <String, Map<String, dynamic>>{};
      for (final raw in rows as List) {
        final r = Map<String, dynamic>.from(raw as Map);
        map[_k('${r['device_id']}', '${r['room_key']}', '${r['sensor_kind']}')] = r;
      }
      if (mounted) setState(() { _maint = map; _maintError = null; });
    } catch (e) {
      if (mounted) {
        setState(() => _maintError =
            'Maintenance records unavailable (run database/11_SUPABASE_AREA_INCIDENTS_AND_MAINTENANCE.sql): $e');
      }
    }
  }

  Future<void> _loadLog() async {
    try {
      final rows = await Supabase.instance.client
          .from('event_history')
          .select('device_id,event_type,message,severity,created_at')
          .inFilter('device_id', RoomSensorService.controllerIds)
          .order('created_at', ascending: false)
          .limit(40);
      if (mounted) setState(() => _log = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {}
  }

  Future<void> _saveMaint(String device, String room, String kind,
      {DateTime? installed, bool checkedToday = false}) async {
    final existing = _maint[_k(device, room, kind)];
    final installedOn = installed ??
        DateTime.tryParse('${existing?['installed_on'] ?? ''}') ??
        DateTime.now();
    try {
      await Supabase.instance.client.from('pyroguard_sensor_maintenance').upsert({
        'user_id': Supabase.instance.client.auth.currentUser?.id,
        'device_id': device,
        'room_key': room,
        'sensor_kind': kind,
        'installed_on': installedOn.toIso8601String().substring(0, 10),
        if (checkedToday) 'last_checked_on': DateTime.now().toIso8601String().substring(0, 10),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id,device_id,room_key,sensor_kind');
      await _loadMaintenance();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  String _hint(SensorHealthStatus h, String kind) => switch (h) {
        SensorHealthStatus.fault when kind == 'DHT22' => 'No temperature/humidity value: check the DHT22 data wire and 3.3V.',
        SensorHealthStatus.fault when kind == 'MQ2' => 'MQ-2 reports a fault: check the AO wire and that VCC is on 5V.',
        SensorHealthStatus.fault => 'Flame sensor is flickering/noisy: adjust its blue sensitivity knob or wiring.',
        SensorHealthStatus.noSignal => 'MQ-2 reads 0 V: AO wire/divider not connected or the sensor has no 5V.',
        SensorHealthStatus.offline => 'This board has not sent data recently (power / Wi-Fi).',
        _ => '',
      };

  Future<void> _pickInstallDate(String device, String room, String kind) async {
    final current = DateTime.tryParse('${_maint[_k(device, room, kind)]?['installed_on'] ?? ''}');
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'When was this sensor installed?',
    );
    if (picked != null) await _saveMaint(device, room, kind, installed: picked);
  }

  Widget _maintLine(String device, String room, String kind) {
    final m = _maint[_k(device, room, kind)];
    final secondary = AppTheme.textSecondary(context);
    final installed = DateTime.tryParse('${m?['installed_on'] ?? ''}');
    if (installed == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
          onPressed: () => _pickInstallDate(device, room, kind),
          child: const Text('Set install date'),
        ),
      );
    }
    final due = DateTime(installed.year, installed.month + _lifeMonths[kind]!, installed.day);
    final daysLeft = due.difference(DateTime.now()).inDays;
    final color = daysLeft < 0 ? AppColors.red : daysLeft < 60 ? AppColors.amber : AppColors.green;
    final checked = DateTime.tryParse('${m?['last_checked_on'] ?? ''}');
    return Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      InkWell(
        onTap: () => _pickInstallDate(device, room, kind),
        child: Text('Installed ${_date.format(installed)}',
            style: TextStyle(color: secondary, fontSize: 11.5, decoration: TextDecoration.underline)),
      ),
      Text(
        daysLeft < 0
            ? '· Replace now (due ${_date.format(due)})'
            : '· Replace by ${_date.format(due)} (${(daysLeft / 30).floor()} mo left)',
        style: TextStyle(color: AppTheme.statusForeground(context, color), fontSize: 11.5, fontWeight: FontWeight.w700),
      ),
      if (checked != null) Text('· Checked ${_date.format(checked)}', style: TextStyle(color: secondary, fontSize: 11.5)),
      TextButton(
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 28)),
        onPressed: () => _saveMaint(device, room, kind, checkedToday: true),
        child: const Text('Mark checked today', style: TextStyle(fontSize: 11.5)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    var faults = 0;
    var dueSoon = 0;
    for (final device in RoomSensorService.controllerIds) {
      for (final room in RoomSensorService.roomsFor(device)) {
        for (final kind in _sensors) {
          final h = SensorHealth.of(rooms, device, room, kind);
          if (SensorHealth.needsAttention(h)) faults++;
          final installed = DateTime.tryParse('${_maint[_k(device, room, kind)]?['installed_on'] ?? ''}');
          if (installed != null &&
              DateTime(installed.year, installed.month + _lifeMonths[kind]!, installed.day)
                      .difference(DateTime.now()).inDays < 60) {
            dueSoon++;
          }
        }
      }
    }

    return PgCard(
      accent: faults > 0 ? AppColors.red : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PgHeader(icon: Icons.health_and_safety_outlined, title: 'Sensor Health & Maintenance'),
        const SizedBox(height: 4),
        Text(
          faults == 0 && dueSoon == 0
              ? 'All sensors reporting normally. Each sensor can be replaced on its own; only the faulty part needs to be bought.'
              : '${faults > 0 ? '$faults damaged sensor${faults == 1 ? '' : 's'} (the others are still working). ' : ''}'
                  '${dueSoon > 0 ? '$dueSoon due for replacement within 2 months.' : ''}',
          style: TextStyle(
              color: faults > 0 ? AppTheme.dangerForeground(context) : secondary,
              fontSize: 12, fontWeight: faults > 0 ? FontWeight.w700 : FontWeight.w400),
        ),
        if (_maintError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_maintError!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 11)),
          ),
        const SizedBox(height: 8),
        for (final device in RoomSensorService.controllerIds)
          for (final room in RoomSensorService.roomsFor(device))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PgTile(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${RoomSensorService.label(device, room)}  ·  $device',
                    style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
                for (final kind in _sensors) ...[
                  const SizedBox(height: 6),
                  Builder(builder: (context) {
                    final h = SensorHealth.of(rooms, device, room, kind);
                    final st = SensorHealth.style(h);
                    final hint = _hint(h, kind);
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        PgDot(st.color),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_names[kind]!, style: TextStyle(color: primary, fontSize: 12.5))),
                        Text(st.text,
                            style: TextStyle(color: AppTheme.statusForeground(context, st.color),
                                fontWeight: FontWeight.w800, fontSize: 12)),
                      ]),
                      if (hint.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 17, top: 2),
                          child: Text(hint, style: TextStyle(color: secondary, fontSize: 11)),
                        ),
                      Padding(padding: const EdgeInsets.only(left: 17), child: _maintLine(device, room, kind)),
                    ]);
                  }),
                ],
              ])),
            ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Device log (like the Serial Monitor)',
                style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 13)),
            subtitle: Text('Latest hardware events from both ESP32 boards, updated every 10 s',
                style: TextStyle(color: secondary, fontSize: 11)),
            children: [
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 280),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF0D0F13), borderRadius: BorderRadius.circular(10)),
                child: _log.isEmpty
                    ? const Text('No hardware events yet.',
                        style: TextStyle(color: Color(0xFFB4B2A9), fontFamily: 'monospace', fontSize: 11.5))
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _log.length,
                        itemBuilder: (context, i) {
                          final e = _log[i];
                          final when = DateTime.tryParse('${e['created_at']}')?.toLocal();
                          final sev = (e['severity'] as num?)?.toInt() ?? 0;
                          final color = sev >= 2
                              ? const Color(0xFFF09595)
                              : sev == 1
                                  ? const Color(0xFFFAC775)
                                  : const Color(0xFF9FE1CB);
                          return Text(
                            '${when == null ? '--' : _logTime.format(when)}  ${e['device_id']}  '
                            '${e['event_type']}  ${e['message'] ?? ''}',
                            style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 11.5, height: 1.4),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ]),
    );
  }
}
