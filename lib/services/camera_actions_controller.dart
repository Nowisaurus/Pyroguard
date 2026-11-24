// ignore_for_file: unused_import

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/camera_endpoint.dart';
import '../config/camera_network_config.dart';
import '../widgets/pg_notice.dart';
import 'recording_video.dart';
import '../config/coverage_config.dart';
import '../config/pyroguard_config.dart';
import 'camera_audio_service.dart';
import 'camera_telemetry_service.dart';
import 'historical_service.dart';
import 'mjpeg_live_feed.dart';
import 'notification_service.dart';

/// The working actions behind the buttons on the camera overlay:
/// Mute/Listen, Record, Speak, Call BFP, Snapshot, digital Zoom and Channel.
///
/// * Snapshot and Record save JPEG frames in the Supabase `incident-media`
///   bucket and a `camera_history` row through HistoricalService, which also
///   writes MySQL (they appear in the Evidence gallery).
/// * Record stores evidence frames (1 per second, up to 60 s) because the
///   ESP32 camera produces JPEG frames, not a video file.
/// * Zoom is digital (the camera module has no optical zoom).
class CameraActionsController extends ChangeNotifier {
  CameraActionsController({
    required this.cameraId,
    required MjpegLiveFeed feed,
  }) : _feed = feed;

  final String cameraId;
  final MjpegLiveFeed _feed;

  static const maxRecordSeconds = 60;
  static const minZoom = 1.0;
  static const maxZoom = 3.0;

  bool get isCameraOne => cameraId == CoverageConfig.cameraOne;
  String get cameraName => isCameraOne ? 'Camera 1' : 'Unknown camera';
  String get controllerId => CoverageConfig.controllerForCamera(cameraId);

  /// Two-way audio on Camera 1 (DFR1154 built-in mic + speaker), the only camera.
  CameraAudioService get audio => CameraAudioService.instance;

  // ---------------- feedback ----------------
  String? message;
  bool messageIsError = false;

  void _say(String text, {bool error = false}) {
    message = text;
    messageIsError = error;
    _notify();
  }

  void clearMessage() {
    message = null;
    _notify();
  }

  // ---------------- zoom (digital) ----------------
  double zoom = 1.0;

  void zoomIn() {
    zoom = (zoom + 0.5).clamp(minZoom, maxZoom).toDouble();
    _notify();
  }

  void zoomOut() {
    zoom = (zoom - 0.5).clamp(minZoom, maxZoom).toDouble();
    _notify();
  }

  // ---------------- audio ----------------
  bool audioBusy = false;
  bool _startedListening = false;

  bool get listening => isCameraOne && audio.listening;

  bool get audioConfigured => isCameraOne;

  bool _requireAudio() {
    if (isCameraOne) return true;
    _say('This camera has no microphone or speaker.', error: true);
    return false;
  }
  bool get talking => isCameraOne && audio.talking;

  Future<void> toggleListen() async {
    if (audioBusy || !_requireAudio()) return;
    audioBusy = true;
    _notify();
    try {
      if (audio.listening) {
        await audio.stopListening();
        _say('$cameraName audio muted');
      } else {
        _startedListening = true;
        unawaited(audio.startListening().catchError((Object e) {
          _say('Audio unavailable: $e', error: true);
        }));
        _say('Listening to $cameraName');
      }
    } catch (e) {
      _say('Audio unavailable: $e', error: true);
    } finally {
      audioBusy = false;
      _notify();
    }
  }

  Future<void> talkStart() async {
    if (audio.talking || !_requireAudio()) return;
    try {
      final ok = await audio.startPushToTalk();
      if (!ok) _say(audio.status, error: true);
    } catch (e) {
      _say('Talk unavailable: $e', error: true);
    }
    _notify();
  }

  Future<void> talkStop() async {
    try {
      await audio.stopPushToTalk();
    } catch (_) {}
    _notify();
  }

  // ---------------- Call BFP ----------------
  Future<void> callBfp() async {
    final ok = await NotificationService.callBFP();
    if (!ok) {
      _say('Save and confirm the BFP contact in Settings first.', error: true);
    }
  }

  // ---------------- evidence storage ----------------
  Uint8List? get _latestFrame => _feed.connected ? _feed.frame : null;

  /// The newest picture: from the live feed in the app, or (website) a fresh
  /// photo from Camera 1 through its secure link.
  Future<Uint8List?> _grabFrame() async {
    final live = _latestFrame;
    if (live != null) return live;
    if (!CameraEndpoint.httpsPage || !CameraTunnel.instance.ready) return null;
    try {
      final r = await http
          .get(CameraEndpoint.url(cameraId, '', '/capture',
              query: {'v': '${DateTime.now().millisecondsSinceEpoch}'}))
          .timeout(const Duration(seconds: 4));
      final b = r.bodyBytes;
      if (r.statusCode == 200 && b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) return b;
    } catch (_) {}
    return null;
  }

  Future<String?> _upload(Uint8List bytes, String path) async {
    final storage =
        Supabase.instance.client.storage.from(PyroGuardConfig.incidentMediaBucket);
    await storage.uploadBinary(
      path,
      bytes,
      fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
    );
    return storage.getPublicUrl(path);
  }

  Map<String, dynamic> _angles() {
    final telemetry = CameraTelemetryService.instance.latest;
    return {
      'pan_at_capture': isCameraOne ? (telemetry?.panAngle ?? 90) : 90,
      'tilt_at_capture': isCameraOne ? (telemetry?.tiltAngle ?? 90) : 90,
    };
  }

  bool snapshotBusy = false;

