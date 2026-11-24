import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../services/pdf_fonts.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme.dart';
import 'pg_ui.dart';

/// NCR minimum wage (Wage Order NCR-28, non-agriculture, effective
/// Sept 26, 2026): PHP 755 per 8-hour day.
const double kLaborRatePerHour = 755 / 8;

/// One price list for every home, kept in `pyroguard_cost_catalog`.
/// Only administrators can change it (RLS + admin console); homeowners see
/// it read-only and can download the pricing PDF.
class CostCatalog {
  CostCatalog._();
  static SupabaseClient get _db => Supabase.instance.client;
  static final peso = NumberFormat.currency(locale: 'en_US', symbol: '₱', decimalDigits: 2);

  static Future<List<Map<String, dynamic>>> load() async {
    final rows = await _db.from('pyroguard_cost_catalog').select().order('sort_order').order('id');
    return [for (final r in rows as List) Map<String, dynamic>.from(r as Map)];
  }

  static double n(dynamic v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
  static double line(Map<String, dynamic> i) => n(i['quantity']) * n(i['unit_price']);
  static double sum(List<Map<String, dynamic>> items, String cat) =>
      items.where((i) => i['category'] == cat).fold<double>(0, (s, i) => s + line(i));
  static String qty(double v) => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(2);

  static String checkedOn(List<Map<String, dynamic>> items) {
    DateTime? latest;
    for (final i in items) {
      final d = DateTime.tryParse('${i['price_checked_on'] ?? ''}');
      if (d != null && (latest == null || d.isAfter(latest))) latest = d;
    }
    return latest == null ? '-' : DateFormat('MMM d, yyyy').format(latest);
  }

  static Future<void> downloadPdf(List<Map<String, dynamic>> items) async {
    const red = PdfColor.fromInt(0xFFB91C1C);
    const grey = PdfColor.fromInt(0xFF555555);
    final money = NumberFormat('#,##0.00');
    final doc = pw.Document(theme: await pgPdfTheme(), title: 'PyroGuard Pricing');
    final hw = sum(items, 'Hardware'), labor = sum(items, 'Labor'), other = sum(items, 'Other');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      build: (_) => [
        pw.Text('PYROGUARD  |  HARDWARE AND LABOR PRICING',
            style: pw.TextStyle(color: red, fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text(
            'One complete home system: ESP32-001 (Entrance, Sala), ESP32-002 (Kitchen, Bedroom), DFR1154 Camera 1. '
            'Prices in Philippine pesos from Makerlab Electronics PH, checked ${checkedOn(items)}. '
            'Generated ${DateFormat('MMM d, yyyy h:mm a').format(DateTime.now())}.',
            style: const pw.TextStyle(fontSize: 9, color: grey)),
        pw.Divider(color: red),
        pw.TableHelper.fromTextArray(
          headers: ['Category', 'Item', 'Qty', 'Unit', 'Unit price', 'Amount'],
          data: [
            for (final i in items)
              [
                '${i['category']}',
                '${i['item']}${i['notes'] == null ? '' : ' (${i['notes']})'}',
                qty(n(i['quantity'])),
                '${i['unit']}',
                money.format(n(i['unit_price'])),
                money.format(line(i)),
              ],
          ],
          headerStyle: pw.TextStyle(color: PdfColors.white, fontSize: 8.5, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(color: red),
          cellStyle: const pw.TextStyle(fontSize: 8.5),
          columnWidths: {1: const pw.FlexColumnWidth(4)},
          cellAlignments: {2: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
        ),
        pw.SizedBox(height: 10),
        for (final row in [
          ('Hardware subtotal', hw),
          ('Labor subtotal', labor),
          if (other > 0) ('Other', other),
          ('TOTAL PER HOME SYSTEM', hw + labor + other),
        ])
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
            pw.SizedBox(
                width: 180,
                child: pw.Text(row.$1,
                    style: pw.TextStyle(fontSize: 10, fontWeight: row.$1.startsWith('TOTAL') ? pw.FontWeight.bold : null))),
            pw.SizedBox(
              width: 110,
              child: pw.Text('PHP ${money.format(row.$2)}',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(fontSize: 10, fontWeight: row.$1.startsWith('TOTAL') ? pw.FontWeight.bold : null)),
            ),
          ]),
        pw.SizedBox(height: 12),
        pw.Text(
          'Labor uses the NCR minimum wage under Wage Order NCR-28: PHP 755 per 8-hour day '
          '(PHP ${kLaborRatePerHour.toStringAsFixed(2)} per hour). Each sensor is a separate module, so a damaged '
          'sensor is replaced on its own. Prices are set by the PyroGuard administrator.',
          style: const pw.TextStyle(fontSize: 8.5, color: grey),
        ),
        pw.SizedBox(height: 8),
        pw.Text('Sources', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        for (final i in items.where((i) => i['source_url'] != null))
          pw.Text('${i['item']}: ${i['source_url']}', style: const pw.TextStyle(fontSize: 7, color: grey)),
      ],
    ));
    await Printing.sharePdf(bytes: await doc.save(), filename: 'PyroGuard_Pricing.pdf');
  }
}

/// Homeowner view: read-only price list plus "Download pricing PDF".
class CostEstimatePanel extends StatefulWidget {
  const CostEstimatePanel({super.key});

  @override
  State<CostEstimatePanel> createState() => _CostEstimatePanelState();
}

class _CostEstimatePanelState extends State<CostEstimatePanel> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load();
    // Price changes made by the admin show up here right away.
    _channel = Supabase.instance.client
        .channel('cost-catalog-${identityHashCode(this)}')
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'pyroguard_cost_catalog',
            callback: (_) => _load())
        .subscribe();
  }

  @override
  void dispose() {
    if (_channel != null) Supabase.instance.client.removeChannel(_channel!);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await CostCatalog.load();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Price list unavailable. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final hw = CostCatalog.sum(_items, 'Hardware');
    final labor = CostCatalog.sum(_items, 'Labor');
    final other = CostCatalog.sum(_items, 'Other');
    final total = hw + labor + other;

    Widget totalRow(String label, double v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: bold ? primary : secondary,
                      fontSize: bold ? 14 : 12.5,
                      fontWeight: bold ? FontWeight.w900 : FontWeight.w600)),
            ),
            Text(CostCatalog.peso.format(v),
                style: TextStyle(
                    color: primary, fontSize: bold ? 15 : 12.5, fontWeight: bold ? FontWeight.w900 : FontWeight.w700)),
          ]),
        );

    return PgCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PgHeader(
          icon: Icons.request_quote_outlined,
          title: 'Hardware & Labor Cost',
          subtitle: 'Original Makerlab Electronics PH prices for one complete system '
              '(2 ESP32 controllers, 4 rooms, Camera 1). Checked ${CostCatalog.checkedOn(_items)}.',
        ),
        const SizedBox(height: 6),
        Row(children: [
          const PgBadge('Set by admin', color: AppColors.amber),
          const Spacer(),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: Colors.white,
                visualDensity: VisualDensity.compact),
            onPressed: _items.isEmpty ? null : () => CostCatalog.downloadPdf(_items),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Download pricing PDF'),
          ),
        ]),
        if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(color: AppColors.orange)),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 11.5)),
          ),
        const SizedBox(height: 6),
        for (final cat in const ['Hardware', 'Labor', 'Other']) ...[
          if (_items.any((i) => i['category'] == cat))
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 2),
              child: Text(cat.toUpperCase(),
                  style: TextStyle(color: secondary, fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: .6)),
            ),
          for (final i in _items.where((i) => i['category'] == cat))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${i['item']}', style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Text(
                        '${CostCatalog.qty(CostCatalog.n(i['quantity']))} ${i['unit']} × '
                        '${CostCatalog.peso.format(CostCatalog.n(i['unit_price']))}'
                        '${i['notes'] == null ? '' : '  ·  ${i['notes']}'}',
                        style: TextStyle(color: secondary, fontSize: 11)),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(CostCatalog.peso.format(CostCatalog.line(i)),
                    style: TextStyle(color: primary, fontSize: 12.5, fontWeight: FontWeight.w700)),
              ]),
            ),
        ],
        Divider(color: AppTheme.border(context), height: 20),
        totalRow('Hardware subtotal', hw),
        totalRow('Labor subtotal', labor),
        if (other > 0) totalRow('Other', other),
        totalRow('Total per home system', total, bold: true),
        const SizedBox(height: 6),
        Text(
          'Labor: NCR minimum wage PHP 755/day under Wage Order NCR-28 '
          '(PHP ${kLaborRatePerHour.toStringAsFixed(2)}/hour). Only the administrator can change prices.',
          style: TextStyle(color: secondary, fontSize: 11),
        ),
      ]),
    );
  }
}
