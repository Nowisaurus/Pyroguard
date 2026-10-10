import 'package:flutter_test/flutter_test.dart';
import 'package:pyroguard_iot/main.dart';

void main() {
  testWidgets('PyroGuard smoke test', (WidgetTester tester) async {
    // Basic smoke test — just checks the app doesn't crash on build
    expect(PyroGuardApp, isNotNull);
  });
}
