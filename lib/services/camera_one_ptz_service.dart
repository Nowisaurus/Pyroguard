import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/camera_network_config.dart';
import '../config/coverage_config.dart';
import 'main_esp_service.dart';

/// Camera 1 pan/tilt over the local Wi-Fi.
///
/// * Auto-follow is done by the hardware itself: Camera 1 detects motion and
///   ESP32-001 (the main controller) decides and drives the servo moves.
///   The app only switches it on/off and shows its state.
/// * Manual buttons: Flutter --POST /ptz--> Camera 1 --POST /ptz--> ESP32-001.
///   A manual move pauses auto-follow for 20 s on the controller.
///
/// Cloud route (used automatically when the local route is not available,
/// e.g. the app is opened from Vercel over HTTPS, from mobile data, or Camera 1
/// is not linked): the app queues a `PTZ` row in Supabase `device_commands`
/// for ESP32-001, which picks it up on its 2-second sync and acknowledges it.
/// The live angle and auto-follow state come back through `ptz_state`.
///
/// Camera 1 learns ESP32-001's address from the controller's own `/link`
/// report, so the app never needs ESP32-001's IP or its device key, and no
/// PC, laptop or Python script is involved.
class CameraOnePtzService extends ChangeNotifier {
  CameraOnePtzService(String cameraIp) : _cameraIp = cameraIp.trim();

  static const actions = {
    'left', 'right', 'up', 'down', 'center', 'stop', 'auto_on', 'auto_off',
  };

  String _cameraIp;
  String get cameraIp => _cameraIp;

  bool cameraReachable = false;
  bool controllerLinked = false;
  bool firmwareSupportsPtz = true;
  String? controllerIp;
  int? pan;
  int? tilt;
  int? targetPan;
  int? targetTilt;
  bool moving = false;
  bool autoFollow = false;
  bool autoPaused = false;
  bool sending = false;
  String? message;
  DateTime? lastStatusAt;

  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;

  static const controllerId = 'ESP32-001';
  static const cloudJogDeg = 15;

  bool get validIp => CameraNetworkConfig.validIpv4(_cameraIp);

  /// A page served over HTTPS (Vercel) cannot call http://192.168.x.x:
  /// the browser blocks it as mixed content, so only the cloud route works.
  static bool get _localBlocked => kIsWeb && Uri.base.scheme == 'https';

  /// ESP32-001 reported its servo position to Supabase recently.
  bool cloudLinked = false;
  DateTime? _relayDownUntil;
  DateTime? cloudSeenAt;
  DateTime? _lastCloudPoll;

  /// Direct route: the camera answers and ESP32-001 is linked to it.
  bool get localReady =>
      !_localBlocked && validIp && cameraReachable && controllerLinked;

  /// Commands go through Supabase when the direct route is unavailable.
  bool get viaCloud => !localReady && cloudLinked;

  /// Buttons are usable on either route.
  bool get ready => localReady || cloudLinked;

  void updateCameraIp(String ip) {
    final next = ip.trim();
    if (next == _cameraIp) return;
    _cameraIp = next;
    cameraReachable = false;
    controllerLinked = false;
    refresh();
  }

