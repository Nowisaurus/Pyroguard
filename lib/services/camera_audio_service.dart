import 'dart:async';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';
import '../config/pyroguard_config.dart';
import 'camera_telemetry_service.dart';
import 'dual_sync_service.dart';
import 'historical_service.dart';

class CameraAudioService extends ChangeNotifier {
  CameraAudioService._();
  static final CameraAudioService instance = CameraAudioService._();

  final AudioPlayer _listenerPlayer = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _recordSub;
  final List<Uint8List> _sendQueue = [];
  final BytesBuilder _pending = BytesBuilder(copy: false);

  bool _listening = false;
  bool _talking = false;
  bool _sending = false;
  String _status = 'Audio idle';

  bool get listening => _listening;
  bool get talking => _talking;
  String get status => _status;

  String get _ip => CameraTelemetryService.instance.cameraIp;

  Future<void> _auditAudio(String action, Map<String, dynamic> payload) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final record = <String, dynamic>{
      'action': action,
      'camera_ip': _ip,
      ...payload,
      'created_at': now,
    };
    try {
      await DualSyncService.instance.writeMirror(
        recordType: 'camera_audio_control',
        recordKey: '${action}_$now',
        payload: record,
      );
      await HistoricalService.instance.logEvent({
        'event_type': action,
        'message': 'Camera audio control action recorded.',
        'severity': 0,
        'payload': record,
        'created_at': now,
      });
    } catch (_) {}
  }

  Future<bool> _postToggle(String path) async {
    try {
      final r = await http
          .post(Uri.parse('http://$_ip$path'))
          .timeout(PyroGuardConfig.localRequestTimeout);
      return r.statusCode >= 200 && r.statusCode < 300;
    } catch (e) {
      _status = 'Audio command failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> setMicEnabled(bool enabled) async {
    final ok = await _postToggle(enabled ? '/api/mic/on' : '/api/mic/off');
    if (ok) await _auditAudio('camera_audio_microphone_changed', {'enabled': enabled});
    return ok;
  }

  Future<bool> setSpeakerEnabled(bool enabled) async {
    final ok = await _postToggle(enabled ? '/api/speaker/on' : '/api/speaker/off');
    if (ok) await _auditAudio('camera_audio_speaker_changed', {'enabled': enabled});
    return ok;
  }

  /// Continuous listen mode implemented as repeated one-second WAV captures.
  /// This is intentionally half-duplex with Push-to-Talk to avoid acoustic echo.
  Future<void> startListening() async {
    if (_listening) return;
    if (_talking) await stopPushToTalk();
    await setMicEnabled(true);
    _listening = true;
    _status = 'Listening to camera microphone';
    notifyListeners();
    await _auditAudio('camera_listening_started', {'listening': true});

    while (_listening) {
      try {
        final response = await http
            .get(Uri.parse('http://$_ip/api/audio/record?seconds=1'))
            .timeout(const Duration(seconds: 4));
        if (!_listening) break;
        if (response.statusCode == 200 && response.bodyBytes.length > 44) {
          await _listenerPlayer.stop();
          await _listenerPlayer.play(BytesSource(response.bodyBytes));
          // One-second recording plus a small scheduling allowance.
          await Future.delayed(const Duration(milliseconds: 1050));
        } else {
          _status = 'Camera microphone HTTP ${response.statusCode}';
          notifyListeners();
          await Future.delayed(const Duration(seconds: 1));
        }
      } catch (e) {
        if (!_listening) break;
        _status = 'Camera microphone unavailable: $e';
        notifyListeners();
        await Future.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> stopListening() async {
    _listening = false;
    await _listenerPlayer.stop();
    _status = 'Audio idle';
    notifyListeners();
    await _auditAudio('camera_listening_stopped', {'listening': false});
  }

  /// Begins half-duplex Push-to-Talk. Phone/PC microphone PCM16LE 16 kHz mono
  /// is buffered into small chunks and POSTed to the DFR1154 speaker endpoint.
  Future<bool> startPushToTalk() async {
    if (_talking) return true;
    if (_listening) await stopListening();

    final allowed = await _recorder.hasPermission();
    if (!allowed) {
      _status = 'Microphone permission denied';
      notifyListeners();
      return false;
    }

    await setSpeakerEnabled(true);
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: false,
      echoCancel: false,
      noiseSuppress: false,
    ));

    _talking = true;
    _status = 'Push-to-Talk active';
    notifyListeners();
    await _auditAudio('camera_push_to_talk_started', {'talking': true});

    _recordSub = stream.listen((chunk) {
      if (!_talking || chunk.isEmpty) return;
      _pending.add(chunk);
      // ~0.25 sec of PCM16 mono @ 16kHz = 8000 bytes.
      if (_pending.length >= 8000) {
        _sendQueue.add(_pending.takeBytes());
        _drainQueue();
      }
    }, onError: (e) {
      _status = 'Phone microphone error: $e';
      notifyListeners();
    });
    return true;
  }

  Future<void> _drainQueue() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_sendQueue.isNotEmpty) {
        final pcm = _sendQueue.removeAt(0);
        try {
          final response = await http
              .post(
                Uri.parse('http://$_ip/api/audio/play-pcm'),
                headers: const {'Content-Type': 'application/octet-stream'},
                body: pcm,
              )
              .timeout(const Duration(seconds: 4));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            _status = 'Speaker HTTP ${response.statusCode}';
            notifyListeners();
          }
        } catch (e) {
          _status = 'Speaker unavailable: $e';
          notifyListeners();
        }
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> stopPushToTalk() async {
    if (!_talking) return;
    _talking = false;
    await _recordSub?.cancel();
    _recordSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    if (_pending.length > 0) {
      _sendQueue.add(_pending.takeBytes());
      await _drainQueue();
    }
    _status = 'Audio idle';
    notifyListeners();
    await _auditAudio('camera_push_to_talk_stopped', {'talking': false});
  }

  Future<bool> echoTest({int seconds = 3}) async {
    try {
      final r = await http
          .get(Uri.parse('http://$_ip/api/audio/echo-test?seconds=$seconds'))
          .timeout(Duration(seconds: seconds + 5));
      _status = r.statusCode == 200 ? 'Echo test complete' : 'Echo test HTTP ${r.statusCode}';
      notifyListeners();
      await _auditAudio('camera_audio_echo_test', {
        'seconds': seconds,
        'success': r.statusCode == 200,
        'http_status': r.statusCode,
      });
      return r.statusCode == 200;
    } catch (e) {
      _status = 'Echo test failed: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> disposeService() async {
    await stopListening();
    await stopPushToTalk();
    await _listenerPlayer.dispose();
    await _recorder.dispose();
  }
}
