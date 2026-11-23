import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../screens/settings/settings_screen.dart' show BfpSettingsPage;
import '../services/incident_report_service.dart';
import '../theme.dart';
import 'pg_ui.dart';

final _fmt = DateFormat('MMM d, yyyy  h:mm a');

Color incidentColor(String type) => switch (type) {
      'FIRE' => AppColors.red,
      'SMOKE' => AppColors.orange,
      _ => AppColors.amber,
    };

String incidentDuration(HomeIncident inc) {
  final mins = inc.end.difference(inc.start).inMinutes;
  return mins < 1 ? 'under 1 min' : '$mins min';
}

/// Downloads the BFP incident report PDF (shared by Events and Calendar).
Future<void> downloadIncidentPdf(BuildContext context, HomeIncident inc) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(duration: Duration(seconds: 3), content: Text('Preparing the PDF report...')));
  try {
    await IncidentReportService.download(inc);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not create the PDF: $e')));
  }
}

/// E-mails the PDF to the saved BFP station (with confirmation).
Future<void> sendIncidentToBfp(BuildContext context, HomeIncident inc) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final bfp = await IncidentReportService.bfpContact();
  if (!context.mounted) return;
  final email = '${bfp['email'] ?? ''}'.trim();
  final station = '${bfp['station_name'] ?? bfp['name'] ?? 'BFP station'}';
  if (email.isEmpty) {
    final add = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('No BFP e-mail saved'),
        content: Text('Add the e-mail address of $station first. You can still download the PDF and send it yourself.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add BFP e-mail')),
        ],
      ),
    );
    if (add == true) await navigator.push(MaterialPageRoute(builder: (_) => BfpSettingsPage(initial: bfp)));
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Send report to BFP?'),
      content: Text('Report ${inc.reportNumber} (${inc.typeLabel}, ${inc.roomLabel}) will be e-mailed as a PDF to:\n\n'
          '$station\n$email\n\nA copy is sent to your own e-mail. This is a record copy, not an emergency call. '
          'For an active fire, call the BFP or 911.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.red),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Send'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  messenger.showSnackBar(const SnackBar(duration: Duration(seconds: 3), content: Text('Sending the report...')));
  try {
    final to = await IncidentReportService.emailToBfp(inc);
    messenger.showSnackBar(SnackBar(backgroundColor: const Color(0xFF166534), content: Text('Report ${inc.reportNumber} sent to $to.')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
  }
}

/// Details of one incident with its actions (Events and Calendar).
void showIncidentSheet(BuildContext context, HomeIncident inc) {
  final temps = inc.readings.map((r) => (r['temperature'] as num?)?.toDouble()).whereType<double>();
  final smokes = inc.readings.map((r) => (r['smoke_raw'] as num?)?.toDouble()).whereType<double>();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: AppTheme.isDark(context) ? AppColors.darkCard : Colors.white,
    builder: (ctx) {
      final primary = AppTheme.textPrimary(ctx);
      final secondary = AppTheme.textSecondary(ctx);
      Widget row(String k, String v) => Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 120, child: Text(k, style: TextStyle(color: secondary, fontSize: 12.5))),
              Expanded(child: Text(v, style: TextStyle(color: primary, fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text('${inc.typeLabel} · ${inc.roomLabel}',
                    style: TextStyle(color: primary, fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              PgBadge(inc.type, color: incidentColor(inc.type)),
            ]),
            const SizedBox(height: 12),
            row('Report number', inc.reportNumber),
            row('First detected', _fmt.format(inc.start)),
            row('Last detected', _fmt.format(inc.end)),
            row('Duration', incidentDuration(inc)),
            row('Readings', '${inc.readings.length} from ${inc.controller}'),
            if (temps.isNotEmpty) row('Peak temperature', '${temps.reduce((a, b) => a > b ? a : b).toStringAsFixed(1)} °C'),
            if (smokes.isNotEmpty) row('Peak smoke', '${smokes.reduce((a, b) => a > b ? a : b).toStringAsFixed(0)} mV'),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                  onPressed: () {
                    Navigator.pop(ctx);
                    downloadIncidentPdf(context, inc);
                  },
                  child: const Text('Download PDF'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    sendIncidentToBfp(context, inc);
                  },
                  child: const Text('Send to BFP'),
                ),
              ),
            ]),
          ]),
        ),
      );
    },
  );
}

