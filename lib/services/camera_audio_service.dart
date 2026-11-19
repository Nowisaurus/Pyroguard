import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../config/pyroguard_config.dart';
import '../config/camera_network_config.dart';
import 'camera_telemetry_service.dart';
import 'historical_service.dart';

class CameraAudioService extends ChangeNotifier {
  CameraAudioService._(this.cameraId, this._ipProvider);

  static final CameraAudioService instance = CameraAudioService._(
    'pyroguard_camera_001',
    () => CameraNetworkConfig.instance.resolve(
      CameraNetworkConfig.cameraOne,
      CameraTelemetryService.instance.cameraIp.trim(),
    ),
  );


  final String cameraId;
  final String Function() _ipProvider;

  final AudioPlayer _player = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _recordSubscription;

  final List<Uint8List> _queue = [];
  final BytesBuilder _pending = BytesBuilder(copy: false);

  bool _listening = false;
  bool _talking = false;
  bool _sending = false;
  bool _disposed = false;

  int _session = 0;

  String _status = 'Audio idle';

  bool get listening => _listening;
  bool get talking => _talking;
  String get status => _status;

  String get _ip => _ipProvider().trim();

  void _setStatus(String value) {
    _status = value;

    if (!_disposed) {
      notifyListeners();
    }
  }

  Uri _uri(String path) {
    if (_ip.isEmpty) {
      throw StateError(
        'Camera IP unavailable.',
      );
    }

    return Uri(
      scheme: 'http',
      host: _ip,
      path: path,
    );
  }

  Future<void> _audit(
    String action,
    Map<String, dynamic> payload,
  ) async {
    final now = DateTime.now().toUtc().toIso8601String();

    try {
      await HistoricalService.instance.logEvent({
        'event_type': action,
        'message': 'Camera audio action recorded.',
        'severity': 0,
        'payload': {
          'action': action,
          'camera_ip': _ip,
          'camera_device_id': cameraId,
          ...payload,
          'created_at': now,
        },
        'created_at': now,
      });
    } catch (error) {
      debugPrint('Audio audit error: $error');
    }
  }

  Future<bool> _postToggle(String path) async {
    try {
      final response = await http
          .post(_uri(path))
          .timeout(PyroGuardConfig.localRequestTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }

      _setStatus(
        'Audio HTTP ${response.statusCode}',
      );
    } catch (error) {
      _setStatus(
        'Audio command failed: $error',
      );
    }

    return false;
  }

  Future<bool> setMicEnabled(bool enabled) async {
    final ok = await _postToggle(
      enabled ? '/api/mic/on' : '/api/mic/off',
    );

    if (ok) {
      await _audit(
        'camera_microphone_changed',
        {'enabled': enabled},
      );
    }

    return ok;
  }

  Future<bool> setSpeakerEnabled(bool enabled) async {
    final ok = await _postToggle(
      enabled ? '/api/speaker/on' : '/api/speaker/off',
    );

    if (ok) {
      await _audit(
        'camera_speaker_changed',
        {'enabled': enabled},
      );
    }

    return ok;
  }

  Future<void> startListening() async {
    if (_listening) return;

    if (_talking) {
      await stopPushToTalk();
    }

    final enabled = await setMicEnabled(true);

    if (!enabled) {
      _setStatus('Camera microphone unavailable');
      return;
    }

    _listening = true;
    final currentSession = ++_session;

    _setStatus('Listening to camera microphone');

    await _audit(
      'camera_listening_started',
      {'listening': true},
    );

    while (_listening && currentSession == _session && !_disposed) {
      try {
        final response = await http
            .get(_uri('/audio/record'))
            .timeout(const Duration(seconds: 5));

        if (!_listening || currentSession != _session) {
          break;
        }

        if (response.statusCode != 200) {
          _setStatus(
            'Camera microphone HTTP ${response.statusCode}',
          );

          await Future.delayed(
            const Duration(seconds: 1),
          );

          continue;
        }

        final wav = response.bodyBytes;

        if (!_isWav(wav)) {
          _setStatus(
            'Camera returned invalid WAV audio',
          );

          await Future.delayed(
            const Duration(milliseconds: 500),
          );

          continue;
        }

        await _player.stop();

        await _player.play(
          BytesSource(wav),
        );

        // The firmware records one second of WAV.
        await Future.delayed(
          const Duration(milliseconds: 1050),
        );
      } catch (error) {
        if (!_listening) break;

        _setStatus(
          'Camera microphone unavailable: $error',
        );

        await Future.delayed(
          const Duration(seconds: 1),
        );
      }
    }
  }

  Future<void> stopListening() async {
    final wasListening = _listening;

    _listening = false;
    _session++;

    await _player.stop();

    _setStatus('Audio idle');

    if (wasListening) {
      await _audit(
        'camera_listening_stopped',
        {'listening': false},
      );
    }
  }

