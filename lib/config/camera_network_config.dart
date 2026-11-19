import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-installation camera address overrides. This cannot reconfigure the
/// ESP32 Wi-Fi itself; it changes the LAN destination used by Flutter.
class CameraNetworkConfig extends ChangeNotifier {
  CameraNetworkConfig._();
  static final instance = CameraNetworkConfig._();

  final Map<String, String> _overrides = {};
  bool _loaded = false;
  static const cameraOne = 'pyroguard_camera_001';

  static bool validIpv4(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      if (p.isEmpty || p.length > 3) return false;
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255 && p == n.toString();
    });
  }

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    for (final id in [cameraOne]) {
      final ip = prefs.getString('pyroguard.camera.ip.$id') ?? '';
      if (validIpv4(ip)) _overrides[id] = ip;
    }
    _loaded = true;
    notifyListeners();
  }

  String resolve(String deviceId, String fallback) {
    // A user-confirmed LAN IP must override an obsolete compiled fallback.
    // The settings screen can clear this override when the camera moves.
    final saved = _overrides[deviceId];
    if (saved != null && validIpv4(saved)) return saved;
    final authoritative = fallback.trim();
    if (validIpv4(authoritative)) return authoritative;
    return '';
  }

  Future<void> save(String deviceId, String ip) async {
    if (deviceId != cameraOne) {
      throw ArgumentError('Unknown camera device');
    }
    if (!validIpv4(ip)) throw ArgumentError('Enter a valid IPv4 address');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pyroguard.camera.ip.$deviceId', ip.trim());
    _overrides[deviceId] = ip.trim();
    notifyListeners();
  }

  Future<void> clear(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('pyroguard.camera.ip.$deviceId');
    _overrides.remove(deviceId);
    notifyListeners();
  }
}
