import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/camera_endpoint.dart';

/// Incremental MJPEG parser.
///
/// The PyroGuard camera firmware sends a `Content-Length` header for every
/// JPEG part, so a frame is normally cut out without scanning its body. If a
/// camera omits the header, the parser falls back to the JPEG start (FFD8)
/// and end (FFD9) markers. Scanning resumes where it stopped, so large frames
/// are never rescanned from the start for every network chunk.
class MjpegParser {
  MjpegParser({this.maxBufferBytes = 2 * 1024 * 1024});

  final int maxBufferBytes;
  Uint8List _buffer = Uint8List(64 * 1024);
  int _length = 0;
  int _scanFrom = 0;

  int get bufferedBytes => _length;

  void reset() {
    _length = 0;
    _scanFrom = 0;
  }

  /// Adds network bytes and returns the newest complete JPEG, or null.
  /// Older complete frames in the same chunk are dropped (latest wins).
  Uint8List? add(List<int> chunk) {
    _append(chunk);
    Uint8List? latest;
    while (true) {
      final frame = _nextFrame();
      if (frame == null) break;
      latest = frame;
    }
    if (_length > maxBufferBytes) reset(); // corrupt stream: resynchronise
    return latest;
  }

  void _append(List<int> chunk) {
    final needed = _length + chunk.length;
    if (needed > _buffer.length) {
      var size = _buffer.length * 2;
      while (size < needed) {
        size *= 2;
      }
      final grown = Uint8List(size);
      grown.setRange(0, _length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_length, needed, chunk);
    _length = needed;
  }

  int _indexOfMarker(int second, int from) {
    for (var i = from; i < _length - 1; i++) {
      if (_buffer[i] == 0xFF && _buffer[i + 1] == second) return i;
    }
    return -1;
  }

  /// Reads "Content-Length: N" from the part headers in [0, end).
  int? _contentLength(int end) {
    if (end <= 0 || end > 1024) return null;
    final header = String.fromCharCodes(_buffer, 0, end).toLowerCase();
    final at = header.lastIndexOf('content-length:');
    if (at < 0) return null;
    final lineEnd = header.indexOf('\n', at);
    final value = header
        .substring(at + 15, lineEnd < 0 ? header.length : lineEnd)
        .trim();
    final parsed = int.tryParse(value);
    return parsed != null && parsed > 4 && parsed <= maxBufferBytes
        ? parsed
        : null;
  }

  void _consume(int count) {
    if (count >= _length) {
      _length = 0;
    } else {
      _buffer.setRange(0, _length - count, _buffer, count);
      _length -= count;
    }
    _scanFrom = 0;
  }

  Uint8List? _nextFrame() {
    if (_length < 4) return null;
    final start = _indexOfMarker(0xD8, 0);
    if (start < 0) {
      // Only part headers so far. Keep a bounded tail for the next chunk.
      if (_length > 4096) _consume(_length - 1);
      return null;
    }

    final declared = _contentLength(start);
    if (declared != null) {
      if (start + declared > _length) return null; // wait for the rest
      final end = start + declared;
      if (_buffer[end - 2] == 0xFF && _buffer[end - 1] == 0xD9) {
        final frame =
            Uint8List.fromList(Uint8List.sublistView(_buffer, start, end));
        _consume(end);
        return frame;
      }
      // Declared length disagrees with the data: fall back to markers.
    }

    final scanStart = _scanFrom > start + 2 ? _scanFrom : start + 2;
    final eoi = _indexOfMarker(0xD9, scanStart);
    if (eoi < 0) {
      _scanFrom = _length > 1 ? _length - 1 : 0;
      return null;
    }
    final end = eoi + 2;
    final frame =
        Uint8List.fromList(Uint8List.sublistView(_buffer, start, end));
    _consume(end);
    return frame;
  }
}

/// One MJPEG connection to one camera.
///
/// Use [MjpegFeedHub] instead of constructing this directly: the ESP32
/// stream server serves ONE viewer at a time, so every screen showing the
/// same camera must share a single connection.
class MjpegLiveFeed extends ChangeNotifier {
  MjpegLiveFeed({required this.cameraId, required List<String> addresses})
      : addresses = _clean(addresses);

