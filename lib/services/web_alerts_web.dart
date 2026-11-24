// Web builds: use the browser Notification API through dart:html.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html';

bool webAlertsSupported() {
  try {
    Notification.permission;
    return true;
  } catch (_) {
    return false;
  }
}

/// 'granted', 'denied', 'default' (not asked yet) or 'unsupported'.
String webAlertPermission() {
  if (!webAlertsSupported()) return 'unsupported';
  try {
    return Notification.permission ?? 'unsupported';
  } catch (_) {
    return 'unsupported';
  }
}

/// Browsers only show the permission prompt after a real tap/click, so call
/// this from a button handler.
Future<String> webRequestAlertPermission() async {
  if (!webAlertsSupported()) return 'unsupported';
  try {
    return await Notification.requestPermission();
  } catch (_) {
    return webAlertPermission();
  }
}

bool webShowAlert({
  required String title,
  required String body,
  required String tag,
  bool urgent = false,
  void Function()? onClick,
}) {
  if (webAlertPermission() != 'granted') return false;
  try {
    final n = Notification(
      title,
      body: body,
      tag: tag,
      icon: 'icons/Icon-192.png',
    );
    // Clicking the browser notification brings PyroGuard to the front and
    // opens the page the alert is about.
    n.onClick.listen((_) {
      n.close();
      onClick?.call();
    });
    return true;
  } catch (_) {
    // Chrome on Android only allows notifications from a service worker;
    // the in-app banner still appears there.
    return false;
  }
}
