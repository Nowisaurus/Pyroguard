import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/pyroguard_config.dart';
import 'camera_telemetry_service.dart';
import 'historical_service.dart';
import 'dual_sync_service.dart';

class CameraStatus {
  final bool wifiConnected;
  final bool cameraReady;
  final bool cameraEnabled;
  final bool micReady;
  final bool micEnabled;
  final bool speakerReady;
  final bool speakerEnabled;
  final bool micStreaming;
  final bool motionDetected;
  final int motionSamples;
  final int pan;
  final int tilt;
  final int uptimeMs;
  final String? videoUrl;
  final String? micPcmUrl;

  const CameraStatus({
    required this.wifiConnected,
    required this.cameraReady,
    required this.cameraEnabled,
    required this.micReady,
    required this.micEnabled,
    required this.speakerReady,
    required this.speakerEnabled,
    required this.micStreaming,
    required this.motionDetected,
    required this.motionSamples,
    required this.pan,
    required this.tilt,
    required this.uptimeMs,
    this.videoUrl,
    this.micPcmUrl,
  });

  factory CameraStatus.fromJson(Map<String, dynamic> json) => CameraStatus(
        wifiConnected: (json['wifi'] ?? '').toString().toLowerCase() == 'connected',
        cameraReady: json['camera_ready'] as bool? ?? false,
        cameraEnabled: json['camera_enabled'] as bool? ?? false,
        micReady: json['mic_ready'] as bool? ?? false,
        micEnabled: json['mic_enabled'] as bool? ?? false,
        speakerReady: json['speaker_ready'] as bool? ?? false,
        speakerEnabled: json['speaker_enabled'] as bool? ?? false,
        micStreaming: json['mic_streaming'] as bool? ?? false,
        motionDetected: json['motion'] as bool? ?? false,
        motionSamples: (json['motion_samples'] as num?)?.toInt() ?? 0,
        pan: (json['pan'] as num?)?.toInt() ?? 90,
        tilt: (json['tilt'] as num?)?.toInt() ?? 90,
        uptimeMs: (json['uptime_ms'] as num?)?.toInt() ?? 0,
        videoUrl: json['video_url'] as String?,
        micPcmUrl: json['mic_pcm_url'] as String?,
      );

  // Compatibility with older widgets.
  bool get streamingActive => cameraEnabled;
  bool get nightVisionEnabled => false;
  bool get motionDetectionEnabled => true;
  int get photosCaputed => 0;
  int get videosRecorded => 0;
}

class CameraEvent {
  final String id;
  final String deviceId;
  final String eventType;
  final String? snapshotUrl;
  final int? panAtCapture;
  final int? tiltAtCapture;
  final DateTime createdAt;

  const CameraEvent({
    required this.id,
    required this.deviceId,
    required this.eventType,
    this.snapshotUrl,
    this.panAtCapture,
    this.tiltAtCapture,
    required this.createdAt,
  });

  factory CameraEvent.fromMap(Map<String, dynamic> map) => CameraEvent(
        id: (map['id'] ?? '').toString(),
        deviceId: (map['device_id'] ?? map['camera_device_id'] ?? '').toString(),
        eventType: (map['event_type'] ?? '').toString(),
        snapshotUrl: map['snapshot_url'] as String?,
        panAtCapture: (map['pan_at_capture'] as num?)?.toInt(),
        tiltAtCapture: (map['tilt_at_capture'] as num?)?.toInt(),
        createdAt: DateTime.tryParse((map['created_at'] ?? '').toString()) ?? DateTime.now(),
      );
}

class AlertLog {
  final String id;
  final String deviceId;
  final String alertType;
  final double temperature;
  final int smokeLevel;
  final String flameStatus;
  final String severityLevel;
  final String location;
  final String? photoUrl;
  final String? videoUrl;
  final DateTime createdAt;

