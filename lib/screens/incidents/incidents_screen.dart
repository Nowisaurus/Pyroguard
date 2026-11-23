// ignore_for_file: unused_field

import 'package:flutter/material.dart';
import '../../services/sensor_service.dart';
import '../../services/pyroguard_event_log_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import '../dashboard/shared_app_bar.dart';
import '../../widgets/incident_reports_panel.dart';
import '../../services/events_export_service.dart';
import '../../widgets/evacuation_guide.dart' show loadHomeLayout;
import '../../widgets/pg_ui.dart';
import '../map/incident_history_section.dart';
import 'package:latlong2/latlong.dart';

class IncidentsTab extends StatefulWidget {
  const IncidentsTab({super.key});
  @override
  State<IncidentsTab> createState() => _IncidentsTabState();
}

class _IncidentsTabState extends State<IncidentsTab> {
  String _filter = 'All';
  List<SensorReading> _logs = [];
  List<Map<String, dynamic>> _hardwareEvents = [];
  String? _hardwareEventError;
  bool _loading = true;
  LatLng? _home;

  @override
  void initState() {
    super.initState();
    _load();
    SensorService.instance.addListener(_upd);
    loadHomeLayout().then((d) { if (mounted) setState(() => _home = d.homePoint); });
  }
  @override
  void dispose() { SensorService.instance.removeListener(_upd); super.dispose(); }
  void _upd() => setState(() => _logs = SensorService.instance.history);

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _logs = await SensorService.instance.fetchHistory(limit: 300); } catch (_) {}
    try {
      _hardwareEvents = await const PyroGuardEventLogService().recent();
      _hardwareEventError = null;
    } catch (e) { _hardwareEventError = '$e'; }
    if (mounted) setState(() => _loading = false);
  }

  bool _exporting = false;

  /// Download the event history as a PDF (panel: "pwede ma-download ang events").
  Future<void> _exportEvents() async {
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: AppTheme.isDark(ctx) ? AppColors.darkCard : AppColors.lightCard,
        surfaceTintColor: Colors.transparent,
        title: Text('Download events (PDF)',
            style: TextStyle(color: AppTheme.textPrimary(ctx), fontSize: 18, fontWeight: FontWeight.w800)),
        children: [
          for (final o in const [(1, 'Today / last 24 hours'), (7, 'Last 7 days'), (30, 'Last 30 days'), (0, 'All events')])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, o.$1),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Row(children: [
                const Icon(Icons.picture_as_pdf_outlined, color: AppColors.orange, size: 19),
                const SizedBox(width: 12),
                Text(o.$2, style: TextStyle(color: AppTheme.textPrimary(ctx), fontSize: 14, fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
    );
    if (days == null) return;
    setState(() => _exporting = true);
    try {
      final n = await EventsExportService.downloadPdf(days: days);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n events exported.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not export events: $e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  List<SensorReading> get _filtered {
    switch (_filter) {
      case 'Critical': return _logs.where((r) => r.severityLevel == 2).toList();
      case 'Warning':  return _logs.where((r) => r.severityLevel == 1).toList();
      case 'Normal':   return _logs.where((r) => r.severityLevel == 0).toList();
      default: return _logs;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: PyroAppBar(
        title: 'Events',
        subtitle: 'Incident reports, fire history and event log',
        extraActions: [
          IconButton(tooltip: 'Refresh', icon: Icon(Icons.refresh, color: AppTheme.brandForeground(context), size: 20), onPressed: _load),
        ],
      ),
      body: DefaultTabController(
        length: 3,
        child: Column(children: [
          Container(
            margin: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8, Responsive.horizontalPadding(context), 0),
            decoration: GlassStyle.card(light: !AppTheme.isDark(context), radius: 14),
            child: TabBar(
              labelColor: AppTheme.brandForeground(context),
              unselectedLabelColor: AppTheme.textSecondary(context),
              indicatorColor: AppColors.orange,
              indicatorSize: TabBarIndicatorSize.label,
              dividerColor: Colors.transparent,
              labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              tabs: const [Tab(text: 'Incident Reports'), Tab(text: 'Fire History'), Tab(text: 'Event Log')],
            ),
          ),
          Expanded(
            child: TabBarView(children: [
              _page(context, const IncidentReportsPanel()),
              _home == null
                  ? Center(child: Text('Set the home location on the Map page to see the fire history around it.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textSecondary(context))))
                  : _page(context, IncidentHistorySection(homeLat: _home!.latitude, homeLng: _home!.longitude)),
              _eventLog(context, filtered),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _page(BuildContext context, Widget child) => ListView(
        padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 12, Responsive.horizontalPadding(context), 96),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
              child: child,
            ),
          ),
        ],
      );

  Widget _eventLog(BuildContext context, List<SensorReading> filtered) => Column(children: [
        Padding(
          padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 12, Responsive.horizontalPadding(context), 6),
          child: Row(children: [
            // Filters and the PDF button stay on one line.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final f in const ['All', 'Critical', 'Warning', 'Normal'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f),
                        selected: _filter == f,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                ]),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brandForeground(context),
                  side: BorderSide(color: AppColors.orange.withValues(alpha: .6)),
                  visualDensity: VisualDensity.compact),
              onPressed: _exporting ? null : _exportEvents,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(_exporting ? 'Preparing...' : 'PDF'),
            ),
          ]),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.orange))
              : filtered.isEmpty
                  ? Center(child: Text('No $_filter events', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 14)))
                  : ListView.separated(
                      padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 8, Responsive.horizontalPadding(context), 96),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
                          child: _IncidentCard(r: filtered[i]),
                        ),
                      ),
                    ),
        ),
      ]);
}

class _IncidentCard extends StatelessWidget {
  final SensorReading r;
  const _IncidentCard({required this.r});

  @override
  Widget build(BuildContext context) {
    final color = r.severityLevel == 2 ? AppColors.red : r.severityLevel == 1 ? AppColors.amber : AppColors.green;
    final foregroundColor = AppTheme.statusForeground(context, color);
    final label = r.severityLevel == 2 ? 'CRITICAL' : r.severityLevel == 1 ? 'WARNING' : 'NORMAL';
    final dt = r.createdAt.toLocal();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final timeStr = '${months[dt.month - 1]} ${dt.day}, ${dt.year} · '
        '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: GlassStyle.card(light: !AppTheme.isDark(context), border: color.withValues(alpha: .3), radius: 14),
      child: Row(children: [
        PgDot(color, size: 10),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(r.incidentType, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary(context)), overflow: TextOverflow.ellipsis)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6)),
                child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: foregroundColor)),
              ),
            ]),
            const SizedBox(height: 4),
            // Wrap these stats to prevent overflow on small screens
            Wrap(spacing: 12, runSpacing: 6, children: [
              _IncidentMetric(icon: Icons.air_outlined, value: r.hasSmokeMeasurement ? '${r.smokeLevel.toStringAsFixed(0)}%' : 'NOT REPORTED'),
              _IncidentMetric(icon: Icons.thermostat_outlined, value: r.hasTemperatureMeasurement ? '${r.temperature.toStringAsFixed(1)}°C' : 'NOT REPORTED'),
              _IncidentMetric(icon: Icons.local_fire_department_outlined, value: !r.hasFlameMeasurement ? 'NOT REPORTED' : (r.flameStatus ? 'Flame detected' : 'No flame')),
              _IncidentMetric(icon: Icons.schedule_outlined, value: timeStr),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _IncidentMetric extends StatelessWidget {
  final IconData icon;
  final String value;
  const _IncidentMetric({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.textSecondary(context)),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.textSecondary(context),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}
