import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'pdf_fonts.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Defense panel: "pwede ma-download ang events". Exports the event history
/// (fire, smoke, door/window, motion, arming, device events) as a PDF.
class EventsExportService {
  EventsExportService._();

  static final _dt = DateFormat('MMM d, yyyy h:mm:ss a');

  static String _severity(dynamic v) => switch ((v as num?)?.toInt() ?? 0) {
        >= 2 => 'Critical',
        1 => 'Warning',
        _ => 'Normal',
      };

  /// [days] = 0 exports everything (up to 5,000 newest events).
  static Future<int> downloadPdf({int days = 30}) async {
    final db = Supabase.instance.client;
    var q = db.from('event_history').select('device_id,event_type,message,severity,created_at');
    if (days > 0) {
      q = q.gte('created_at', DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String());
    }
    final rows = [
      for (final r in await q.order('created_at', ascending: false).limit(5000) as List)
        Map<String, dynamic>.from(r as Map)
    ];
    final counts = <String, int>{};
    for (final r in rows) {
      final s = _severity(r['severity']);
      counts[s] = (counts[s] ?? 0) + 1;
    }

    const red = PdfColor.fromInt(0xFFB91C1C);
    const grey = PdfColor.fromInt(0xFF555555);
    const light = PdfColor.fromInt(0xFFFDF2F2);
    final doc = pw.Document(theme: await pgPdfTheme(), title: 'PyroGuard Event History');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      header: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('PYROGUARD  |  EVENT HISTORY',
            style: pw.TextStyle(color: red, fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text(
          '${days > 0 ? 'Last $days days' : 'All recorded events'} · ${rows.length} events '
          '(${counts['Critical'] ?? 0} critical, ${counts['Warning'] ?? 0} warning, ${counts['Normal'] ?? 0} normal) · '
          'generated ${_dt.format(DateTime.now())} (PH time)',
          style: const pw.TextStyle(fontSize: 8, color: grey),
        ),
        pw.Divider(color: red),
      ]),
      footer: (ctx) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey)),
      ),
      build: (_) => [
        if (rows.isEmpty)
          pw.Text('No events in this period.')
        else
          pw.TableHelper.fromTextArray(
            headers: ['Date and time', 'Device', 'Event', 'Level', 'Details'],
            data: [
              for (final r in rows)
                [
                  _dt.format(DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now()),
                  '${r['device_id'] ?? '-'}',
                  '${r['event_type'] ?? '-'}'.replaceAll('_', ' '),
                  _severity(r['severity']),
                  '${r['message'] ?? ''}',
                ],
            ],
            headerStyle: pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: red),
            cellStyle: const pw.TextStyle(fontSize: 7.5),
            oddRowDecoration: const pw.BoxDecoration(color: light),
            columnWidths: {
              0: const pw.FixedColumnWidth(92),
              1: const pw.FixedColumnWidth(62),
              2: const pw.FixedColumnWidth(80),
              3: const pw.FixedColumnWidth(42),
              4: const pw.FlexColumnWidth(),
            },
          ),
      ],
    ));
    await Printing.sharePdf(
        bytes: await doc.save(),
        filename: 'PyroGuard_Events_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf');
    return rows.length;
  }
}
