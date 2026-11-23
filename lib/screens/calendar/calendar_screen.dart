import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../services/sensor_service.dart';
import '../../services/pyroguard_event_log_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import '../dashboard/shared_app_bar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/incident_report_service.dart';
import '../../widgets/incident_reports_panel.dart';
import '../../widgets/pg_ui.dart';

/// Dedicated Calendar page, reached from the sidebar/drawer menu bar —
/// not tucked beside the live dashboard readouts. Selecting a day filters
/// the incident history below it to events recorded that day, each shown
/// with its full date and time.
class CalendarTab extends StatefulWidget {
  const CalendarTab({super.key});
  @override
  State<CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<CalendarTab> {
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  List<Map<String, dynamic>> _hardwareEvents = [];
  List<HomeIncident> _incidents = [];
  List<Map<String, dynamic>> _areaFires = [];

  Future<void> _loadIncidents() async {
    try {
      final list = await IncidentReportService.loadIncidents(days: 0);
      if (mounted) setState(() => _incidents = list);
    } catch (_) {}
    try {
      final rows = await Supabase.instance.client.from('pyroguard_area_incidents')
          .select('occurred_on,date_precision,location_text,city,alarm_level,details,description,reference')
          .order('occurred_on', ascending: false).limit(500);
      if (mounted) setState(() => _areaFires = [for (final r in rows) Map<String, dynamic>.from(r)]);
    } catch (_) {}
  }

  List<HomeIncident> _incidentsFor(DateTime day) => _incidents.where((i) => isSameDay(i.start, day)).toList();

  List<Map<String, dynamic>> _areaFor(DateTime day) => _areaFires.where((r) {
        if (r['date_precision'] == 'month') return false;
        final d = DateTime.tryParse('${r['occurred_on']}');
        return d != null && isSameDay(d, day);
      }).toList();
  String? _hardwareError;
  Future<void> _loadHardwareEvents() async {
    try {
      final rows = await const PyroGuardEventLogService().recent(limit: 1000);
      if (mounted) setState(() { _hardwareEvents = rows; _hardwareError = null; });
    } catch (e) {
      if (mounted) setState(() => _hardwareError = '$e');
    }
  }
  List<Map<String, dynamic>> _hardwareFor(DateTime day) => _hardwareEvents.where((r) {
    final at = PyroGuardEventLogService.eventDate(r);
    return at != null && isSameDay(at, day);
  }).toList();

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _loadHardwareEvents();
    _loadIncidents();
    SensorService.instance.addListener(_rebuild);
  }

