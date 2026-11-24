import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// URL builder for Camera 1 (pyroguard_camera_001, DFR1154 with two-way audio).
///
/// In the app and on `flutter run` the camera is reached directly on the
/// home Wi-Fi (http://192.168.8.99). On the HTTPS website the browser blocks
/// http:// addresses, so the camera is reached through the secure tunnel
/// addresses published by deployment/camera-tunnel/start-camera-tunnel.ps1
/// (Cloudflare tunnels on the PC that is on the Pyroguard_Team Wi-Fi).
class CameraEndpoint {
  CameraEndpoint._();

  /// True on the HTTPS website, where http:// camera addresses are blocked.
  static bool get httpsPage => kIsWeb && Uri.base.scheme == 'https';

  /// The website can reach the camera (directly, or through the tunnel).
  static bool get reachable => !httpsPage || CameraTunnel.instance.ready;

  static Uri url(String cameraId, String ip, String path, {int? port, Map<String, String>? query}) {
    final q = (query == null || query.isEmpty) ? null : query;
    if (httpsPage) {
      final t = CameraTunnel.instance;
      final base = port == 81 ? t.streamUrl : t.httpUrl;
      if (base != null) {
        final b = Uri.parse(base);
        return b.replace(path: path, queryParameters: q);
      }
    }
    return Uri(scheme: 'http', host: ip, port: port, path: path, queryParameters: q);
  }
}

/// Live copy of `pyroguard_camera_tunnel` (the camera's HTTPS addresses).
class CameraTunnel extends ChangeNotifier {
  CameraTunnel._();
  static final instance = CameraTunnel._();

  static const cameraId = 'pyroguard_camera_001';

  String? httpUrl;
  String? streamUrl;
  DateTime? updatedAt;
  RealtimeChannel? _channel;
  bool _started = false;

  /// Links are refreshed every 30 s by the PC script; older than 2 minutes
  /// means the PC or the script was closed.
  bool get ready =>
      httpUrl != null &&
      streamUrl != null &&
      updatedAt != null &&
      DateTime.now().toUtc().difference(updatedAt!.toUtc()) < const Duration(minutes: 2);

  Future<void> start() async {
    if (!CameraEndpoint.httpsPage || _started) return;
    _started = true;
    await refresh();
    _channel = Supabase.instance.client
        .channel('camera-tunnel')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'pyroguard_camera_tunnel',
          callback: (_) => refresh(),
        )
        .subscribe();
  }

  Future<void> refresh() async {
    try {
      final row = await Supabase.instance.client
          .from('pyroguard_camera_tunnel')
          .select()
          .eq('camera_device_id', cameraId)
          .maybeSingle();
      final h = '${row?['http_url'] ?? ''}'.trim();
      final s = '${row?['stream_url'] ?? ''}'.trim();
      httpUrl = h.startsWith('https://') ? h : null;
      streamUrl = s.startsWith('https://') ? s : null;
      updatedAt = DateTime.tryParse('${row?['updated_at'] ?? ''}');
    } catch (e) {
      debugPrint('Camera tunnel unavailable: $e');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final c = _channel;
    _channel = null;
    _started = false;
    if (c != null) await Supabase.instance.client.removeChannel(c);
  }
}
