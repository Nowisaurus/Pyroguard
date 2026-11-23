import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:flutter/services.dart' show rootBundle;

import '../widgets/evacuation_guide.dart' show loadHomeLayout, LayoutItem, kFloorPlanAsset, kPlanOffsetM, kPlanSizeM;
import 'location_service.dart';

import 'room_sensor_service.dart';

/// One fire / smoke / flame incident at this home: consecutive hazard
/// readings in the same room (less than 10 minutes apart).
class HomeIncident {
  HomeIncident({
    required this.start,
    required this.end,
    required this.controller,
    required this.room,
    required this.type,
    required this.readings,
  });
  final DateTime start;
  DateTime end;
  final String controller;
  final String room;
  String type; // FIRE, SMOKE, FLAME
  final List<Map<String, dynamic>> readings;

  String get roomLabel => RoomSensorService.label(controller, room);
  String get typeLabel => switch (type) {
        'FIRE' => 'Confirmed fire (flame + smoke)',
        'SMOKE' => 'Smoke / gas detected',
        _ => 'Flame detected',
      };
  String get reportNumber =>
      'PG-${DateFormat('yyyyMMdd-HHmm').format(start)}-${room.toUpperCase()}';
}

/// Builds a downloadable PDF incident report for the Bureau of Fire
/// Protection (panel suggestion: "the incident can be downloaded as a PDF and
/// sent to the BFP for their records").
class IncidentReportService {
  IncidentReportService._();

  static final _db = Supabase.instance.client;

  /// Public page where the BFP checks a report against the server records.
  /// (web/verify.html on Vercel; it calls the verify-incident-report function.)
  static const verifyBaseUrl = 'https://pyroguard-chi.vercel.app/verify.html';
  static final _dt = DateFormat('MMM d, yyyy  h:mm:ss a');
  static final _time = DateFormat('h:mm:ss a');

  /// This home's incidents (newest first). [days] = 0 means all recorded
  /// incidents (the newest 5,000 hazard readings are grouped).
  static Future<List<HomeIncident>> loadIncidents({int days = 365}) async {
    var q = _db
        .from('pyroguard_room_sensor_readings')
        .select('controller_device_id,room_key,temperature,humidity,smoke_raw,smoke_status,'
            'flame_detected,fire_confirmed,buzzer_active,flame_fault,smoke_fault,received_at')
        .or('fire_confirmed.eq.true,smoke_status.eq.ALARM,flame_detected.eq.true');
    if (days > 0) {
      q = q.gte('received_at', DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String());
    }
    final newestFirst = await q.order('received_at', ascending: false).limit(5000);
    final rows = (newestFirst as List).reversed.toList();
    final incidents = <HomeIncident>[];
    final open = <String, HomeIncident>{};
    for (final raw in rows) {
      final r = Map<String, dynamic>.from(raw as Map);
      final when = DateTime.tryParse('${r['received_at']}')?.toLocal();
      if (when == null) continue;
      final controller = '${r['controller_device_id'] ?? ''}';
      final room = '${r['room_key'] ?? ''}';
      final key = '$controller/$room';
      final type = r['fire_confirmed'] == true
          ? 'FIRE'
          : '${r['smoke_status']}'.toUpperCase() == 'ALARM'
              ? 'SMOKE'
              : 'FLAME';
      final current = open[key];
      if (current != null && when.difference(current.end).inMinutes < 10) {
        current.end = when;
        current.readings.add(r);
        if (type == 'FIRE') current.type = 'FIRE';
        continue;
      }
      final inc = HomeIncident(
          start: when, end: when, controller: controller, room: room, type: type, readings: [r]);
      open[key] = inc;
      incidents.add(inc);
    }
    incidents.sort((a, b) => b.start.compareTo(a.start));
    return incidents;
  }

  /// The most recent incident (optionally for one controller / room).
  /// The [count] most recent incidents, whatever their date.
  static Future<List<HomeIncident>> recentIncidents({int count = 10}) async =>
      (await loadIncidents(days: 0)).take(count).toList();

  static Future<HomeIncident?> latestIncident({String? controller, String? room, int days = 30}) async {
    final list = await loadIncidents(days: days);
    for (final i in list) {
      if ((controller == null || i.controller == controller) && (room == null || i.room == room)) return i;
    }
    return list.isEmpty ? null : list.first;
  }