  void start() {
    if (_timer != null) return;
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  int? _int(Object? value) => value is num ? value.round() : null;

  void _applyController(Object? raw) {
    if (raw is! Map) return;
    final c = Map<String, dynamic>.from(raw);
    controllerLinked = c['linked'] == true;
    final ip = c['ip']?.toString();
    controllerIp = ip != null && CameraNetworkConfig.validIpv4(ip) ? ip : null;
    pan = _int(c['pan']) ?? pan;
    tilt = _int(c['tilt']) ?? tilt;
    targetPan = _int(c['target_pan']) ?? targetPan;
    targetTilt = _int(c['target_tilt']) ?? targetTilt;
    moving = c['moving'] == true;
    autoFollow = c['auto_follow'] == true;
    autoPaused = c['auto_paused'] == true;
    // Camera 1 discovered ESP32-001's DHCP address: let the System
    // Connections screen use it too (a user-saved address still wins).
    if (controllerLinked && controllerIp != null) {
      MainEspService.instance.adoptDiscoveredIp(controllerIp!);
    }
  }

  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    if (_localBlocked) {
      cameraReachable = false;
      controllerLinked = false;
      _refreshing = true;
      try {
        await _pollCloud(force: true);
      } finally {
        _refreshing = false;
        _notify();
      }
      return;
    }
    if (!validIp) {
      cameraReachable = false;
      controllerLinked = false;
      message = 'Camera 1 IP address is not configured.';
      _refreshing = true;
      try {
        await _pollCloud();
        if (viaCloud) message = null;
      } finally {
        _refreshing = false;
        _notify();
      }
      return;
    }
    _refreshing = true;
    try {
      final response = await http
          .get(Uri(scheme: 'http', host: _cameraIp, path: '/status'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException('Invalid /status');
      cameraReachable = true;
      lastStatusAt = DateTime.now();
      final controller = decoded['ptz_controller'];
      firmwareSupportsPtz = controller is Map;
      if (controller is Map) {
        _applyController(controller);
        if (message != null && controllerLinked && !sending) message = null;
      } else {
        controllerLinked = false;
        message = 'Camera 1 is running the old sketch. Upload the new '
            'PyroGuard_Camera1_DFR1154.ino to enable manual PTZ.';
      }
    } catch (e) {
      cameraReachable = false;
      controllerLinked = false;
    } finally {
      if (!localReady) await _pollCloud();
      if (viaCloud) message = null;
      _refreshing = false;
      _notify();
    }
  }

  /// Reads ESP32-001's servo position and auto-follow state from Supabase.
  Future<void> _pollCloud({bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _lastCloudPoll != null &&
        now.difference(_lastCloudPoll!) < const Duration(seconds: 2)) {
      return;
    }
    _lastCloudPoll = now;
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) {
        cloudLinked = false;
        return;
      }
      final row = await client
          .from('ptz_state')
          .select('pan_angle,tilt_angle,moving,auto_tracking,last_device_at')
          .eq('device_id', controllerId)
          .maybeSingle();
      if (row == null) {
        cloudLinked = false;
        return;
      }
      final seen = DateTime.tryParse('${row['last_device_at'] ?? ''}');
      cloudSeenAt = seen?.toLocal();
      cloudLinked = seen != null &&
          now.toUtc().difference(seen.toUtc()) < const Duration(seconds: 60);
      if (!localReady) {
        pan = _int(row['pan_angle']) ?? pan;
        tilt = _int(row['tilt_angle']) ?? tilt;
        moving = row['moving'] == true;
        autoFollow = row['auto_tracking'] == true;
        autoPaused = false;
      }
      if (!cloudLinked && !localReady) {
        message = _localBlocked
            ? 'ESP32-001 has not reported in the last minute. Check that it '
                'is powered and online.'
            : message;
      }
    } catch (e) {
      cloudLinked = false;
      debugPrint('Camera 1 PTZ cloud state unavailable: $e');
    }
  }