  const AlertLog({
    required this.id,
    required this.deviceId,
    required this.alertType,
    required this.temperature,
    required this.smokeLevel,
    required this.flameStatus,
    required this.severityLevel,
    required this.location,
    this.photoUrl,
    this.videoUrl,
    required this.createdAt,
  });

  factory AlertLog.fromMap(Map<String, dynamic> map) => AlertLog(
        id: (map['id'] ?? '').toString(),
        deviceId: (map['device_id'] ?? '').toString(),
        alertType: (map['alert_type'] ?? map['alert_status'] ?? '').toString(),
        temperature: (map['temperature'] as num?)?.toDouble() ?? 0,
        smokeLevel: (map['smoke_level'] as num?)?.toInt() ?? (map['smoke_raw'] as num?)?.toInt() ?? 0,
        flameStatus: (map['flame_status'] ?? map['flame_detected'] ?? '').toString(),
        severityLevel: (map['severity_level'] ?? map['alert_status'] ?? '').toString(),
        location: (map['location'] ?? '').toString(),
        photoUrl: map['photo_url'] as String?,
        videoUrl: map['video_url'] as String?,
        createdAt: DateTime.tryParse((map['created_at'] ?? '').toString()) ?? DateTime.now(),
      );
}

class CameraService extends ChangeNotifier {
  CameraService._();
  static final CameraService instance = CameraService._();

  final StreamController<Uint8List> _frameController = StreamController<Uint8List>.broadcast();
  final StreamController<String> _statusController = StreamController<String>.broadcast();
  final List<int> _mjpegBuffer = <int>[];

  http.Client? _streamClient;
  StreamSubscription<List<int>>? _streamSubscription;
  bool _isStreaming = false;
  bool _wantStreaming = false;
  CameraStatus? _lastStatus;
  String? _lastError;

  Stream<Uint8List> get frames => _frameController.stream;
  Stream<String> get status => _statusController.stream;
  bool get isStreaming => _isStreaming;
  CameraStatus? get lastStatus => _lastStatus;
  String? get lastError => _lastError;
  String get espIp => CameraTelemetryService.instance.cameraIp;
  String get homepageUrl => 'http://$espIp/';
  String get streamUrl => 'http://$espIp:81/stream';
  String get micPcmUrl => 'http://$espIp:82/mic';

