/// LAN URL builder for Camera 1 (pyroguard_camera_001, DFR1154 with two-way audio).
/// PyroGuard now uses this single camera; the Camera 2 monitoring unit was removed.
class CameraEndpoint {
  CameraEndpoint._();

  static Uri url(String cameraId, String ip, String path, {int? port, Map<String, String>? query}) =>
      Uri(scheme: 'http', host: ip, port: port, path: path,
          queryParameters: (query == null || query.isEmpty) ? null : query);
}
