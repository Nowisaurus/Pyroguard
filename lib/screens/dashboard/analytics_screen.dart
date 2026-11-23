import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../responsive.dart';
import '../../theme.dart';
import 'shared_app_bar.dart';
import 'dashboard_repository.dart';
import 'dashboard_models.dart';
import 'analytics_overview.dart';
import '../../widgets/testing_data_panel.dart';
import '../../widgets/sensor_health_panel.dart';

class AnalyticsTab extends StatefulWidget {
  const AnalyticsTab({super.key});
  @override State<AnalyticsTab> createState() => _AnalyticsTabState();
}
class _AnalyticsTabState extends State<AnalyticsTab> {
  late final DashboardRepository repository;
  AnalyticsSummary? summary;
  String? error;
  bool loading = true;
  @override void initState() {
    super.initState();
    repository = DashboardRepository(Supabase.instance.client);
    refresh();
  }
  Future<void> refresh() async {
    try {
      final result = await repository.analytics();
      if (mounted) setState(() { summary = result; error = null; loading = false; });
    } catch (e) {
      if (mounted) setState(() { error = e.toString(); loading = false; });
    }
  }
  @override Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    appBar: const PyroAppBar(title: 'Analytics', subtitle: 'Dual ESP32 sensor history'),
    body: RefreshIndicator(onRefresh: refresh, color: AppColors.orange,
      child: ListView(padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context),14,Responsive.horizontalPadding(context),90),children:[
        Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          if (loading) const LinearProgressIndicator(),
          if (error != null) Padding(padding: const EdgeInsets.only(bottom:12),child:Text('Unable to load saved history: $error',style:const TextStyle(color:AppColors.red))),
          AnalyticsOverview(summary: summary),
          const SizedBox(height: 14),
          // Sensor health: working / damaged, maintenance, device log.
          const SensorHealthPanel(),
          const SizedBox(height: 14),
          const TestingDataPanel(),
        ]))),
      ])),
  );
}
