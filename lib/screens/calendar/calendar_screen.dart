import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import '../../services/sensor_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import '../dashboard/shared_app_bar.dart';

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

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
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

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const PyroAppBar(title: 'Calendar', subtitle: 'Incident history by day'),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 14, Responsive.horizontalPadding(context), 96),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: GlassStyle.card(light: !AppTheme.isDark(context)),
            child: TableCalendar<SensorReading>(
              firstDay: DateTime.utc(2020, 1, 1),
              lastDay: DateTime.utc(2030, 12, 31),
              focusedDay: _focusedDay,
              selectedDayPredicate: (d) => isSameDay(_selectedDay, d),
              eventLoader: _eventsFor,
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
          if (dayEvents.isEmpty)
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
      decoration: BoxDecoration(
        color: AppTheme.card(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
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
