import 'dart:async';
import '../config/camera_endpoint.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/camera_network_config.dart';
import '../config/coverage_config.dart';
import 'camera_telemetry_service.dart';
import 'notification_service.dart';
import 'security_control_service.dart';

/// Motion status measured by the camera's own frame analysis (/motion).
class CameraMotionState {
  const CameraMotionState({
    required this.reachable,
    required this.ready,
    required this.enabled,
    required this.fresh,
    required this.detected,
    required this.score,
    required this.detections,
    required this.checkedAt,
  });

  final bool reachable;
  final bool ready;
  final bool enabled;

  /// A frame was analysed recently (the camera is really watching).
  final bool fresh;
  final bool detected;
  final double score;
  final int detections;
  final DateTime checkedAt;

  /// Only report motion that the camera verified on a fresh analysis.
  bool get motionNow => reachable && enabled && fresh && detected;

  String get label {
    if (!reachable) return 'Motion sensor offline';
    if (!ready) return 'Motion sensor unavailable';
    if (!enabled) return 'Motion detection off';
    if (!fresh) return 'Motion sensor starting';
    return detected ? 'MOTION DETECTED' : 'No motion';
  }
}

/// Polls one camera's `/motion` endpoint (port 80, separate from the video
/// stream on port 81, so it never slows the live preview).
///
/// Screens attach while visible. The dashboard shell keeps Camera 1 attached
/// so motion is still noticed when the camera screen is closed, and raises an
/// intrusion-style alert when motion starts while the system is ARMED.
class CameraMotionMonitor extends ChangeNotifier {
  CameraMotionMonitor._(this.cameraId);

  static final Map<String, CameraMotionMonitor> _monitors = {};
  static CameraMotionMonitor forCamera(String cameraId) =>
      _monitors.putIfAbsent(cameraId, () => CameraMotionMonitor._(cameraId));

  static const _pollInterval = Duration(seconds: 1);
  static const _alertCooldown = Duration(seconds: 45);

  /// Camera 1 address: a saved override, else fresh telemetry, else the
  /// fixed firmware address (192.168.8.99).
  static String cameraOneIp() => CameraNetworkConfig.instance.resolve(
        CoverageConfig.cameraOne,
        CameraTelemetryService.instance.cameraIp,
      );

  final String cameraId;
  CameraMotionState? state;
  String _ip = '';
  int _attachments = 0;
  Timer? _timer;
  bool _busy = false;
  int _failures = 0;
  DateTime? _nextAttempt;
  DateTime? _lastAlert;

  String get ip => _ip;
  String get cameraName =>
      cameraId == CoverageConfig.cameraOne ? 'Camera 1' : 'Unknown camera';

  /// Starts polling (reference counted). Call [detach] when done.
  void attach(String ip) {
    _attachments++;
    setIp(ip);
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
    _poll();
  }

  void detach() {
    if (_attachments > 0) _attachments--;
    if (_attachments == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void setIp(String ip) {
    final next = ip.trim();
    if (next.isEmpty || next == _ip) return;
    _ip = next;
    _failures = 0;
    _nextAttempt = null;
  }

  /// An HTTPS page (Vercel) may not call http://192.168.x.x: the browser
  /// blocks it as mixed content and fills the console with warnings. Motion
  /// then comes from Supabase (camera_events) instead of the local camera.
  static bool get _localBlocked => !CameraEndpoint.reachable;

  Future<void> _poll() async {
    if (_localBlocked || _busy || !CameraNetworkConfig.validIpv4(_ip)) return;
    // Back off while the camera is offline: 1 s, then every 5 s.
    final wait = _nextAttempt;
    if (wait != null && DateTime.now().isBefore(wait)) return;
    _busy = true;
    final previous = state;
    try {
      final response = await http
          .get(CameraEndpoint.url(cameraId, _ip, '/motion'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException('Invalid /motion');
      final age = decoded['analysis_age_ms'];
      final fresh = decoded['motion_fresh'] == true ||
          (decoded['motion_fresh'] == null && age is num && age <= 2400);
      state = CameraMotionState(
        reachable: true,
        ready: decoded['motion_ready'] == true,
        enabled: decoded['motion_enabled'] == true,
        fresh: fresh,
        detected: decoded['motion_detected'] == true,
        score: (decoded['motion_score'] as num?)?.toDouble() ?? 0,
        detections: (decoded['detection_count'] as num?)?.toInt() ?? 0,
        checkedAt: DateTime.now(),
      );
      _failures = 0;
      _nextAttempt = null;
    } catch (_) {
      _failures++;
      if (_failures > 2) {
        _nextAttempt = DateTime.now().add(const Duration(seconds: 5));
      }
      state = CameraMotionState(
        reachable: false,
        ready: false,
        enabled: false,
        fresh: false,
        detected: false,
        score: 0,
        detections: previous?.detections ?? 0,
        checkedAt: DateTime.now(),
      );
    } finally {
      _busy = false;
    }
    final now = state;
    if (now != null && now.motionNow && !(previous?.motionNow ?? false)) {
      _onMotionStarted();
    }
    if (previous == null ||
        now == null ||
        previous.label != now.label ||
        previous.detections != now.detections) {
      notifyListeners();
    }
  }

  void _onMotionStarted() {
    debugPrint('[$cameraName] motion detected');
    final armed =
        SecurityControlService.instance.mode != SecurityMode.disarmed;
    if (!armed) return;
    final last = _lastAlert;
    if (last != null && DateTime.now().difference(last) < _alertCooldown) {
      return;
    }
    _lastAlert = DateTime.now();
    NotificationService.notifyCameraMotion(
      cameraName,
      CoverageConfig.cameraCoverage(cameraId),
    );
  }
}
