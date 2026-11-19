/// Actual room keys transmitted by the two independent sensor controllers.
/// These keys are stored in Supabase, not just display aliases.
/// ESP32-001: entrance + sala; ESP32-002: kitchen + bedroom.
class CoverageConfig {
  CoverageConfig._();

  static const batchOneController = 'ESP32-001';
  static const batchTwoController = 'ESP32-002';
  static const cameraOne = 'pyroguard_camera_001';

  /// Database room keys in display order.
  static const roomKeys = ['entrance', 'sala', 'kitchen', 'bedroom'];

  static const Map<String, Map<String, String>> _roomLabels = {
    batchOneController: {'entrance': 'Entrance', 'sala': 'Sala'},
    batchTwoController: {'kitchen': 'Kitchen', 'bedroom': 'Bedroom'},
  };

  /// Name shown for one sensor slot of one controller.
  static String roomLabel(String controller, String roomKey) =>
      _roomLabels[controller]?[roomKey] ?? roomKey;

  static List<String> roomsForController(String controller) => switch (controller) {
        batchOneController => const ['entrance', 'sala'],
        batchTwoController => const ['kitchen', 'bedroom'],
        _ => const <String>[],
      };

  static List<String> areasForController(String controller) =>
      [for (final key in roomsForController(controller)) roomLabel(controller, key)];

  /// e.g. "Entrance & Sala".
  static String controllerCoverage(String controller) =>
      areasForController(controller).join(' & ');

  static String batchName(String controller) => switch (controller) {
        batchOneController => 'Batch 1',
        batchTwoController => 'Batch 2',
        _ => controller,
      };

  /// Camera 1 belongs to ESP32-001 (the only camera in the system).
  static String controllerForCamera(String cameraId) => batchOneController;

  /// e.g. "Entrance & Sala" for Camera 1.
  static String cameraCoverage(String cameraId) =>
      controllerCoverage(controllerForCamera(cameraId));

  static String cameraBatch(String cameraId) =>
      batchName(controllerForCamera(cameraId));

  static const controllers = [batchOneController, batchTwoController];

  /// The two reed switches on each controller ("door" and "window" in the
  /// firmware / database). Change the names here only.
  static const Map<String, Map<String, String>> _contactLabels = {
    batchOneController: {'door': 'Entrance door', 'window': 'Sala window'},
    batchTwoController: {'door': 'Fire exit door', 'window': 'Bedroom window'},
  };

  static const contactKeys = ['door', 'window'];

  static String contactLabel(String controller, String contact) =>
      _contactLabels[controller]?[contact] ?? contact;
}
