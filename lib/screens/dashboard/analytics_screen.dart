import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../services/sensor_service.dart';
import '../../theme.dart';
import '../../responsive.dart';
import 'shared_app_bar.dart';

class AnalyticsTab extends StatefulWidget {
  const AnalyticsTab({super.key});
  @override
  State<AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<AnalyticsTab> {
  @override
  void initState() { super.initState(); SensorService.instance.addListener(_r); }
  @override
  void dispose() { SensorService.instance.removeListener(_r); super.dispose(); }
  void _r() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final isDark  = AppTheme.isDark(context);
    final svc     = SensorService.instance;
    final hist    = svc.history;
    final counts  = svc.incidentCounts;
    final recent  = hist.reversed.take(20).toList();
    final smokeSpots = <FlSpot>[];
    final tempSpots  = <FlSpot>[];
    for (int i = 0; i < recent.length; i++) {
      smokeSpots.add(FlSpot(i.toDouble(), recent[i].smokeLevel));
      tempSpots.add(FlSpot(i.toDouble(), recent[i].temperature));
    }

    final gridColor = AppTheme.border(context).withValues(alpha: 0.4);
    final txtSec    = AppTheme.textSecondary(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const PyroAppBar(title: 'Analytics', subtitle: 'Sensor trends'),
      body: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              Responsive.horizontalPadding(context),
              14,
              Responsive.horizontalPadding(context),
              96,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

          // KPI grid
          LayoutBuilder(builder: (context, constraints) {
            final columns = constraints.maxWidth < 430 ? 1 : constraints.maxWidth >= 900 ? 4 : 2;
            return GridView.count(
            crossAxisCount: columns, crossAxisSpacing: 10, mainAxisSpacing: 10,
            childAspectRatio: columns == 1 ? 2.5 : columns == 4 ? 1.35 : 1.6, shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _KPI('Total Readings', '${hist.length}', Icons.data_usage, AppColors.maroonMid, isDark),
              _KPI('Fire Events', '${counts['Fire Detected'] ?? 0}', Icons.local_fire_department, AppColors.red, isDark),
              _KPI('Warnings', '${(counts['Dust/Smoke'] ?? 0) + (counts['Cooking Smoke'] ?? 0)}', Icons.warning_amber, AppColors.amber, isDark),
              _KPI('Normal Reads', '${counts['Normal'] ?? 0}', Icons.check_circle_outline, AppColors.green, isDark),
            ],
          );
          }),
          const SizedBox(height: 14),

          // Smoke chart
          if (smokeSpots.length > 1) ...[
            _ChartCard(
              title: 'Smoke Level % (last ${smokeSpots.length} readings)',
              isDark: isDark,
              child: LineChart(LineChartData(
                minY: 0, maxY: 100,
                gridData: FlGridData(show: true, getDrawingHorizontalLine: (_) => FlLine(color: gridColor, strokeWidth: 1), getDrawingVerticalLine: (_) => FlLine(color: gridColor, strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32,
                    getTitlesWidget: (v, _) => Text('${v.toInt()}', style: TextStyle(fontSize: 9, color: txtSec)))),
                ),
                lineBarsData: [LineChartBarData(
                  spots: smokeSpots, isCurved: true, color: AppColors.orange,
                  barWidth: 2.5, dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: true, color: AppColors.orange.withValues(alpha: 0.12)),
                )],
              )),
            ),
            const SizedBox(height: 14),
          ],

          // Temp chart
          if (tempSpots.length > 1) ...[
            _ChartCard(
              title: 'Temperature °C (last ${tempSpots.length} readings)',
              isDark: isDark,
              child: LineChart(LineChartData(
                gridData: FlGridData(show: true, getDrawingHorizontalLine: (_) => FlLine(color: gridColor, strokeWidth: 1), getDrawingVerticalLine: (_) => FlLine(color: gridColor, strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32,
                    getTitlesWidget: (v, _) => Text('${v.toInt()}', style: TextStyle(fontSize: 9, color: txtSec)))),
                ),
                lineBarsData: [LineChartBarData(
                  spots: tempSpots, isCurved: true, color: AppColors.maroonMid,
                  barWidth: 2.5, dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(show: true, color: AppColors.maroonMid.withValues(alpha: 0.12)),
                )],
              )),
            ),
            const SizedBox(height: 14),
          ],

          // Incident breakdown
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.card(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.border(context)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Incident Breakdown', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textPrimary(context))),
              const SizedBox(height: 12),
              ...counts.entries.map((e) {
                final pct = hist.isEmpty ? 0.0 : e.value / hist.length;
                final color = e.key == 'Fire Detected' ? AppColors.red : e.key == 'Normal' ? AppColors.green : AppColors.amber;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(e.key, style: TextStyle(fontSize: 12, color: AppTheme.textPrimary(context)))),
                      Text('${e.value}  (${(pct * 100).toStringAsFixed(0)}%)', style: TextStyle(fontSize: 11, color: AppTheme.statusForeground(context, color), fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: pct, minHeight: 6,
                        backgroundColor: AppTheme.border(context),
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                  ]),
                );
              }),
              if (hist.isEmpty)
                Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No data yet — waiting for ESP32 sensor readings.', style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12), textAlign: TextAlign.center),
                )),
            ]),
          ),
        ]),
              ),
            ),
          ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final Widget child;
  final bool isDark;
  const _ChartCard({required this.title, required this.child, required this.isDark});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
    decoration: BoxDecoration(
      color: AppTheme.card(context),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.border(context)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.textPrimary(context))),
      const SizedBox(height: 12),
      SizedBox(height: 160, child: child),
    ]),
  );
}

class _KPI extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  final bool isDark;
  const _KPI(this.label, this.value, this.icon, this.color, this.isDark);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTheme.card(context),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Icon(icon, color: AppTheme.statusForeground(context, color), size: 22),
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppTheme.statusForeground(context, color))),
        Text(label, style: TextStyle(fontSize: 10, color: AppTheme.textSecondary(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]),
    ]),
  );
}