/// Events > Incident Reports: this home's fire / smoke / flame incidents,
/// each downloadable as a BFP-ready PDF (location map, floor plan, readings,
/// camera photos, verification QR code) or e-mailed to the BFP.
class IncidentReportsPanel extends StatefulWidget {
  const IncidentReportsPanel({super.key});

  @override
  State<IncidentReportsPanel> createState() => _IncidentReportsPanelState();
}

class _IncidentReportsPanelState extends State<IncidentReportsPanel> {
  /// -1 = recent (newest 10, any date), 0 = all, otherwise days.
  int _period = -1;
  bool _loading = true;
  String? _error;
  List<HomeIncident> _incidents = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = _period == -1
          ? await IncidentReportService.recentIncidents(count: 10)
          : await IncidentReportService.loadIncidents(days: _period);
      if (!mounted) return;
      setState(() {
        _incidents = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load incidents: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final latest = _incidents.isEmpty ? null : _incidents.first;
    return PgCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PgHeader(
          icon: Icons.description_outlined,
          title: 'Incident Reports',
          subtitle: 'BFP-ready PDF for each fire, smoke or flame incident: location map, floor plan, '
              'sensor readings, camera photos and a verification QR code.',
          actions: [
            IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20)),
          ],
        ),
        const SizedBox(height: 8),
        // Period filters on one line (scrolls sideways on narrow phones).
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final p in const [(-1, 'Recent'), (7, '7 days'), (30, '30 days'), (365, '1 year'), (0, 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(p.$2),
                  selected: _period == p.$1,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) {
                    setState(() => _period = p.$1);
                    _load();
                  },
                ),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        if (_loading) const LinearProgressIndicator(color: AppColors.orange),
        if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 12)),
        if (!_loading && _error == null && latest == null)
          Text('No fire, smoke or flame incidents in this period.', style: TextStyle(color: secondary, fontSize: 12.5)),
        if (latest != null)
          PgTile(
            color: incidentColor(latest.type),
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                PgBadge('LATEST', color: incidentColor(latest.type)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${latest.typeLabel} · ${latest.roomLabel}',
                      style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13.5)),
                ),
              ]),
              const SizedBox(height: 6),
              Text('${_fmt.format(latest.start)} · ${incidentDuration(latest)} · ${latest.readings.length} readings',
                  style: TextStyle(color: secondary, fontSize: 12)),
              Text(latest.reportNumber, style: TextStyle(color: secondary, fontSize: 11.5)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.red,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 42)),
                    onPressed: () => downloadIncidentPdf(context, latest),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const FittedBox(child: Text('Download PDF')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.brandForeground(context),
                        side: BorderSide(color: AppColors.orange.withValues(alpha: .6)),
                        minimumSize: const Size(0, 42)),
                    onPressed: () => sendIncidentToBfp(context, latest),
                    icon: const Icon(Icons.outgoing_mail, size: 18),
                    label: const FittedBox(child: Text('Send to BFP')),
                  ),
                ),
              ]),
            ]),
          ),
        if (_incidents.length > 1) ...[
          const SizedBox(height: 12),
          Text('Earlier incidents (${_incidents.length - 1})',
              style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
          const SizedBox(height: 4),
          for (final inc in _incidents.skip(1))
            InkWell(
              onTap: () => showIncidentSheet(context, inc),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  PgDot(incidentColor(inc.type)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${inc.typeLabel} · ${inc.roomLabel}',
                          style: TextStyle(color: primary, fontWeight: FontWeight.w700, fontSize: 12.5)),
                      Text('${_fmt.format(inc.start)} · ${incidentDuration(inc)}',
                          style: TextStyle(color: secondary, fontSize: 11.5)),
                    ]),
                  ),
                  // PDF and Send on one line, same size, aligned on every row.
                  _rowAction(Icons.picture_as_pdf_outlined, 'Download PDF', AppColors.red,
                      () => downloadIncidentPdf(context, inc)),
                  const SizedBox(width: 6),
                  _rowAction(Icons.outgoing_mail, 'Send to BFP', AppColors.orange,
                      () => sendIncidentToBfp(context, inc)),
                ]),
              ),
            ),
        ],
      ]),
    );
  }

  Widget _rowAction(IconData icon, String tip, Color color, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: .40)),
            ),
            child: Icon(icon, size: 19, color: AppTheme.statusForeground(context, color)),
          ),
        ),
      );
}