  /// Camera photos for the incident: fire-alarm photos first, then the
  /// photos closest to the first detection (10 minutes before to 10 minutes
  /// after). Returns up to [max] in time order.
  static Future<List<_Photo>> _loadPhotos(HomeIncident inc, {int max = 4}) async {
    final out = <_Photo>[];
    try {
      final rows = await _db
          .from('camera_events')
          .select('device_id,event_type,snapshot_url,payload_json,created_at')
          .not('snapshot_url', 'is', 'null')
          .gte('created_at', inc.start.subtract(const Duration(minutes: 10)).toUtc().toIso8601String())
          .lte('created_at', inc.end.add(const Duration(minutes: 10)).toUtc().toIso8601String())
          .order('created_at', ascending: true)
          .limit(200);
      final list = [for (final x in rows as List) Map<String, dynamic>.from(x as Map)];
      int rank(Map<String, dynamic> m) {
        final t = '${m['event_type'] ?? ''}'.toLowerCase();
        return t.contains('fire') ? 0 : t.contains('intrusion') ? 1 : t.contains('manual') ? 2 : 3;
      }

      Duration gap(Map<String, dynamic> m) {
        final t = DateTime.tryParse('${m['created_at']}')?.toLocal() ?? inc.start;
        return t.difference(inc.start).abs();
      }

      list.sort((a, b) {
        final c = rank(a).compareTo(rank(b));
        return c != 0 ? c : gap(a).compareTo(gap(b));
      });
      for (final m in list) {
        if (out.length >= max) break;
        final when = DateTime.tryParse('${m['created_at']}')?.toLocal();
        final url = '${m['snapshot_url'] ?? ''}';
        if (when == null || url.isEmpty) continue;
        Uint8List? bytes;
        final path = (m['payload_json'] is Map) ? '${(m['payload_json'] as Map)['storage_path'] ?? ''}' : '';
        if (path.isNotEmpty) {
          try {
            bytes = await _db.storage.from('incident-media').download(path).timeout(const Duration(seconds: 12));
          } catch (_) {}
        }
        if (bytes == null || bytes.isEmpty) {
          try {
            final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
            if (res.statusCode == 200) bytes = res.bodyBytes;
          } catch (_) {}
        }
        if (bytes == null || bytes.isEmpty) continue;
        final t = '${m['event_type'] ?? ''}'.toLowerCase();
        out.add(_Photo(
          when: when,
          url: url,
          bytes: bytes,
          kind: t.contains('fire')
              ? 'Fire alarm photo'
              : t.contains('intrusion')
                  ? 'Intrusion alarm photo'
                  : t.contains('manual')
                      ? 'Manual capture'
                      : 'Motion photo',
          camera: '${m['device_id'] ?? 'camera'}',
        ));
      }
    } catch (_) {}
    out.sort((a, b) => a.when.compareTo(b.when));
    return out;
  }

  /// SHA-256 over the readings and photo files: any change to the data gives
  /// a different fingerprint, so the BFP can check the PDF against the server.
  static String _fingerprint(HomeIncident inc, List<_Photo> photos) {
    final lines = <String>[
      'PYROGUARD-REPORT-V1',
      inc.reportNumber,
      inc.controller,
      inc.room,
      inc.type,
      inc.start.toUtc().toIso8601String(),
      inc.end.toUtc().toIso8601String(),
      for (final r in inc.readings)
        [
          r['received_at'], r['temperature'], r['humidity'], r['smoke_raw'], r['smoke_status'],
          r['flame_detected'], r['fire_confirmed'], r['buzzer_active'],
        ].map((v) => '${v ?? ''}').join('|'),
      for (final p in photos) 'photo|${p.url}|${sha256.convert(p.bytes)}',
    ];
    return sha256.convert(utf8.encode(lines.join('\n'))).toString();
  }