  @override
  void dispose() {
    SensorService.instance.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  List<SensorReading> _eventsFor(DateTime day) {
    return SensorService.instance.history
        .where((r) => isSameDay(r.createdAt.toLocal(), day))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedDay ?? DateTime.now();
    final dayEvents = _eventsFor(selected);
    final hardwareEvents = _hardwareFor(selected);
    final incidents = _incidentsFor(selected);
    final areaFires = _areaFor(selected);
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const PyroAppBar(title: 'Calendar', subtitle: 'Incidents, area fires and events by day'),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 14, Responsive.horizontalPadding(context), 96),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
            child: TableCalendar<Object>(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
              eventLoader: (day) => [
                ..._incidentsFor(day),
                ..._areaFor(day),
                ..._eventsFor(day),
                ..._hardwareFor(day),
              ],
              calendarBuilders: CalendarBuilders<Object>(
                markerBuilder: (context, day, events) {
                  if (events.isEmpty) return null;
                  final home = _incidentsFor(day).isNotEmpty;
                  final area = _areaFor(day).isNotEmpty;
                  return Positioned(
                    bottom: 4,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (home) const PgDot(AppColors.red, size: 6),
                      if (home && area) const SizedBox(width: 2),
                      if (area) const PgDot(AppColors.orange, size: 6),
                      if (!home && !area) const PgDot(AppColors.amber, size: 5),
                    ]),
                  );
                },
              ),
              onDaySelected: (sel, foc) => setState(() {
                _selectedDay = sel;
                _focusedDay = foc;
              }),
              calendarStyle: CalendarStyle(
                defaultTextStyle: TextStyle(color: AppTheme.textPrimary(context), fontSize: 13),
                weekendTextStyle: TextStyle(color: AppTheme.brandForeground(context), fontSize: 13, fontWeight: FontWeight.w600),
                todayDecoration: BoxDecoration(color: AppColors.orange.withValues(alpha: 0.3), shape: BoxShape.circle),
                todayTextStyle: TextStyle(color: AppTheme.brandForeground(context), fontWeight: FontWeight.w800),
                selectedDecoration: const BoxDecoration(color: AppColors.orange, shape: BoxShape.circle),
                selectedTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                markerDecoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle),
                outsideDaysVisible: false,
              ),
              headerStyle: HeaderStyle(
                formatButtonVisible: false,
                titleCentered: true,
                titleTextStyle: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700, fontSize: 15),
                leftChevronIcon: Icon(Icons.chevron_left, color: AppTheme.brandForeground(context)),
                rightChevronIcon: Icon(Icons.chevron_right, color: AppTheme.brandForeground(context)),
              ),
              daysOfWeekStyle: DaysOfWeekStyle(
                weekdayStyle: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11),
                weekendStyle: TextStyle(color: AppTheme.brandForeground(context), fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _fullDate(selected),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context)),
          ),
          const SizedBox(height: 8),
          if (incidents.isNotEmpty) ...[
            Text('Incidents at home', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: primary)),
            const SizedBox(height: 6),
            for (final inc in incidents)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PgTile(
                  color: incidentColor(inc.type),
                  onTap: () => showIncidentSheet(context, inc),
                  child: Row(children: [
                    PgDot(incidentColor(inc.type)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${inc.typeLabel} · ${inc.roomLabel}',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: primary)),
                        Text('${_hm(inc.start)} - ${_hm(inc.end)} · ${incidentDuration(inc)} · ${inc.readings.length} readings',
                            style: TextStyle(fontSize: 11.5, color: secondary)),
                      ]),
                    ),
                    Text('View report', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.brandForeground(context))),
                  ]),
                ),
              ),
            const SizedBox(height: 6),
          ],
          if (areaFires.isNotEmpty) ...[
            Text('Fires in the area', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: primary)),
            const SizedBox(height: 6),
            for (final f in areaFires)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: PgTile(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: Text('${f['location_text'] ?? 'Fire incident'}'),
                      content: Text([
                        if (f['city'] != null) '${f['city']}',
                        if (f['alarm_level'] != null) '${f['alarm_level']}',
                        '${f['details'] ?? f['description'] ?? ''}',
                        if (f['reference'] != null) 'Source: ${f['reference']}',
                      ].join('\n\n')),
                      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
                    ),
                  ),
                  child: Row(children: [
                    const PgDot(AppColors.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${f['location_text'] ?? 'Fire incident'}',
                            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: primary)),
                        Text([f['city'], f['alarm_level']].where((x) => x != null).join(' · '),
                            style: TextStyle(fontSize: 11.5, color: secondary)),
                      ]),
                    ),
                  ]),
                ),
              ),
            const SizedBox(height: 6),
          ],
          if (_hardwareError != null) Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Hardware event history unavailable: $_hardwareError'),
          ),
          ...hardwareEvents.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: PgTile(
              child: Row(children: [
                const PgDot(AppColors.amber),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${'${r['event_type'] ?? 'Event'}'.replaceAll('_', ' ')} · ${r['device_id'] ?? 'Device'}',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: primary)),
                    Text('${r['message'] ?? 'Hardware event'}', style: TextStyle(fontSize: 11.5, color: secondary)),
                  ]),
                ),
                Text(() { final at = PyroGuardEventLogService.eventDate(r);
                  return at == null ? '--:--' : _hm(at); }(),
                    style: TextStyle(fontSize: 11, color: secondary, fontFamily: 'monospace')),
              ]),
            ),
          )),
          if (dayEvents.isEmpty && hardwareEvents.isEmpty && incidents.isEmpty && areaFires.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
              child: Center(
                child: Text('No sensor events recorded on this day.',
                    style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12)),
              ),
            )
          else
            ...dayEvents.map((r) => _EventTile(r: r)),
            ]),
          ),
        ),
      ),
    );
  }

  String _hm(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  String _fullDate(DateTime d) {
    const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January','February','March','April','May','June','July','August','September','October','November','December'];
    return '${weekdays[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _EventTile extends StatelessWidget {
  final SensorReading r;
  const _EventTile({required this.r});

  @override
  Widget build(BuildContext context) {
    final color = r.isCriticalFire ? AppColors.red : r.isWarning ? AppColors.amber : AppColors.green;
    final l = r.createdAt.toLocal();
    final timeStr = '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: GlassStyle.card(light: !AppTheme.isDark(context), border: color.withValues(alpha: .3), radius: 12),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.incidentType, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppTheme.statusForeground(context, color))),
            Text('Smoke ${r.smokeLevel.toStringAsFixed(0)}%  ·  Temp ${r.temperature.toStringAsFixed(1)}°C  ·  Flame ${r.flameStatus ? "Yes" : "No"}',
                style: TextStyle(fontSize: 10.5, color: AppTheme.textSecondary(context))),
          ]),
        ),
        Text(timeStr, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context), fontFamily: 'monospace')),
      ]),
    );
  }
}
