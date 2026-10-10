import 'package:flutter/material.dart';
import '../../services/sensor_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import '../dashboard/shared_app_bar.dart';

class IncidentsTab extends StatefulWidget {
  const IncidentsTab({super.key});
  @override
  State<IncidentsTab> createState() => _IncidentsTabState();
}

class _IncidentsTabState extends State<IncidentsTab> {
  String _filter = 'All';
  List<SensorReading> _logs = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); SensorService.instance.addListener(_upd); }
  @override
  void dispose() { SensorService.instance.removeListener(_upd); super.dispose(); }
  void _upd() => setState(() => _logs = SensorService.instance.history);

  Future<void> _load() async {
    setState(() => _loading = true);
    try { _logs = await SensorService.instance.fetchHistory(limit: 300); } catch (_) {}
    if (mounted) setState(() => _loading = false);
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
        title: 'Incident Logs',
        subtitle: '${_logs.length} total records',
        extraActions: [
          IconButton(icon: Icon(Icons.refresh_rounded, color: AppTheme.brandForeground(context), size: 20), onPressed: _load),
        ],
      ),
      body: Column(children: [
        // Filter chips — wrap prevents overflow
        Container(
          padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 10, Responsive.horizontalPadding(context), 6),
          color: AppTheme.bg(context),
          child: Wrap(
            spacing: 8, runSpacing: 6,
            children: ['All', 'Critical', 'Warning', 'Normal'].map((f) {
              final active = _filter == f;
              final color = f == 'Critical' ? AppColors.red : f == 'Warning' ? AppColors.amber : f == 'Normal' ? AppColors.green : AppColors.orange;
              return GestureDetector(
                onTap: () => setState(() => _filter = f),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: active ? color.withValues(alpha: 0.15) : AppTheme.card(context),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: active ? color.withValues(alpha: 0.5) : AppTheme.border(context)),
                  ),
                  child: Text(f, style: TextStyle(fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.w400, color: active ? color : AppTheme.textSecondary(context))),
                ),
              );
            }).toList(),
          ),
        ),

        // List
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.orange))
              : filtered.isEmpty
                  ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.inbox_outlined, size: 56, color: AppTheme.textSecondary(context).withValues(alpha: 0.4)),
                      const SizedBox(height: 12),
                      Text('No $_filter incidents', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 14)),
                    ]))
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
      ]),
    );
  }
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
      decoration: BoxDecoration(
        color: AppTheme.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
          child: Icon(r.severityLevel == 2 ? Icons.local_fire_department_outlined : r.severityLevel == 1 ? Icons.warning_amber_outlined : Icons.check_circle_outline, color: foregroundColor, size: 20),
        ),
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
              _IncidentMetric(icon: Icons.air_outlined, value: '${r.smokeLevel.toStringAsFixed(0)}%'),
              _IncidentMetric(icon: Icons.thermostat_outlined, value: '${r.temperature.toStringAsFixed(1)}°C'),
              _IncidentMetric(icon: Icons.local_fire_department_outlined, value: r.flameStatus == true ? 'Flame detected' : 'No flame'),
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