  final String cameraId;

  List<String> addresses;
  Uint8List? frame;
  String? activeIp;
  String? error;
  bool connected = false;

  /// Measured delivery rate of the camera stream (frames per second).
  double fps = 0;
  DateTime? lastFrameAt;

  static const _minNotifyInterval = Duration(milliseconds: 33); // ~30 fps
  static const _stallTimeout = Duration(seconds: 6);
  static const _retryDelays = [1, 2, 3, 5, 8];

  http.Client? _client;
  StreamSubscription<List<int>>? _subscription;
  Timer? _retry;
  Timer? _watchdog;
  final MjpegParser _parser = MjpegParser();
  bool _disposed = false;
  bool _starting = false;
  bool _stopped = false;
  int _generation = 0;
  int _failures = 0;
  int _fpsFrames = 0;
  DateTime _fpsWindow = DateTime.now();
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  static List<String> _clean(List<String> values) => {
        for (final v in values)
          if (v.trim().isNotEmpty) v.trim(),
      }.toList();

  /// HTTPS website: the Dart feed never connects (the browser blocks http://
  /// and cannot stream an endless response); MjpegFrameView plays the
  /// camera's secure tunnel address with an <img> element instead.
  static bool get localBlocked => CameraEndpoint.httpsPage;
  static String get localBlockedMessage => CameraTunnel.instance.ready
      ? 'Live video through the secure camera link.'
      : 'Waiting for the secure camera link. On the PC on the Pyroguard_Team Wi-Fi, run '
          'start-camera-tunnel.bat. Motion photos still appear.';

  void start() {
    _stopped = false;
    if (localBlocked) {
      if (error != localBlockedMessage) {
        error = localBlockedMessage;
        // Not during a build: start() can be called from initState.
        scheduleMicrotask(() {
          if (!_disposed) notifyListeners();
        });
      }
      return;
    }
    if (_disposed || _starting || _subscription != null || addresses.isEmpty) {
      return;
    }
    _retry?.cancel();
    _connect(++_generation);
  }

