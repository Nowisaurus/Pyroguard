import 'package:flutter/material.dart';
import 'pg_notice.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../services/pdf_fonts.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/room_sensor_service.dart';
import '../theme.dart';
import 'pg_ui.dart';

/// Rated ranges of the actual modules, as listed by Makerlab Electronics PH.
class SensorSpec {
  const SensorSpec(this.sensor, this.measures, this.rated, this.accuracy, this.power, this.source);
  final String sensor, measures, rated, accuracy, power, source;
}

const kSensorSpecs = <SensorSpec>[
  SensorSpec('DHT22', 'Temperature', '-40 to 80 °C', '±0.5 °C', '3-5 V, 1 reading every 2 s',
      'https://makerlab.ph/products/dht22-temperature-humidity-sensor-module'),
  SensorSpec('DHT22', 'Humidity', '0 to 100 %RH', '±2-5 %RH', '3-5 V, 1 reading every 2 s',
      'https://makerlab.ph/products/dht22-temperature-humidity-sensor-module'),
  SensorSpec('MQ-2', 'LPG / propane / butane', '200 to 5000 ppm', 'Analog output', '5 V heater, 48 h first preheat',
      'https://makerlab.ph/products/mq2-smoke-gas-sensor'),
  SensorSpec('MQ-2', 'Alcohol / CO', '100 to 2000 ppm', 'Analog output', 'Works at -10 to 50 °C, up to 95 %RH',
      'https://makerlab.ph/products/mq2-smoke-gas-sensor'),
  SensorSpec('MQ-2', 'Hydrogen / methane', '300-5000 / 5000-20000 ppm', 'Analog output', '5 V heater',
      'https://makerlab.ph/products/mq2-smoke-gas-sensor'),
  SensorSpec('Flame', 'Infrared flame light', '760 to 1100 nm, 0-60° angle', 'D0 goes LOW on flame', '3.3-5 V',
      'https://makerlab.ph/products/flame-sensor-module'),
];

// Limits used to flag recorded values.
const double kDhtTempMin = -40, kDhtTempMax = 80;
const double kDhtHumMin = 0, kDhtHumMax = 100;
const double kMq2OperTempMin = -10, kMq2OperTempMax = 50, kMq2OperHumMax = 95;

/// Monitoring panel: ranges actually recorded by each room's sensors (from
/// every reading in Supabase) next to the module's rated range. Values
/// outside the rated or operating range are flagged.
class TestingDataPanel extends StatefulWidget {
  const TestingDataPanel({super.key});

  @override
  State<TestingDataPanel> createState() => _TestingDataPanelState();
}

class _TestingDataPanelState extends State<TestingDataPanel> {
  static final _d = DateFormat('MMM d, yyyy');
  static final _dt = DateFormat('MMM d, yyyy h:mm a');
  SupabaseClient get _db => Supabase.instance.client;