  /// Saves the current live frame as evidence (Supabase + MySQL).
  Future<void> snapshot() async {
    if (snapshotBusy) return;
    final bytes = await _grabFrame();
    if (bytes == null) {
      _say('No live picture yet. Wait for LIVE, then try again.', error: true);
      return;
    }
    snapshotBusy = true;
    _notify();
    try {
      final now = DateTime.now().toUtc();
      final url = await _upload(bytes, '$cameraId/${now.millisecondsSinceEpoch}.jpg');
      final stored = await HistoricalService.instance.logCameraEvent({
        'device_id': controllerId,
        'camera_device_id': cameraId,
        'event_type': 'manual_snapshot',
        'snapshot_url': url,
        'coverage': CoverageConfig.cameraCoverage(cameraId),
        ..._angles(),
        'created_at': now.toIso8601String(),
      });
      _say(stored
          ? 'Snapshot saved to Evidence (Supabase + MySQL)'
          : 'Snapshot uploaded; history sync pending');
    } catch (e) {
      _say('Snapshot not saved: $e', error: true);
    } finally {
      snapshotBusy = false;
      _notify();
    }
  }

  // ---------------- recording (evidence frames) ----------------
  bool recording = false;
  int recordedFrames = 0;
  DateTime? recordStartedAt;
  Timer? _recordTimer;
  bool _recordUploadBusy = false;
  Uint8List? _lastRecordedFrame;
  final List<String> _recordUrls = [];
  final List<Uint8List> _recordBytes = [];
  String _recordFolder = '';

  Duration get recordElapsed => recordStartedAt == null
      ? Duration.zero
      : DateTime.now().difference(recordStartedAt!);

  Future<void> toggleRecord() async {
    if (recording) {
      await stopRecording();
    } else {
      startRecording();
    }
  }

  void startRecording() {
    if (recording) return;
    if (_latestFrame == null && !(CameraEndpoint.httpsPage && CameraTunnel.instance.ready)) {
      _say('No live picture yet. Wait for LIVE, then record.', error: true);
      return;
    }
    recording = true;
    recordedFrames = 0;
    recordStartedAt = DateTime.now();
    _recordUrls.clear();
    _recordBytes.clear();
    _lastRecordedFrame = null;
    _recordFolder =
        '$cameraId/rec_${DateTime.now().toUtc().millisecondsSinceEpoch}';
    _say('Recording $cameraName (1 frame per second, max $maxRecordSeconds s)');
    _captureRecordFrame();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (recordElapsed.inSeconds >= maxRecordSeconds) {
        stopRecording();
      } else {
        _captureRecordFrame();
      }
    });
  }

  Future<void> _captureRecordFrame() async {
    if (!recording || _recordUploadBusy) return;
    _recordUploadBusy = true;
    final bytes = await _grabFrame();
    if (bytes == null || identical(bytes, _lastRecordedFrame)) {
      _recordUploadBusy = false;
      return;
    }
    _lastRecordedFrame = bytes;
    try {
      final url = await _upload(
        bytes,
        '$_recordFolder/${recordedFrames.toString().padLeft(3, '0')}.jpg',
      );
      if (url != null) {
        _recordUrls.add(url);
        _recordBytes.add(bytes);
        recordedFrames++;
        _notify();
      }
    } catch (e) {
      debugPrint('Recording frame not uploaded: $e');
    } finally {
      _recordUploadBusy = false;
    }
  }

  Future<void> stopRecording() async {
    if (!recording) return;
    _recordTimer?.cancel();
    _recordTimer = null;
    recording = false;
    final seconds = recordElapsed.inSeconds;
    _notify();
    // Wait briefly for a frame upload still in flight.
    for (var i = 0; i < 40 && _recordUploadBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_recordUrls.isEmpty) {
      _say('Recording stopped; no frames were saved (check Supabase storage).',
          error: true);
      return;
    }
    // One video file (MJPEG .avi) so the recording can be played and downloaded.
    String? videoUrl;
    try {
      final int fps = seconds <= 0 ? 1 : (_recordBytes.length / seconds).round().clamp(1, 30).toInt();
      videoUrl = await RecordingVideo.store(List<Uint8List>.from(_recordBytes), _recordFolder, fps: fps);
    } catch (e) {
      debugPrint('Recording video not built: $e');
    }
    _recordBytes.clear();
    try {
      final stored = await HistoricalService.instance.logCameraEvent({
        'device_id': controllerId,
        'camera_device_id': cameraId,
        'event_type': 'recording',
        if (videoUrl != null) 'video_url': videoUrl,
        'snapshot_url': _recordUrls.first,
        'frame_urls': List<String>.from(_recordUrls),
        'frame_count': _recordUrls.length,
        'duration_seconds': seconds,
        'coverage': CoverageConfig.cameraCoverage(cameraId),
        ..._angles(),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      PgNotice.show(
        '${_recordUrls.length} frames, ${seconds}s${videoUrl != null ? ', video ready to download' : ''}.'
        '${stored ? '' : ' History sync pending.'}',
        title: 'Recording saved',
        kind: PgNoticeKind.success,
        actionLabel: 'View',
        onAction: () => NotificationService.onOpenRoute?.call('/evidence'),
      );
    } catch (e) {
      _say('Recording frames uploaded, history not saved: $e', error: true);
    }
  }


  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (recording) {
      // Finish the evidence record even when the page closes mid-recording.
      unawaited(stopRecording());
    }
    _recordTimer?.cancel();
    if (isCameraOne) {
      if (_startedListening) unawaited(audio.stopListening());
      unawaited(audio.stopPushToTalk());
    }
    super.dispose();
  }
}