  /// Registers the report on the server so the verification page can find it.
  static Future<bool> _register(HomeIncident inc, List<_Photo> photos, String hash, String code) async {
    try {
      await _db.from('pyroguard_incident_reports').upsert({
        'user_id': _db.auth.currentUser?.id,
        'report_number': inc.reportNumber,
        'controller_id': inc.controller,
        'room_key': inc.room,
        'incident_type': inc.type,
        'first_detected': inc.start.toUtc().toIso8601String(),
        'last_detected': inc.end.toUtc().toIso8601String(),
        'reading_count': inc.readings.length,
        'photo_urls': [for (final p in photos) p.url],
        'data_sha256': hash,
        'verify_code': code,
        'area_label': inc.roomLabel,
        'generated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id,report_number').timeout(const Duration(seconds: 12));
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Builds the report and downloads it (web) / opens the share sheet
  /// (phone: save to Files, email, Messenger...).
  static Future<void> download(HomeIncident incident) async {
    final bytes = await buildPdf(incident);
    await Printing.sharePdf(bytes: bytes, filename: 'PyroGuard_Incident_${incident.reportNumber}.pdf');
  }

  /// The saved primary BFP contact (station, e-mail ...) or an empty map.
  static Future<Map<String, dynamic>> bfpContact() async {
    final uid = _db.auth.currentUser?.id ?? '';
    return _single(() => _db.from('emergency_contacts').select()
        .eq('user_id', uid).eq('is_primary', true).maybeSingle());
  }

  /// Builds the PDF and e-mails it to the saved BFP station e-mail (copy to
  /// the homeowner) through the send-incident-report Edge Function.
  /// Returns the address it was sent to; throws a readable message on failure.
  static Future<String> emailToBfp(HomeIncident inc) async {
    final bytes = await buildPdf(inc);
    final fmt = DateFormat('MMM d, yyyy h:mm:ss a');
    try {
      final res = await _db.functions.invoke('send-incident-report', body: {
        'report_number': inc.reportNumber,
        'pdf_base64': base64Encode(bytes),
        'summary': {
          'room': inc.roomLabel,
          'type': inc.typeLabel,
          'first_detected': '${fmt.format(inc.start)} (PH time)',
          'last_detected': '${fmt.format(inc.end)} (PH time)',
        },
      }).timeout(const Duration(seconds: 60));
      final data = res.data is Map ? Map<String, dynamic>.from(res.data as Map) : <String, dynamic>{};
      if (data['ok'] != true) throw Exception(data['error'] ?? 'E-mail could not be sent.');
      return '${data['sent_to']}';
    } on FunctionException catch (e) {
      final d = e.details;
      throw Exception(d is Map ? (d['error'] ?? 'E-mail could not be sent.') : 'E-mail service is unavailable (${e.status}).');
    }
  }

  static Future<Map<String, dynamic>> _single(Future<dynamic> Function() q) async {
    try {
      final v = await q().timeout(const Duration(seconds: 12));
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Future<Uint8List> buildPdf(HomeIncident inc) async {
    final user = _db.auth.currentUser;
    final uid = user?.id ?? '';
    final profile = await _single(() => _db.from('profiles').select().eq('id', uid).maybeSingle());
    var home = await _single(() => _db.from('homes').select().eq('user_id', uid).maybeSingle());
    if (home.isEmpty) {
      final m = await _single(() => _db.from('pyroguard_home_members').select('home_id')
          .eq('user_id', uid).eq('membership_status', 'approved').limit(1).maybeSingle());
      if (m['home_id'] != null) {
        home = await _single(() => _db.from('homes').select().eq('id', m['home_id']).maybeSingle());
      }
    }
    final bfp = await _single(() => _db.from('emergency_contacts').select()
        .eq('user_id', uid).eq('is_primary', true).maybeSingle());

    // Camera photos, fingerprint and server registration (authenticity).
    final photos = await _loadPhotos(inc);
    final hash = _fingerprint(inc, photos);
    final code = hash.substring(0, 16).toUpperCase();
    final codeText = [for (var i = 0; i < 16; i += 4) code.substring(i, i + 4)].join('-');
    final registered = await _register(inc, photos, hash, code);
    final verifyUrl = '$verifyBaseUrl?r=${Uri.encodeQueryComponent(inc.reportNumber)}&c=$code';
    final cameraViewsRoom = inc.controller == 'ESP32-001';

    String v(Map<String, dynamic> m, String k, [String fallback = 'Not provided']) {
      final s = '${m[k] ?? ''}'.trim();
      return s.isEmpty ? fallback : s;
    }

    final meta = user?.userMetadata ?? const <String, dynamic>{};
    final lat = (home['latitude'] as num?)?.toDouble() ?? double.tryParse('${meta['home_latitude'] ?? ''}');
    final lng = (home['longitude'] as num?)?.toDouble() ?? double.tryParse('${meta['home_longitude'] ?? ''}');
    // Where it happened: street map of the home + floor plan with the room.
    String? mapAddress;
    pw.Widget? mapImage;
    if (lat != null && lng != null) {
      try {
        mapAddress = await LocationService.resolvePlaceName(lat, lng).timeout(const Duration(seconds: 8));
      } catch (_) {}
      mapImage = await _locationMap(lat, lng);
    }
    final layout = await loadHomeLayout();
    final floorPlan = await _floorPlan(layout.items, inc);
    final temps = inc.readings.map((r) => (r['temperature'] as num?)?.toDouble()).whereType<double>();
    final smokes = inc.readings.map((r) => (r['smoke_raw'] as num?)?.toDouble()).whereType<double>();
    final peakTemp = temps.isEmpty ? null : temps.reduce((a, b) => a > b ? a : b);
    final peakSmoke = smokes.isEmpty ? null : smokes.reduce((a, b) => a > b ? a : b);
    final buzzer = inc.readings.any((r) => r['buzzer_active'] == true);
    final dur = inc.end.difference(inc.start);
    final durText = dur.inMinutes >= 1
        ? '${dur.inMinutes} min ${dur.inSeconds % 60} s'
        : '${dur.inSeconds} s (single detection window)';
    final ongoing = DateTime.now().difference(inc.end).inMinutes < 10;

    const red = PdfColor.fromInt(0xFFB91C1C);
    const maroon = PdfColor.fromInt(0xFF450A0A);
    const grey = PdfColor.fromInt(0xFF555555);
    const light = PdfColor.fromInt(0xFFFDF2F2);

    pw.Widget section(String title) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 12, bottom: 4),
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          color: maroon,
          child: pw.Text(title.toUpperCase(),
              style: pw.TextStyle(color: PdfColors.white, fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
        );
    pw.Widget row(String label, String value) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.SizedBox(width: 130, child: pw.Text(label, style: const pw.TextStyle(color: grey, fontSize: 9))),
            pw.Expanded(child: pw.Text(value, style: const pw.TextStyle(fontSize: 9.5))),
          ]),
        );

    final shown = inc.readings.length > 40 ? inc.readings.sublist(inc.readings.length - 40) : inc.readings;
    final doc = pw.Document(title: 'PyroGuard Incident Report ${inc.reportNumber}', author: 'PyroGuard');
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(32, 28, 32, 28),
      header: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(children: [
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('PYROGUARD  |  FIRE / SMOKE INCIDENT REPORT',
                style: pw.TextStyle(color: red, fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Text('Prepared for the Bureau of Fire Protection (BFP) - for official records',
                style: const pw.TextStyle(color: grey, fontSize: 9)),
          ])),
          pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
            pw.Text('Report No. ${inc.reportNumber}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            pw.Text('Generated ${_dt.format(DateTime.now())}', style: const pw.TextStyle(fontSize: 8, color: grey)),
          ]),
        ]),
        pw.Divider(color: red, thickness: 1.2),
      ]),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('PyroGuard Home Monitoring & Security - automatically recorded sensor data',
            style: const pw.TextStyle(fontSize: 7.5, color: grey)),
        pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 7.5, color: grey)),
      ]),
      build: (ctx) => [
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(color: light, border: pw.Border.all(color: red, width: .8)),
          child: pw.Row(children: [
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text(inc.typeLabel.toUpperCase(),
                  style: pw.TextStyle(color: red, fontSize: 13, fontWeight: pw.FontWeight.bold)),
              pw.Text('${inc.roomLabel}  |  ${_dt.format(inc.start)}', style: const pw.TextStyle(fontSize: 10)),
            ])),
            pw.Text(ongoing ? 'STATUS: ONGOING' : 'STATUS: CLEARED',
                style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: ongoing ? red : grey)),
          ]),
        ),
        section('1. Reporting party'),
        row('Homeowner', v(profile, 'full_name', v(user?.userMetadata ?? {}, 'full_name'))),
        row('Contact number', v(profile, 'phone', v(user?.userMetadata ?? {}, 'phone_number'))),
        row('Email', v(profile, 'email', user?.email ?? 'Not provided')),
        row('Household', v(home, 'home_name')),
        section('2. Incident location'),
        row('Address on file', v(home, 'address', '${meta['address'] ?? 'Not provided'}')),
        if (mapAddress != null) row('Address at GPS point', mapAddress),
        row('Barangay / City', '${v(home, 'barangay', '-')} / ${v(home, 'city', '-')}'),
        row('GPS coordinates', lat != null && lng != null
            ? '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'
            : 'Not provided'),
        if (lat != null && lng != null)
          row('Map link', 'https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
        row('Room / area', '${inc.roomLabel}  (controller ${inc.controller})'),
        pw.SizedBox(height: 6),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (mapImage != null)
            pw.Expanded(
              flex: 3,
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                pw.Text('Street map (red dot = incident location)', style: const pw.TextStyle(fontSize: 8, color: grey)),
                pw.SizedBox(height: 2),
                mapImage,
                pw.Text('Map data: OpenStreetMap contributors', style: const pw.TextStyle(fontSize: 6.5, color: grey)),
              ]),
            ),
          if (mapImage != null) pw.SizedBox(width: 10),
          pw.Expanded(
            flex: 2,
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.Text('Floor plan (red = room where it was detected)',
                  style: const pw.TextStyle(fontSize: 8, color: grey)),
              pw.SizedBox(height: 2),
              floorPlan,
            ]),
          ),
        ]),
        section('3. Incident summary'),
        row('Detection type', inc.typeLabel),
        row('First detected', _dt.format(inc.start)),
        row('Last detected', _dt.format(inc.end)),
        row('Duration', durText),
        row('Peak temperature', peakTemp == null ? 'Not recorded' : '${peakTemp.toStringAsFixed(1)} °C'),
        row('Peak smoke/gas reading', peakSmoke == null ? 'Not recorded' : '${peakSmoke.round()} mV (MQ-2 sensor)'),
        row('Local alarm', buzzer ? 'Buzzer sounded at the location' : 'No buzzer activation recorded'),
        row('Readings recorded', '${inc.readings.length}'),
        row('Camera photos', photos.isEmpty ? 'None saved' : '${photos.length} attached (section 5)'),
        row('Verification code', '$codeText  (see section 6)'),
        section('4. Sensor readings (Philippine time)'),
        pw.TableHelper.fromTextArray(
          headers: ['Time', 'Temp °C', 'Hum %', 'Smoke', 'Smoke mV', 'Flame', 'Fire', 'Buzzer'],
          data: [
            for (final r in shown)
              [
                _time.format(DateTime.tryParse('${r['received_at']}')?.toLocal() ?? inc.start),
                (r['temperature'] as num?)?.toStringAsFixed(1) ?? '-',
                (r['humidity'] as num?)?.toStringAsFixed(0) ?? '-',
                '${r['smoke_status'] ?? '-'}',
                (r['smoke_raw'] as num?)?.round().toString() ?? '-',
                r['flame_detected'] == true ? 'YES' : 'no',
                r['fire_confirmed'] == true ? 'YES' : 'no',
                r['buzzer_active'] == true ? 'ON' : 'off',
              ],
          ],
          headerStyle: pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold),
          headerDecoration: const pw.BoxDecoration(color: red),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellAlignment: pw.Alignment.center,
          oddRowDecoration: const pw.BoxDecoration(color: light),
        ),
        if (inc.readings.length > shown.length)
          pw.Text('Showing the last ${shown.length} of ${inc.readings.length} readings.',
              style: const pw.TextStyle(fontSize: 8, color: grey)),
        section('5. Camera evidence'),
        pw.Text(
          cameraViewsRoom
              ? 'Photos saved automatically by PyroGuard Camera 1 (it covers the Entrance and Sala), '
                  'fire-alarm photos first. Original files are kept on the PyroGuard server.'
              : 'PyroGuard Camera 1 covers the Entrance and Sala; it does not view the ${inc.roomLabel}. '
                  'The photos show the home at the time of the alarm. Original files are kept on the PyroGuard server.',
          style: const pw.TextStyle(fontSize: 8.5, color: grey),
        ),
        pw.SizedBox(height: 6),
        if (photos.isEmpty)
          pw.Text('No camera photos were saved from 10 minutes before to 10 minutes after this incident.',
              style: const pw.TextStyle(fontSize: 9))
        else
          pw.Wrap(spacing: 10, runSpacing: 10, children: [
            for (final p in photos)
              pw.Container(
                width: 250,
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: .6)),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                  pw.Image(pw.MemoryImage(p.bytes), width: 250, height: 188, fit: pw.BoxFit.cover),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
                      pw.Text('${p.kind}  |  ${_dt.format(p.when)}',
                          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      pw.Text('${_offset(p.when.difference(inc.start))} first detection  |  ${p.camera}',
                          style: const pw.TextStyle(fontSize: 7.5, color: grey)),
                    ]),
                  ),
                ]),
              ),
          ]),
        section('6. Authenticity and verification'),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              row('Data source', 'Sent automatically every few seconds by controller ${inc.controller} '
                  '(ESP32) to the PyroGuard cloud server. Readings are not typed in by the homeowner.'),
              row('Verification code', codeText),
              row('SHA-256 fingerprint', '${hash.substring(0, 32)}\n${hash.substring(32)}'),
              row('Verify online', registered
                  ? verifyUrl
                  : 'Not registered (no connection). Generate the report again while online.'),
              pw.SizedBox(height: 4),
              pw.Text(
                'To check this report, scan the QR code or open the link. The page compares this report with the '
                'sensor readings and camera photos stored on the PyroGuard server. If any number, time or photo '
                'in this PDF was changed, the fingerprint will not match.',
                style: const pw.TextStyle(fontSize: 8, color: grey),
              ),
            ]),
          ),
          if (registered) ...[
            pw.SizedBox(width: 12),
            pw.Column(children: [
              pw.BarcodeWidget(barcode: pw.Barcode.qrCode(), data: verifyUrl, width: 92, height: 92),
              pw.SizedBox(height: 3),
              pw.Text('Scan to verify', style: const pw.TextStyle(fontSize: 7.5, color: grey)),
            ]),
          ],
        ]),
        section('7. BFP station on file'),
        row('Station', v(bfp, 'station_name', v(bfp, 'name'))),
        row('Contact person', '${v(bfp, 'rank_position', '')} ${v(bfp, 'personnel_name', '')}'.trim().isEmpty
            ? 'Not provided'
            : '${v(bfp, 'rank_position', '')} ${v(bfp, 'personnel_name', '')}'.trim()),
        row('Station number', v(bfp, 'phone')),
        row('Station address', v(bfp, 'address')),
        row('Station e-mail', v(bfp, 'email', 'Not provided')),
        row('Emergency hotline', '911 (National Emergency Hotline)'),
        section('8. Certification'),
        pw.Text(
          'This report was generated from data recorded automatically by the PyroGuard multi-sensor system '
          '(DHT22 temperature/humidity, MQ-2 smoke/gas and IR flame sensors) installed at the location above. '
          'Times are in Philippine Standard Time (UTC+8). I certify that the information above is true and correct '
          'to the best of my knowledge.',
          style: const pw.TextStyle(fontSize: 9),
        ),
        pw.SizedBox(height: 28),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          for (final who in ['Prepared by (Homeowner)', 'Received by (BFP Personnel)'])
            pw.Column(children: [
              pw.Container(width: 200, height: .8, color: PdfColors.black),
              pw.SizedBox(height: 3),
              pw.Text(who, style: const pw.TextStyle(fontSize: 8.5)),
              pw.Text('Signature over printed name / Date', style: const pw.TextStyle(fontSize: 7.5, color: grey)),
            ]),
        ]),
      ],
    ));
    return doc.save();
  }

  /// Street map around the home from OpenStreetMap tiles (zoom 17) with a
  /// red marker on the incident location. Null when offline.
  static Future<pw.Widget?> _locationMap(double lat, double lng) async {
    const z = 17, tile = 256.0, w = 300.0, h = 190.0;
    final n = math.pow(2, z).toDouble();
    final xt = (lng + 180) / 360 * n;
    final latR = lat * math.pi / 180;
    final yt = (1 - math.log(math.tan(latR) + 1 / math.cos(latR)) / math.pi) / 2 * n;
    final cx = xt.floor(), cy = yt.floor();
    final tiles = <pw.Widget>[];
    var got = 0;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        final tx = cx + dx, ty = cy + dy;
        try {
          final res = await http
              .get(Uri.parse('https://tile.openstreetmap.org/$z/$tx/$ty.png'))
              .timeout(const Duration(seconds: 8));
          if (res.statusCode != 200) continue;
          got++;
          tiles.add(pw.Positioned(
            left: (tx - xt) * tile + w / 2,
            top: (ty - yt) * tile + h / 2,
            child: pw.Image(pw.MemoryImage(res.bodyBytes), width: tile, height: tile),
          ));
        } catch (_) {}
      }
    }
    if (got == 0) return null;
    return pw.Container(
      width: w,
      height: h,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500, width: .6)),
      child: pw.ClipRect(
        child: pw.Stack(overflow: pw.Overflow.clip, children: [
          ...tiles,
          pw.Positioned(
            left: w / 2 - 7,
            top: h / 2 - 7,
            child: pw.Container(
              width: 14,
              height: 14,
              decoration: pw.BoxDecoration(
                color: const PdfColor.fromInt(0xFFDC2626),
                shape: pw.BoxShape.circle,
                border: pw.Border.all(color: PdfColors.white, width: 2),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  /// The home's floor plan drawing with the incident room marked in red and
  /// the exits in green.
  static Future<pw.Widget> _floorPlan(List<LayoutItem> items, HomeIncident inc) async {
    const w = 200.0;
    final k = w / kPlanSizeM.width; // points per meter
    final h = kPlanSizeM.height * k;
    pw.MemoryImage? plan;
    try {
      plan = pw.MemoryImage((await rootBundle.load(kFloorPlanAsset)).buffer.asUint8List());
    } catch (_) {}
    double px(double m) => (m + kPlanOffsetM.dx) * k;
    double py(double m) => (m + kPlanOffsetM.dy) * k;
    final hit = items.where((i) => i.kind == 'room' && i.controller == inc.controller && i.room == inc.room);
    return pw.Container(
      width: w,
      height: h,
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500, width: .6)),
      child: pw.Stack(overflow: pw.Overflow.clip, children: [
        if (plan != null) pw.Positioned(left: 0, top: 0, child: pw.Image(plan, width: w, height: h, fit: pw.BoxFit.fill)),
        for (final i in hit)
          pw.Positioned(
            left: px(i.x),
            top: py(i.y),
            child: pw.Opacity(
              opacity: .45,
              child: pw.Container(width: i.w * k, height: i.h * k, color: const PdfColor.fromInt(0xFFDC2626)),
            ),
          ),
        for (final i in hit)
          pw.Positioned(
            left: px(i.x) + 3,
            top: py(i.y) + 3,
            child: pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              color: const PdfColor.fromInt(0xFFDC2626),
              child: pw.Text('${i.label.toUpperCase()} - INCIDENT',
                  style: pw.TextStyle(color: PdfColors.white, fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
            ),
          ),
        for (final e in items.where((i) => i.kind == 'exit'))
          pw.Positioned(
            left: px(e.x),
            top: py(e.y),
            child: pw.Container(width: math.max(3, e.w * k), height: math.max(3, e.h * k), color: const PdfColor.fromInt(0xFF16A34A)),
          ),
      ]),
    );
  }

  static String _offset(Duration d) {
    final m = d.inSeconds.abs() ~/ 60, sec = d.inSeconds.abs() % 60;
    final t = m > 0 ? '$m min ${sec}s' : '${sec}s';
    return d.isNegative ? '$t before' : '$t after';
  }
}

class _Photo {
  _Photo({required this.when, required this.url, required this.bytes, required this.kind, required this.camera});
  final DateTime when;
  final String url;
  final Uint8List bytes;
  final String kind;
  final String camera;
}
