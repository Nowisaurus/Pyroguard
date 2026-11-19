// Mobile/desktop builds: browser notifications do not exist here.
// flutter_local_notifications handles Android/iOS instead.
bool webAlertsSupported() => false;
String webAlertPermission() => 'unsupported';
Future<String> webRequestAlertPermission() async => 'unsupported';
bool webShowAlert({
  required String title,
  required String body,
  required String tag,
  bool urgent = false,
}) =>
    false;
