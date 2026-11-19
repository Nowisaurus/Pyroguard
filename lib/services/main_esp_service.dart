import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/pyroguard_config.dart';
import '../config/camera_network_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MainEspStatus {
  final bool reachable;
  final String ip;
  final String deviceId;
  final double temperature;
  final double humidity;
  final int smokeRaw;
  final String smokeStatus;
  final bool flameDetected;
  final String alertStatus;
  final DateTime checkedAt;

  const MainEspStatus({
    required this.reachable,
    required this.ip,
    required this.deviceId,
    required this.temperature,
    required this.humidity,
    required this.smokeRaw,
    required this.smokeStatus,
    required this.flameDetected,
    required this.alertStatus,
    required this.checkedAt,
  });

  factory MainEspStatus.offline(String ip) => MainEspStatus(
        reachable: false,
        ip: ip,
        deviceId: '',
        temperature: 0,
        humidity: 0,
        smokeRaw: 0,
        smokeStatus: 'UNKNOWN',
        flameDetected: false,
        alertStatus: 'OFFLINE',
        checkedAt: DateTime.now(),
      );

  factory MainEspStatus.fromJson(String ip, Map<String, dynamic> json) => MainEspStatus(
        reachable: true,
        ip: ip,
        deviceId: (json['device_id'] ?? '').toString(),
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0,
        humidity: (json['humidity'] as num?)?.toDouble() ?? 0,
        smokeRaw: (json['smoke_raw'] as num?)?.toInt() ?? 0,
        smokeStatus: (json['smoke_status'] ?? 'UNKNOWN').toString(),
        flameDetected: json['flame_detected'] as bool? ?? false,
        alertStatus: (json['alert_status'] ?? json['alert'] ?? 'UNKNOWN').toString(),
        checkedAt: DateTime.now(),
      );
}

class MainEspService extends ChangeNotifier {
  MainEspService._();
  static final MainEspService instance = MainEspService._();

  String _ip = PyroGuardConfig.mainEspFallbackIp;
  MainEspStatus? _status;
  Timer? _timer;
  bool _busy = false;
  String? _lastError;

  String get ip => _ip;
  MainEspStatus? get status => _status;
  bool get online => _status?.reachable ?? false;
  String? get lastError => _lastError;

  static const _ipKey = 'pyroguard.controller1.ip';
  bool _hasSavedIp = false;

  Future<void> loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_ipKey);
    if (saved != null && CameraNetworkConfig.validIpv4(saved)) {
      _ip = saved;
      _hasSavedIp = true;
      notifyListeners();
    }
  }

  /// ESP32-001 uses DHCP. Camera 1 learns its real address over the direct
  /// LAN link and reports it in /status; use it unless the user saved one.
  void adoptDiscoveredIp(String ip) {
    final trimmed = ip.trim();
    if (_hasSavedIp || trimmed == _ip || !CameraNetworkConfig.validIpv4(trimmed)) {
      return;
    }
    _ip = trimmed;
    notifyListeners();
  }

  /// Saves a confirmed address across application restarts.
  /// This does not change the hardware's Wi-Fi configuration.
  Future<void> setIp(String ip) async {
    final trimmed = ip.trim();
    if (!CameraNetworkConfig.validIpv4(trimmed)) {
      throw ArgumentError('Enter a valid ESP32 IPv4 address');
    }
    final prefs = await SharedPreferences.getInstance();
    final ok = await prefs.setString(_ipKey, trimmed);
    if (!ok) throw StateError('Could not persist ESP32 address');
    _ip = trimmed;
    _hasSavedIp = true;
    notifyListeners();
  }

  void startPolling({Duration interval = const Duration(seconds: 5)}) {
    _timer?.cancel();
    loadSavedIp().then((_) => refresh()).catchError((Object e) {
      debugPrint('Could not restore controller IP: $e');
      return refresh();
    });
    _timer = Timer.periodic(interval, (_) => refresh());
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<MainEspStatus?> refresh() async {
    if (_busy) return _status;
    _busy = true;
    try {
      final uri = Uri.parse('http://$_ip/status');
      final response = await http.get(uri).timeout(PyroGuardConfig.localRequestTimeout);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final id = (decoded['device_id'] ?? '').toString().trim();
          if (id.isNotEmpty && id != PyroGuardConfig.mainDeviceId) {
            throw StateError('Wrong device at $_ip: $id');
          }
          _status = MainEspStatus.fromJson(_ip, decoded);
        } else if (decoded is Map) {
          final body = Map<String, dynamic>.from(decoded);
          final id = (body['device_id'] ?? '').toString().trim();
          if (id.isNotEmpty && id != PyroGuardConfig.mainDeviceId) {
            throw StateError('Wrong device at $_ip: $id');
          }
          _status = MainEspStatus.fromJson(_ip, body);
        } else {
          _status = MainEspStatus.offline(_ip);
          _lastError = 'Unexpected /status response';
        }
        if (_status?.reachable == true) _lastError = null;
      } else if (response.statusCode == 401) {
        // /status is protected by the device key, which the app does not
        // hold. The unauthenticated /health route still proves the
        // controller is reachable on the LAN (sensor values come from cloud).
        final health = await http
            .get(Uri.parse('http://$_ip/health'))
            .timeout(PyroGuardConfig.localRequestTimeout);
        final decoded = health.statusCode == 200 ? jsonDecode(health.body) : null;
        final id = decoded is Map ? '${decoded['device_id'] ?? ''}'.trim() : '';
        if (id == PyroGuardConfig.mainDeviceId) {
          _status = MainEspStatus.fromJson(_ip, {'device_id': id, 'alert_status': 'REACHABLE'});
          _lastError = null;
        } else {
          _status = MainEspStatus.offline(_ip);
          _lastError = 'HTTP ${health.statusCode} from /health';
        }
      } else {
        _status = MainEspStatus.offline(_ip);
        _lastError = 'HTTP ${response.statusCode}';
      }
    } catch (e) {
      _status = MainEspStatus.offline(_ip);
      _lastError = '$e';
    } finally {
      _busy = false;
      notifyListeners();
    }
    return _status;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