  Future<void> _auditControl(String action, Map<String, dynamic> payload) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final record = <String, dynamic>{
      'action': action,
      'camera_device_id': PyroGuardConfig.cameraDeviceId,
      'device_id': CameraTelemetryService.instance.latest?.deviceId ?? PyroGuardConfig.mainDeviceId,
      ...payload,
      'created_at': now,
    };
    try {
      await DualSyncService.instance.writeMirror(
        recordType: 'camera_control',
        recordKey: '${action}_$now',
        payload: record,
      );
      await HistoricalService.instance.logEvent({
        'event_type': action,
        'message': 'Camera control action recorded.',
        'severity': 0,
        'device_id': record['device_id'],
        'payload': record,
        'created_at': now,
      });
    } catch (_) {}
  }

  Future<bool> _post(String path) async {
    try {
      final response = await http
          .post(Uri.parse('http://$espIp$path'))
          .timeout(PyroGuardConfig.localRequestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) return true;
      _lastError = 'HTTP ${response.statusCode}: ${response.body}';
    } catch (e) {
      _lastError = '$e';
    }
    _statusController.add(_lastError ?? 'Command failed');
    notifyListeners();
    return false;
  }

  Future<bool> setCameraEnabled(bool enabled) async {
    final ok = await _post(enabled ? '/api/camera/on' : '/api/camera/off');
    if (!enabled) await stopStream();
    if (ok) {
      await getStatus();
      await _auditControl('camera_enabled_changed', {'enabled': enabled});
    }
    return ok;
  }

  Future<bool> setMicEnabled(bool enabled) async {
    final ok = await _post(enabled ? '/api/mic/on' : '/api/mic/off');
    if (ok) await _auditControl('camera_microphone_changed', {'enabled': enabled});
    return ok;
  }

  Future<bool> setSpeakerEnabled(bool enabled) async {
    final ok = await _post(enabled ? '/api/speaker/on' : '/api/speaker/off');
    if (ok) await _auditControl('camera_speaker_changed', {'enabled': enabled});
    return ok;
  }

  Future<void> startStream() async {
    _wantStreaming = true;
    if (_isStreaming) return;
    _isStreaming = true;
    _lastError = null;
    _statusController.add('Connecting to camera $espIp...');
    _mjpegBuffer.clear();

    try {
      await _post('/api/camera/on');
      final client = http.Client();
      _streamClient = client;
      final request = http.Request('GET', Uri.parse(streamUrl));
      final response = await client.send(request).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        _lastError = 'Camera stream HTTP ${response.statusCode}';
        _statusController.add(_lastError!);
        notifyListeners();
        client.close();
        _scheduleReconnect();
        return;
      }

      _statusController.add('Live camera connected');
      notifyListeners();
      _streamSubscription = response.stream.listen(
        (chunk) {
          if (!_isStreaming) return;
          _mjpegBuffer.addAll(chunk);
          _extractFrames();
        },
        onError: (e) {
          _lastError = 'Camera stream error: $e';
          _statusController.add(_lastError!);
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (e) {
      _lastError = 'Camera unavailable: $e';
      _statusController.add(_lastError!);
      _scheduleReconnect();
    }
  }

  void _extractFrames() {
    while (_mjpegBuffer.length >= 4) {
      int start = -1;
      for (int i = 0; i < _mjpegBuffer.length - 1; i++) {
        if (_mjpegBuffer[i] == 0xFF && _mjpegBuffer[i + 1] == 0xD8) {
          start = i;
          break;
        }
      }
      if (start < 0) {
        if (_mjpegBuffer.length > 1024 * 1024) _mjpegBuffer.clear();
        return;
      }
      if (start > 0) _mjpegBuffer.removeRange(0, start);

      int end = -1;
      for (int i = 2; i < _mjpegBuffer.length - 1; i++) {
        if (_mjpegBuffer[i] == 0xFF && _mjpegBuffer[i + 1] == 0xD9) {
          end = i + 2;
          break;
        }
      }
      if (end < 0) return;
      final frame = Uint8List.fromList(_mjpegBuffer.sublist(0, end));
      _mjpegBuffer.removeRange(0, end);
      if (!_frameController.isClosed) _frameController.add(frame);
    }
  }

  void _scheduleReconnect() {
    _streamSubscription?.cancel();
    _streamSubscription = null;
    _streamClient?.close();
    _streamClient = null;
    if (!_wantStreaming) return;
    _isStreaming = false;
    Future.delayed(const Duration(seconds: 2), () {
      if (_wantStreaming && !_frameController.isClosed) startStream();
    });
  }

  Future<void> stopStream() async {
    _wantStreaming = false;
    _isStreaming = false;
    await _streamSubscription?.cancel();
    _streamSubscription = null;
    _streamClient?.close();
    _streamClient = null;
    _mjpegBuffer.clear();
    if (!_statusController.isClosed) _statusController.add('Stream stopped');
    notifyListeners();
  }

  Future<Uint8List?> captureSnapshotBytes() async {
    try {
      final response = await http
          .get(Uri.parse('http://$espIp/snapshot'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        _statusController.add('Snapshot captured');
        return response.bodyBytes;
      }
      _lastError = 'Snapshot HTTP ${response.statusCode}';
    } catch (e) {
      _lastError = 'Snapshot failed: $e';
    }
    _statusController.add(_lastError ?? 'Snapshot failed');
    return null;
  }

  Future<bool> capturePhoto() async => (await captureSnapshotBytes()) != null;

  Future<String?> captureAndStoreSnapshot() async {
    final bytes = await captureSnapshotBytes();
    if (bytes == null) return null;
    try {
      final now = DateTime.now().toUtc();
      final path = '${PyroGuardConfig.cameraDeviceId}/${now.millisecondsSinceEpoch}.jpg';
      await Supabase.instance.client.storage.from(PyroGuardConfig.incidentMediaBucket).uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
          );
      final url = Supabase.instance.client.storage.from(PyroGuardConfig.incidentMediaBucket).getPublicUrl(path);
      final telemetry = CameraTelemetryService.instance.latest;
      await HistoricalService.instance.logCameraEvent({
        'device_id': telemetry?.deviceId.isNotEmpty == true ? telemetry!.deviceId : PyroGuardConfig.cameraDeviceId,
        'camera_device_id': PyroGuardConfig.cameraDeviceId,
        'event_type': 'manual_snapshot',
        'snapshot_url': url,
        'pan_at_capture': _lastStatus?.pan ?? telemetry?.panAngle ?? 90,
        'tilt_at_capture': _lastStatus?.tilt ?? telemetry?.tiltAngle ?? 90,
      });
      _statusController.add('Snapshot stored; metadata retained in Supabase and MySQL');
      return url;
    } catch (e) {
      _lastError = 'Snapshot captured, but Supabase upload failed: $e';
      _statusController.add(_lastError!);
      return null;
    }
  }

  Future<CameraStatus?> getStatus() async {
    try {
      final response = await http
          .get(Uri.parse('http://$espIp/status'))
          .timeout(PyroGuardConfig.localRequestTimeout);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final map = decoded is Map<String, dynamic> ? decoded : Map<String, dynamic>.from(decoded as Map);
        _lastStatus = CameraStatus.fromJson(map);
        _lastError = null;
        notifyListeners();
        return _lastStatus;
      }
      _lastError = 'Camera status HTTP ${response.statusCode}';
    } catch (e) {
      _lastError = 'Camera status unavailable: $e';
    }
    notifyListeners();
    return null;
  }

  // Current DFR1154 firmware performs motion analysis automatically and does
  // not expose mutable night-vision/motion routes. Keep these methods for old
  // screens without pretending a command succeeded.
  Future<bool> setNightVision(bool enabled) async {
    _statusController.add('Night-vision control is not exposed by the current camera firmware');
    return false;
  }

  Future<bool> setMotionDetection(bool enabled) async {
    _statusController.add('Motion analysis is managed by the camera firmware');
    return false;
  }

  Future<List<AlertLog>> getEvidencePhotos() async {
    try {
      final rows = await HistoricalService.instance.fetchIncidentHistory(limit: 50);
      return rows.map(AlertLog.fromMap).toList();
    } catch (e) {
      debugPrint('Error fetching mirrored evidence history: $e');
      return [];
    }
  }

  Future<List<CameraEvent>> getCapturedPhotos() async {
    try {
      final rows = await HistoricalService.instance.fetchCameraEvents(limit: 100);
      return rows.map(CameraEvent.fromMap).toList();
    } catch (e) {
      debugPrint('Error fetching mirrored camera history: $e');
      return [];
    }
  }

  String getPhotoUrl(String filename) {
    final value = filename.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    return Supabase.instance.client.storage
        .from(PyroGuardConfig.incidentMediaBucket)
        .getPublicUrl(value);
  }

  Future<bool> uploadPhotoMetadata(String photoUrl, int pan, int tilt) async {
    try {
      return await HistoricalService.instance.logCameraEvent({
        'device_id': CameraTelemetryService.instance.latest?.deviceId ?? PyroGuardConfig.cameraDeviceId,
        'camera_device_id': PyroGuardConfig.cameraDeviceId,
        'event_type': 'manual_snapshot',
        'snapshot_url': photoUrl,
        'pan_at_capture': pan,
        'tilt_at_capture': tilt,
      });
    } catch (e) {
      debugPrint('Error uploading metadata: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _wantStreaming = false;
    _isStreaming = false;
    _streamSubscription?.cancel();
    _streamClient?.close();
    _frameController.close();
    _statusController.close();
    super.dispose();
  }
}
