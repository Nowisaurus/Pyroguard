import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/pyroguard_config.dart';

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

  void setIp(String ip) {
    final trimmed = ip.trim();
    if (trimmed.isEmpty || trimmed == _ip) return;
    _ip = trimmed;
    notifyListeners();
  }

  void startPolling({Duration interval = const Duration(seconds: 5)}) {
    _timer?.cancel();
    refresh();
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
          _status = MainEspStatus.fromJson(_ip, decoded);
        } else if (decoded is Map) {
          _status = MainEspStatus.fromJson(_ip, Map<String, dynamic>.from(decoded));
        } else {
          _status = MainEspStatus.offline(_ip);
          _lastError = 'Unexpected /status response';
        }
        _lastError = null;
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