  Future<void> _connect(int generation) async {
    _starting = true;
    final candidates = [
      if (activeIp != null && addresses.contains(activeIp)) activeIp!,
      ...addresses.where((ip) => ip != activeIp),
    ];
    for (final ip in candidates) {
      if (_disposed || generation != _generation) return;
      final client = http.Client();
      try {
        final request = http.Request(
          'GET',
          CameraEndpoint.url(cameraId, ip, '/stream', port: 81),
        );
        final response =
            await client.send(request).timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode}');
        }
        if (_disposed || generation != _generation) {
          client.close();
          return;
        }
        _client = client;
        activeIp = ip;
        error = null;
        _starting = false;
        _parser.reset();
        _lastFrame = DateTime.now(); // grace period for the first frame
        _subscription = response.stream.listen(
          (chunk) => _accept(chunk, generation),
          onError: (Object e) => _lost('Stream error: $e', generation),
          onDone: () => _lost('Stream disconnected', generation),
          cancelOnError: true,
        );
        _watchdog?.cancel();
        _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
          if (generation == _generation &&
              !_disposed &&
              DateTime.now().difference(_lastFrame) > _stallTimeout) {
            _lost('Camera stream stalled (no fresh JPEG frames)', generation);
          }
        });
        notifyListeners();
        return;
      } catch (e) {
        client.close();
        error = 'Unable to stream from $ip: $e';
      }
    }
    _starting = false;
    if (!_disposed && generation == _generation) {
      connected = false;
      notifyListeners();
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_disposed || _stopped) return;
    final seconds =
        _retryDelays[_failures.clamp(0, _retryDelays.length - 1).toInt()];
    _failures++;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), start);
  }

  void _accept(List<int> chunk, int generation) {
    if (_disposed || generation != _generation) return;
    final latest = _parser.add(chunk);
    if (latest == null) return;

    final now = DateTime.now();
    _lastFrame = now;
    lastFrameAt = now;
    _fpsFrames++;
    final windowMs = now.difference(_fpsWindow).inMilliseconds;
    if (windowMs >= 2000) {
      fps = _fpsFrames * 1000 / windowMs;
      _fpsFrames = 0;
      _fpsWindow = now;
    }

    frame = latest;
    final becameLive = !connected;
    if (becameLive) {
      connected = true;
      error = null;
      _failures = 0;
    }
    // Viewers decode latest-wins, so notifying at up to ~30 fps never
    // builds a backlog; this cap only avoids pointless rebuilds.
    if (becameLive || now.difference(_lastNotified) >= _minNotifyInterval) {
      _lastNotified = now;
      notifyListeners();
    }
  }

  void _lost(String reason, int generation) {
    if (_disposed || generation != _generation) return;
    _teardown();
    connected = false;
    error = reason;
    fps = 0;
    notifyListeners();
    _scheduleRetry();
  }

  void _teardown() {
    _subscription?.cancel();
    _subscription = null;
    _watchdog?.cancel();
    _watchdog = null;
    _client?.close();
    _client = null;
    _parser.reset();
    _starting = false;
  }

  /// Updates the candidate addresses. A working connection is kept when its
  /// address is still a candidate, so two screens never fight over it.
  void updateAddresses(List<String> next) {
    final cleaned = _clean(next);
    if (listEquals(addresses, cleaned)) return;
    addresses = cleaned;
    if (activeIp != null && cleaned.contains(activeIp)) return;
    stop();
    frame = null;
    activeIp = null;
    _failures = 0;
    start();
  }

  /// Stops streaming until [start] is called (e.g. camera switched off).
  void stop() {
    _stopped = true;
    ++_generation;
    _retry?.cancel();
    _teardown();
    connected = false;
    fps = 0;
  }

  /// Reconnects immediately (manual refresh button).
  void reconnect() {
    stop();
    _failures = 0;
    start();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

/// Shares one MJPEG connection per camera between all visible screens.
///
/// The overview card and the camera detail screen previously opened two
/// separate streams; the ESP32 can serve only one, so the detail screen fell
/// back to a 3-second snapshot. Now both screens show the same live stream.
class MjpegFeedHub {
  MjpegFeedHub._();
  static final MjpegFeedHub instance = MjpegFeedHub._();

  /// Keeps the connection briefly after the last viewer leaves, so moving
  /// between the overview and a camera screen never reconnects.
  static const releaseGrace = Duration(seconds: 5);

  final Map<String, _HubEntry> _entries = {};

  MjpegLiveFeed acquire(String cameraId, List<String> addresses) {
    final existing = _entries[cameraId];
    if (existing != null) {
      existing.refs++;
      existing.releaseTimer?.cancel();
      existing.releaseTimer = null;
      if (addresses.isNotEmpty) existing.feed.updateAddresses(addresses);
      existing.feed.start();
      return existing.feed;
    }
    final feed = MjpegLiveFeed(cameraId: cameraId, addresses: addresses);
    _entries[cameraId] = _HubEntry(feed);
    feed.start();
    return feed;
  }

  void release(String cameraId, MjpegLiveFeed feed) {
    final entry = _entries[cameraId];
    if (entry == null || !identical(entry.feed, feed)) return;
    entry.refs--;
    if (entry.refs > 0) return;
    entry.releaseTimer?.cancel();
    entry.releaseTimer = Timer(releaseGrace, () {
      if (entry.refs > 0) return;
      if (identical(_entries[cameraId], entry)) _entries.remove(cameraId);
      entry.feed.dispose();
    });
  }
}

class _HubEntry {
  _HubEntry(this.feed);
  final MjpegLiveFeed feed;
  int refs = 1;
  Timer? releaseTimer;
}