  List<Map<String, dynamic>> _stats = const [];
  bool _loading = true;
  bool _pdfBusy = false;
  String? _error;

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
      final s = await _db.rpc('pyroguard_reading_stats', params: {'days': 0});
      _stats = [for (final r in s as List) Map<String, dynamic>.from(r as Map)];
    } catch (e) {
      _error = 'Recorded ranges unavailable. Pull to refresh or try again.';
    }
    if (mounted) setState(() => _loading = false);
  }

  double? _v(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');

  String _n(dynamic v, [String unit = '']) {
    final x = _v(v);
    if (x == null) return '-';
    return '${x % 1 == 0 ? x.toInt() : x.toStringAsFixed(1)}$unit';
  }

  String _room(Map<String, dynamic> r) =>
      RoomSensorService.label('${r['controller_device_id'] ?? ''}', '${r['room_key']}');

  /// Notes on recorded values outside the rated / operating range.
  List<String> _flags(Map<String, dynamic> s) {
    final tMin = _v(s['temp_min']), tMax = _v(s['temp_max']);
    final hMin = _v(s['hum_min']), hMax = _v(s['hum_max']);
    return [
      if ((tMin != null && tMin < kDhtTempMin) || (tMax != null && tMax > kDhtTempMax))
        'Temperature outside the DHT22 rated range (-40 to 80 °C)',
      if ((hMin != null && hMin < kDhtHumMin) || (hMax != null && hMax > kDhtHumMax))
        'Humidity outside the DHT22 rated range (0 to 100 %RH)',
      if ((tMin != null && tMin < kMq2OperTempMin) || (tMax != null && tMax > kMq2OperTempMax))
        'Room temperature outside the MQ-2 operating range (-10 to 50 °C)',
      if (hMax != null && hMax > kMq2OperHumMax) 'Humidity above the MQ-2 operating limit (95 %RH)',
    ];
  }

  Future<void> _downloadPdf() async {
    setState(() => _pdfBusy = true);
    try {
      const red = PdfColor.fromInt(0xFFB91C1C);
      const grey = PdfColor.fromInt(0xFF555555);
      final doc = pw.Document(theme: await pgPdfTheme(), title: 'PyroGuard Sensor Ranges');
      pw.Widget h(String t) => pw.Padding(
            padding: const pw.EdgeInsets.only(top: 12, bottom: 6),
            child: pw.Text(t, style: pw.TextStyle(color: red, fontSize: 12, fontWeight: pw.FontWeight.bold)),
          );
      final head = pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold);
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('PYROGUARD  |  SENSOR RANGES REPORT',
              style: pw.TextStyle(color: red, fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('Real readings from Supabase. Generated ${_dt.format(DateTime.now())}',
              style: const pw.TextStyle(fontSize: 8, color: grey)),
          pw.Divider(color: red),
        ]),
        footer: (ctx) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey)),
        ),
        build: (_) => [
          h('1. Rated ranges of the modules (Makerlab Electronics PH)'),
          pw.TableHelper.fromTextArray(
            headers: ['Sensor', 'Measures', 'Rated range', 'Accuracy / output', 'Power / conditions'],
            data: [
              for (final s in kSensorSpecs)
                [s.sensor, s.measures, s.rated.replaceAll('°', ' deg'), s.accuracy, s.power.replaceAll('°', ' deg')],
            ],
            headerStyle: head,
            headerDecoration: const pw.BoxDecoration(color: red),
            cellStyle: const pw.TextStyle(fontSize: 8),
          ),
          h('2. Ranges recorded in each room'),
          pw.TableHelper.fromTextArray(
            headers: ['Room', 'Readings', 'Period', 'Temp min / max / avg (C)', 'Humidity min / max / avg (%)',
              'Max smoke (mV)', 'Smoke alarms', 'Flame events', 'Fires', 'Within rated range'],
            data: [
              for (final s in _stats)
                [
                  _room(s),
                  '${s['readings']}',
                  '${_d.format(DateTime.parse('${s['first_at']}').toLocal())} - ${_d.format(DateTime.parse('${s['last_at']}').toLocal())}',
                  '${_n(s['temp_min'])} / ${_n(s['temp_max'])} / ${_n(s['temp_avg'])}',
                  '${_n(s['hum_min'])} / ${_n(s['hum_max'])} / ${_n(s['hum_avg'])}',
                  _n(s['smoke_max']),
                  '${s['smoke_alarms']}',
                  '${s['flame_events']}',
                  '${s['fires']}',
                  _flags(s).isEmpty ? 'Yes' : _flags(s).join('; ').replaceAll('°', ' deg'),
                ],
            ],
            headerStyle: head,
            headerDecoration: const pw.BoxDecoration(color: red),
            cellStyle: const pw.TextStyle(fontSize: 8),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'The MQ-2 value is the analog output in millivolts read by the ESP32; the module is rated in ppm for each gas. '
            'Sources: ${{for (final s in kSensorSpecs) s.source}.join('  ')}',
            style: const pw.TextStyle(fontSize: 7.5, color: grey),
          ),
        ],
      ));
      await Printing.sharePdf(bytes: await doc.save(), filename: 'PyroGuard_Sensor_Ranges.pdf');
    } catch (e) {
      if (mounted) PgNotice.show('Could not create the PDF: $e', kind: PgNoticeKind.error);
    } finally {
      if (mounted) setState(() => _pdfBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);

    return PgCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PgHeader(
          icon: Icons.science_outlined,
          title: 'Sensor Ranges',
          subtitle: 'What each room\'s sensors actually recorded, compared with the module\'s rated range.',
          actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: Icon(Icons.refresh, color: secondary, size: 20))],
        ),
        if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(color: AppColors.orange)),
        if (_error != null) Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 11.5)),
        const SizedBox(height: 10),
        Text('Rated range (Makerlab)', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        PgTile(
          child: Column(children: [
            for (final s in kSensorSpecs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    width: 52,
                    child: Text(s.sensor, style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12)),
                  ),
                  Expanded(
                    child: Text('${s.measures}: ${s.rated}', style: TextStyle(color: primary, fontSize: 12)),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(s.accuracy,
                        textAlign: TextAlign.right, style: TextStyle(color: secondary, fontSize: 11)),
                  ),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        Text('Recorded in each room', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13)),
        const SizedBox(height: 6),
        if (!_loading && _stats.isEmpty)
          Text('No readings received yet.', style: TextStyle(color: secondary, fontSize: 12)),
        for (final s in _stats) _roomTile(s, primary, secondary),
        const SizedBox(height: 8),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.orange, foregroundColor: Colors.white),
          onPressed: _pdfBusy || _stats.isEmpty ? null : _downloadPdf,
          icon: const Icon(Icons.download_outlined, size: 18),
          label: Text(_pdfBusy ? 'Preparing...' : 'Download sensor ranges (PDF)'),
        ),
      ]),
    );
  }

  Widget _roomTile(Map<String, dynamic> s, Color primary, Color secondary) {
    final flags = _flags(s);
    final ok = flags.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PgTile(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_room(s), style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13))),
            PgBadge(ok ? 'Within rated range' : 'Check', color: ok ? AppColors.green : AppColors.amber),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: _metric('Temperature', '${_n(s['temp_min'])} to ${_n(s['temp_max'])} °C',
                'avg ${_n(s['temp_avg'])} °C · rated -40 to 80')),
            Expanded(child: _metric('Humidity', '${_n(s['hum_min'])} to ${_n(s['hum_max'])} %',
                'avg ${_n(s['hum_avg'])} % · rated 0 to 100')),
          ]),
          const SizedBox(height: 4),
          Text(
            '${s['readings']} readings · max smoke ${_n(s['smoke_max'])} mV · ${s['smoke_alarms']} smoke alarms · '
            '${s['flame_events']} flame events · ${s['fires']} confirmed fires',
            style: TextStyle(color: secondary, fontSize: 11.5),
          ),
          for (final f in flags)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(f, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 11.5)),
            ),
        ]),
      ),
    );
  }

  Widget _metric(String label, String value, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11)),
        Text(value, style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800, fontSize: 13)),
        Text(sub, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5)),
      ]);
}