  Future<bool> startPushToTalk() async {
    if (_talking) return true;

    if (_listening) {
      await stopListening();
    }

    try {
      final allowed = await _recorder.hasPermission();

      if (!allowed) {
        _setStatus('Microphone permission denied');
        return false;
      }

      final speakerReady = await setSpeakerEnabled(true);

      if (!speakerReady) {
        _setStatus(
          'Camera speaker unavailable',
        );
        return false;
      }

      // Clear audio remaining from an older PTT session.
      _queue.clear();

      if (_pending.length > 0) {
        _pending.takeBytes();
      }

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: false,
          echoCancel: false,
          noiseSuppress: false,
        ),
      );

      _talking = true;
      _setStatus('Push-to-Talk active');

      await _audit(
        'camera_push_to_talk_started',
        {'talking': true},
      );

      _recordSubscription = stream.listen(
        (chunk) {
          if (!_talking || chunk.isEmpty) return;

          _pending.add(chunk);

          // 8000 bytes = 250 ms of PCM16 mono at 16 kHz.
          if (_pending.length >= 8000) {
            final pcm = _pending.takeBytes();
            _enqueueAudio(pcm);
          }
        },
        onError: (Object error) {
          _setStatus(
            'Microphone recording error: $error',
          );
        },
      );

      return true;
    } catch (error) {
      _talking = false;

      try {
        await _recorder.stop();
      } catch (_) {}

      _setStatus(
        'Push-to-Talk failed: $error',
      );

      return false;
    }
  }

  void _enqueueAudio(Uint8List pcm) {
    if (pcm.isEmpty) return;

    // Prevent unlimited memory growth if Wi-Fi slows down.
    if (_queue.length >= 4) {
      _queue.removeAt(0);
    }

    _queue.add(pcm);
    _drainQueue();
  }

  Future<void> _drainQueue() async {
    if (_sending) return;

    _sending = true;

    try {
      while (_queue.isNotEmpty && !_disposed) {
        final pcm = _queue.removeAt(0);

        final wav = _pcmToWav(pcm);

        try {
          // Camera 1 (DFR1154) two-way audio: raw WAV body to /audio/play.
          final response = await http.post(
            _uri('/audio/play'),
            headers: const {'Content-Type': 'audio/wav'},
            body: wav,
          ).timeout(const Duration(seconds: 5));

          if (response.statusCode < 200 || response.statusCode >= 300) {
            _setStatus(
              'Camera speaker HTTP ${response.statusCode}',
            );
          }
        } catch (error) {
          _setStatus(
            'Camera speaker unavailable: $error',
          );
        }
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> stopPushToTalk() async {
    if (!_talking) return;

    _talking = false;

    await _recordSubscription?.cancel();
    _recordSubscription = null;

    try {
      await _recorder.stop();
    } catch (error) {
      debugPrint('Recorder stop error: $error');
    }

    if (_pending.length > 0) {
      _enqueueAudio(_pending.takeBytes());
    }

    // Wait for the queued WAV data to finish sending.
    while (_sending || _queue.isNotEmpty) {
      if (!_sending && _queue.isNotEmpty) {
        await _drainQueue();
      } else {
        await Future.delayed(
          const Duration(milliseconds: 40),
        );
      }
    }

    _setStatus('Audio idle');

    await _audit(
      'camera_push_to_talk_stopped',
      {'talking': false},
    );
  }

  bool _isWav(Uint8List bytes) {
    if (bytes.length < 44) return false;

    return bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x41 &&
        bytes[10] == 0x56 &&
        bytes[11] == 0x45;
  }

  Uint8List _pcmToWav(Uint8List pcm) {
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    const headerSize = 44;

    final dataSize = pcm.length;
    final totalSize = headerSize + dataSize;

    final wav = Uint8List(totalSize);
    final data = ByteData.sublistView(wav);

    void writeString(int offset, String value) {
      for (int i = 0; i < value.length; i++) {
        wav[offset + i] = value.codeUnitAt(i);
      }
    }

    writeString(0, 'RIFF');

    data.setUint32(
      4,
      totalSize - 8,
      Endian.little,
    );

    writeString(8, 'WAVE');
    writeString(12, 'fmt ');

    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, channels, Endian.little);

    data.setUint32(
      24,
      sampleRate,
      Endian.little,
    );

    data.setUint32(
      28,
      sampleRate * channels * (bitsPerSample ~/ 8),
      Endian.little,
    );

    data.setUint16(
      32,
      channels * (bitsPerSample ~/ 8),
      Endian.little,
    );

    data.setUint16(
      34,
      bitsPerSample,
      Endian.little,
    );

    writeString(36, 'data');

    data.setUint32(
      40,
      dataSize,
      Endian.little,
    );

    wav.setRange(44, totalSize, pcm);

    return wav;
  }

  Future<bool> echoTest({
    int seconds = 3,
  }) async {
    // The uploaded firmware has no echo-test endpoint.
    _setStatus(
      'Echo test is not supported by the current firmware.',
    );

    return false;
  }

  Future<void> disposeService() async {
    await stopListening();
    await stopPushToTalk();

    _disposed = true;

    await _player.dispose();
    await _recorder.dispose();
  }
}