  /// Queues one PTZ action for ESP32-001 in Supabase `device_commands`.
  Future<bool> _cloudCommand(String action, int? step) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      message = 'Sign in to control the camera.';
      return false;
    }
    try {
      await client.from('device_commands').insert({
        'user_id': user.id,
        'requested_by': user.id,
        'target_device_id': controllerId,
        'command': 'PTZ',
        'payload': {
          'action': action,
          'step': step ?? cloudJogDeg,
          'source': 'app',
        },
        'status': 'pending',
      });
      message = null;
      if (action == 'auto_on' || action == 'auto_off') {
        autoFollow = action == 'auto_on';
        autoPaused = false;
      }
      return true;
    } catch (e) {
      message = 'PTZ command could not be queued: $e';
      return false;
    }
  }

  /// Sends one command. Returns true when ESP32-001 accepted it.
  /// [record] stores the command in Supabase `ptz_commands` (mirrored to
  /// MySQL by the sync worker). Hold-to-move repeats pass false so one
  /// press-and-hold is stored once, plus the final "stop".
  Future<bool> command(String action, {int? step, bool record = true}) async {
    if (!actions.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported PTZ action');
    }
    if (_disposed || sending) return false;

    // ---- cloud route (Supabase -> ESP32-001) ----
    final relayDown = _relayDownUntil != null && DateTime.now().isBefore(_relayDownUntil!);
    if (!localReady || relayDown) {
      // One press = one 15 degree jog. Hold-repeats and the release "stop"
      // are skipped, because a queued "stop" would cancel the jog.
      if (!record && action != 'stop') return false;
      if (action == 'stop') return true;
      sending = true;
      _notify();
      try {
        final ok = await _cloudCommand(action, step);
        if (ok && record) unawaited(_recordCommand(action));
        return ok;
      } finally {
        sending = false;
        _notify();
      }
    }

    if (!validIp) return false;
    sending = true;
    _notify();
    try {
      final response = await http
          .post(Uri(
            scheme: 'http',
            host: _cameraIp,
            path: '/ptz',
            queryParameters: {
              'action': action,
              if (step != null) 'step': '$step',
            },
          ))
          .timeout(const Duration(seconds: 4));
      cameraReachable = true;
      Map<String, dynamic> body = const {};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) body = Map<String, dynamic>.from(decoded);
      } catch (_) {}
      _applyController(body['controller']);

      switch (response.statusCode) {
        case 200:
          message = null;
          if (record) unawaited(_recordCommand(action));
          return true;
        case 202:
          message = 'Command queued; ESP32-001 is responding slowly.';
          if (record) unawaited(_recordCommand(action));
          return true;
        case 404:
          firmwareSupportsPtz = false;
          message = 'Camera 1 is running the old sketch. Upload the new '
              'PyroGuard_Camera1_DFR1154.ino to enable manual PTZ.';
          return false;
        case 429:
          message = null; // a previous jog is still being delivered
          return false;
        case 502:
          // Camera 1 reached ESP32-001 but the board did not accept the move
          // (rebooting / Wi-Fi blip). Send the same move through Supabase,
          // and keep using that route for 2 minutes (no failing LAN calls).
          controllerLinked = false;
          _relayDownUntil = DateTime.now().add(const Duration(minutes: 2));
          return await _cloudFallback(action, step, record);
        case 503:
          controllerLinked = false;
          message = body['error'] == 'controller_not_linked'
              ? 'ESP32-001 is not linked yet. Check that it is powered and '
                  'on the same Wi-Fi as Camera 1.'
              : 'PTZ relay unavailable on Camera 1.';
          return false;
        default:
          message = 'ESP32-001 did not accept the move '
              '(HTTP ${body['controller_http'] ?? response.statusCode}).';
          return false;
      }
    } catch (e) {
      // Timeout / network changed / camera offline: try the cloud route.
      cameraReachable = false;
      return await _cloudFallback(action, step, record);
    } finally {
      sending = false;
      _notify();
    }
  }

  /// Used when the direct (LAN) route fails: queue the move for ESP32-001 in
  /// Supabase instead. Hold-repeats and "stop" are skipped on this route.
  Future<bool> _cloudFallback(String action, int? step, bool record) async {
    if (!record && action != 'stop') return false;
    if (action == 'stop') return true;
    final ok = await _cloudCommand(action, step);
    if (ok) {
      message = 'Direct link busy; move sent through the cloud (about 2 s).';
      if (record) unawaited(_recordCommand(action));
    } else {
      message ??= 'Camera 1 not reachable at $_cameraIp, and the cloud route failed.';
    }
    return ok;
  }

  String? lastRecordError;

  /// Stores a delivered Camera 1 command in Supabase (`ptz_commands`,
  /// status "executed"). The local MySQL sync worker mirrors that table.
  Future<void> _recordCommand(String action) async {
    try {
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) return;
      final auto = action == 'auto_on' || action == 'auto_off';
      final tiltAction = action == 'up' || action == 'down';
      final panValue = targetPan ?? pan ?? 90;
      final tiltValue = targetTilt ?? tilt ?? 90;
      await client.from('ptz_commands').insert({
        'user_id': user.id,
        'device_id': CoverageConfig.cameraOne,
        'pan': panValue.toDouble(),
        'tilt': tiltValue.toDouble(),
        'speed': 0.5,
        'mode': auto ? 'auto' : 'manual',
        'command': action,
        'value': tiltAction ? tiltValue : panValue,
        'status': 'executed',
        'applied_at': DateTime.now().toUtc().toIso8601String(),
      });
      lastRecordError = null;
    } catch (e) {
      lastRecordError = '$e';
      debugPrint('Camera 1 PTZ command not stored in Supabase: $e');
    }
  }

  /// Halts the servos where they are, after any jog still in flight.
  Future<void> stopAfterCurrent() async {
    final started = DateTime.now();
    while (sending &&
        !_disposed &&
        DateTime.now().difference(started) < const Duration(seconds: 3)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    if (!_disposed) await command('stop');
  }

  /// Switches the controller's automatic motion-following on or off.
  Future<bool> setAutoFollow(bool enabled) async {
    final ok = await command(enabled ? 'auto_on' : 'auto_off');
    if (ok) {
      autoFollow = enabled;
      if (enabled) autoPaused = false;
      _notify();
    }
    return ok;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
