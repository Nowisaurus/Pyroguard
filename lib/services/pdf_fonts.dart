import 'package:flutter/foundation.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Unicode fonts for every PyroGuard PDF (°, ±, ₱, ·, ñ ...). The built-in
/// Helvetica cannot show these. Loaded once; falls back to Helvetica offline.
Future<pw.ThemeData?>? _theme;

Future<pw.ThemeData?> pgPdfTheme() => _theme ??= () async {
      try {
        return pw.ThemeData.withFont(
          base: await PdfGoogleFonts.notoSansRegular(),
          bold: await PdfGoogleFonts.notoSansBold(),
          italic: await PdfGoogleFonts.notoSansItalic(),
          boldItalic: await PdfGoogleFonts.notoSansBoldItalic(),
        );
      } catch (e) {
        debugPrint('PDF fonts unavailable, using Helvetica: $e');
        _theme = null;
        return null;
      }
    }();
