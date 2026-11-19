import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'sensor_service.dart';
import 'historical_service.dart';
import 'dual_sync_service.dart';
import 'web_alerts_stub.dart' if (dart.library.js_interop) 'web_alerts_web.dart';

/// Which kind of alert is being raised. Each kind has its own Android
/// channel so the user can tune them separately in phone settings.
enum PyroAlertKind { fire, warning, intrusion, deviceStatus, test }

/// Every alert in PyroGuard goes through this service, on all platforms:
///  * Android/iOS: system notification (flutter_local_notifications)
///  * Web: browser notification (Notification API) while the tab is open
///  * Everywhere: an in-app banner, so an alert is visible even when the
///    system notification permission was refused.
class NotificationService {
  static FlutterLocalNotificationsPlugin? _plugin;
  static final AudioPlayer _audio = AudioPlayer();
  static bool _alarmPlaying = false;
  static Timer? _vibTimer;
  static Timer? _reNotifyTimer;

  // Notification ids: one per alert kind, so a newer alert of the same kind
  // replaces the older one instead of stacking duplicates.
  static const int _warningId = 0;
  static const int _fireId = 1;
  static const int _intrusionId = 2;
  static const int _deviceStatusId = 3;
  static const int _testId = 9;
  static const int _cameraMotionId = 4;
  static const int _contactEventId = 5;

  /// Attached to MaterialApp.scaffoldMessengerKey in main.dart, so alerts
  /// can show an in-app banner from anywhere (services have no context).
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// Set by main.dart: opens a route when the user taps a notification.
  static void Function(String route)? onOpenRoute;
  static String? _pendingRoute;

  // Some browsers block audio.play() unless it follows a real user
  // gesture (click/tap) somewhere on the page — an alarm triggered by
  // an incoming Supabase event isn't a gesture, so playback can be
  // silently blocked on web. When that happens this flips true so the
  // UI (the fire overlay) can show a "tap to enable alarm sound"
  // button that retries playback from an actual click.
  static bool alarmSoundBlocked = false;

  // ── Contacts ──────────────────────────────────────────────────────
  // These start as sane defaults and are overwritten by loadBfpContact()
  // with whatever the signed-in user has actually saved (Device →
  // BFP Emergency Contacts → Edit) — nobody has confirmed the *real*
  // local BFP office's number/address yet, so this must stay editable
  // rather than a fixed constant pretending to be verified.
  static String bfpPhone = '';
  static String bfpSms   = '';
  static String? bfpName;
  static String? bfpStation;
  static String? bfpPersonnel;
  static String? bfpRank;
  static String? bfpAddress;
  static bool bfpConfirmedByUser = false;

  static String? _userPhone() =>
      Supabase.instance.client.auth.currentUser?.userMetadata?['phone_number'] as String?;

  /// Loads the signed-in user's saved BFP contact (their local station's
  /// name/number/address) from emergency_contacts, if they've entered
  /// one. Call once after sign-in / on Device or Settings screen init;
  /// safe to call repeatedly. Falls back to the placeholder defaults
  /// above and leaves bfpConfirmedByUser false if nothing is saved yet.
  static Future<void> loadBfpContact() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      bfpPhone = ''; bfpSms = ''; bfpName = null; bfpStation = null;
      bfpPersonnel = null; bfpRank = null; bfpAddress = null;
      bfpConfirmedByUser = false;
      return;
    }
    try {
      final row = await Supabase.instance.client
          .from('emergency_contacts')
          .select()
          .eq('user_id', uid)
          .eq('is_primary', true)
          .maybeSingle();
      // Update cache only after the database query succeeds.
      bfpPhone = (row?['phone'] as String?)?.trim() ?? '';
      bfpSms = bfpPhone;
      bfpStation = (row?['station_name'] ?? row?['name'])?.toString();
      bfpName = bfpStation;
      bfpPersonnel = row?['personnel_name']?.toString();
      bfpRank = row?['rank_position']?.toString();
      bfpAddress = row?['address']?.toString();
      bfpConfirmedByUser = (row?['is_confirmed'] as bool?) ?? false;
    } catch (e) {
      debugPrint('BFP contact refresh failed; cached contact retained: $e');
    }
  }

  /// Saves/updates the user's BFP contact record. Upserts onto the
  /// existing primary row if one exists, otherwise inserts a new one.
  static Future<void> saveBfpContact({required String name, required String phone, String? address, String? personnelName, String? rankPosition}) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final existing = await Supabase.instance.client
.from('emergency_contacts').select('id').eq('user_id', uid).eq('is_primary', true).maybeSingle();
    final data = {
      'user_id': uid, 'name': name, 'station_name': name, 'personnel_name': personnelName, 'rank_position': rankPosition, 'phone': phone, 'address': address, 'is_primary': true, 'is_confirmed': true,
    };
    if (existing != null) {
      await Supabase.instance.client.from('emergency_contacts').update(data).eq('id', existing['id']);
    } else {
      await Supabase.instance.client.from('emergency_contacts').insert(data);
    }
    await DualSyncService.instance.writeMirror(
      recordType: 'emergency_contacts',
      recordKey: uid,
      payload: Map<String, dynamic>.from(data),
    );
    await HistoricalService.instance.logEvent({
      'event_type': 'bfp_contact_updated',
      'message': 'Saved BFP emergency contact was updated.',
      'severity': 0,
      'payload': data,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    bfpPhone = phone;
    bfpSms   = phone;
    bfpName = name;
    bfpStation = name;
    bfpPersonnel = personnelName;
    bfpRank = rankPosition;
    bfpAddress = address;
    bfpConfirmedByUser = true;
  }

  // ── Init ──────────────────────────────────────────────────────────
  static const _channels = <AndroidNotificationChannel>[
    AndroidNotificationChannel('pyroguard_fire', 'Fire Alerts',
        description: 'Confirmed fire emergencies (smoke + flame).',
        importance: Importance.max),
    AndroidNotificationChannel('pyroguard_security', 'Security Alerts',
        description: 'Door opened while the system is armed.',
        importance: Importance.max),
    AndroidNotificationChannel('pyroguard_warn', 'Warnings',
        description: 'Smoke, flame or high temperature without a confirmed fire.',
        importance: Importance.high),
    AndroidNotificationChannel('pyroguard_status', 'Device Status',
        description: 'Controller went offline or came back online.',
        importance: Importance.defaultImportance),
  ];

  static Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    // Web has no flutter_local_notifications implementation; the browser
    // Notification API is used instead and needs no setup here.
    if (kIsWeb) return;
    _plugin = plugin;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (response) => _openRoute(response.payload),
    );
    final androidImpl = plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final channel in _channels) {
      await androidImpl?.createNotificationChannel(channel);
    }
    // The app was started by tapping a notification: open that screen once
    // the signed-in shell is ready (see openPendingRoute()).
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      _pendingRoute = launch?.notificationResponse?.payload;
    }
    await requestPermission();
  }

  static void _openRoute(String? route) {
    if (route == null || route.isEmpty) return;
    final open = onOpenRoute;
    if (open == null) {
      _pendingRoute = route;
    } else {
      open(route);
    }
  }

  /// Called by the dashboard shell after sign-in.
  static void openPendingRoute() {
    final route = _pendingRoute;
    _pendingRoute = null;
    if (route != null) _openRoute(route);
  }

  /// Asks for notification permission. On web this must run from a button
  /// tap (browsers ignore the request otherwise). Returns true when allowed.
  static Future<bool> requestPermission() async {
    if (kIsWeb) return await webRequestAlertPermission() == 'granted';
    try {
      final androidImpl = _plugin
          ?.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        return await androidImpl.requestNotificationsPermission() ?? false;
      }
      final iosImpl = _plugin
          ?.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      if (iosImpl != null) {
        return await iosImpl.requestPermissions(alert: true, badge: true, sound: true) ?? false;
      }
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
    return _plugin != null;
  }

  /// True when the system/browser will actually display PyroGuard alerts.
  static Future<bool> permissionGranted() async {
    if (kIsWeb) return webAlertPermission() == 'granted';
    try {
      final androidImpl = _plugin
          ?.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) return await androidImpl.areNotificationsEnabled() ?? false;
    } catch (_) {}
    return _plugin != null;
  }

  /// False when the browser has no Notification API (the in-app banner
  /// still works there).
  static bool get systemAlertsSupported => kIsWeb ? webAlertsSupported() : _plugin != null;

  /// Settings → "Send Test Alert". Ignores the saved preferences on purpose
  /// so the user can check the device itself.
  static Future<bool> sendTestAlert() async {
    final shown = await _notify(_testId, PyroAlertKind.test, 'PyroGuard test alert',
        'Notifications are working on this device.', route: '/settings', respectPreferences: false);
    _inApp(PyroAlertKind.test, 'Test alert', 'This is how PyroGuard alerts appear inside the app.', '/settings');
    return shown;
  }

  // ── WARNING → notifies only the app's own user, never BFP ─────────
  // A warning (smoke, flame or heat without a confirmed fire) is not a
  // confirmed emergency, so only the signed-in user/client gets it — in-app
  // notification, beep, SMS to their own phone, and the permanent log.
  // BFP is never contacted automatically; the saved contact is shown only for a deliberate user action.
  static DateTime? _lastWarningSoundAt;
  static String? _lastWarningText;
  /// Same warning text again within this time: in-app banner only, no beep,
  /// vibration, OS notification or SMS (stops repeated "random" beeping).
  static const Duration warningRepeatQuietPeriod = Duration(minutes: 5);

  static Future<void> triggerWarning(SensorReading r) async {
    final what = r.incidentType.trim().isEmpty || r.incidentType == 'Normal' ? 'Smoke Warning' : r.incidentType;
    final temp = r.hasTemperatureMeasurement ? ', ${r.temperature.toStringAsFixed(1)}°C' : '';
    final body = '$what$temp. No confirmed fire. Monitoring.';
    final now = DateTime.now();
    final repeat = _lastWarningSoundAt != null && _lastWarningText == what &&
        now.difference(_lastWarningSoundAt!) < warningRepeatQuietPeriod;
    _inApp(PyroAlertKind.warning, 'PyroGuard Warning', body, '/dashboard');
    if (repeat) return;
    _lastWarningSoundAt = now;
    _lastWarningText = what;
    unawaited(_log(r, 'WARNING'));
    await _notify(_warningId, PyroAlertKind.warning, 'PyroGuard Warning', body, route: '/dashboard');
    _pulseVibration(const [0, 300, 200, 300], const [0, 150, 0, 150], repeats: 3);
    await _playWarningBeep();
    final phone = _userPhone();
    if (phone != null && phone.isNotEmpty) {
      await _sendSms(phone, r, false);
    }
  }

  // ── CRITICAL → alarm + homeowner notification; BFP call is manual ─
  // Re-fires the OS notification every 20s while the alarm stays
  // active — a single notification is easy to swipe away by accident
  // and forget about while a real fire keeps burning; repeating it
  // (like an alarm clock does) is what actually makes it hard to miss.
  // A confirmed fire is a safety alert, so it is shown even if the user
  // turned general notifications off in Settings.
  static Future<void> triggerFireAlarm(SensorReading r) async {
    unawaited(_log(r, 'CRITICAL_FIRE'));
    const title = 'Fire Emergency';
    final body = 'Smoke: ${r.smokeLevel.toStringAsFixed(0)}% | Flame: CONFIRMED | EVACUATE NOW!';
    await _notify(_fireId, PyroAlertKind.fire, title, body,
        route: '/dashboard', respectPreferences: false);
    _sosVibration();       // no user approval needed — like NDRRMC
    await _playAlarm();
    final phone = _userPhone();
    if (phone != null && phone.isNotEmpty) {
      await _sendSms(phone, r, true, prefix: 'YOUR PYROGUARD: ');
    }
    // Do not auto-call or auto-message the BFP. The emergency overlay
    // displays the saved BFP contact and requires the user to tap CALL BFP.

    _reNotifyTimer?.cancel();
    _reNotifyTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _notify(_fireId, PyroAlertKind.fire, 'Fire Emergency — Still Active', body,
          route: '/dashboard', respectPreferences: false);
    });
  }

  // ── INTRUSION → door opened while the system is armed ─────────────
  // The controller records the event itself (event_history DOOR_OPEN), so
  // the app only alerts the homeowner here.
  static Future<void> triggerIntrusion(SensorReading r) async {
    const title = 'Intrusion Alert';
    final body = r.sirenActive
        ? 'The active piezo buzzer is ringing at ${r.deviceId}: the door was opened while armed. Disarm or silence it in the app.'
        : 'Door opened while the system is armed (${r.deviceId}). Disarm now or the active piezo buzzer will ring after the entry delay.';
    _inApp(PyroAlertKind.intrusion, title, body, '/camera');
    await _notify(_intrusionId, PyroAlertKind.intrusion, title, body, route: '/camera');
    _pulseVibration(const [0, 500, 150, 500, 150, 500], const [0, 255, 0, 255, 0, 255], repeats: 2);
    await _playWarningBeep();
  }

  // ── DOOR / WINDOW / ARM changes stored by the controllers ─────────
  // Raised by SecurityActivityService for each new event_history row.
  // [alarm] = opened while ARMED and protected (intrusion).
  static Future<void> notifyContactEvent(String title, String body, {bool alarm = false}) async {
    final kind = alarm ? PyroAlertKind.intrusion : PyroAlertKind.deviceStatus;
    _inApp(kind, title, body, '/device');
    await _notify(_contactEventId, kind, title, body, route: '/device');
    if (alarm) _pulseVibration(const [0, 400, 150, 400], const [0, 255, 0, 255]);
  }

  // ── CAMERA MOTION → camera frame analysis saw movement while armed ─
  // Raised by CameraMotionMonitor (rate-limited there). Uses the intrusion
  // channel because it is a security event, but no siren is started here.
  static Future<void> notifyCameraMotion(String cameraName, String coverage) async {
    const title = 'Motion detected';
    final body = '$cameraName ($coverage) detected movement while the system is armed. '
        'Open the camera to check the live view.';
    _inApp(PyroAlertKind.intrusion, title, body, '/camera');
    await _notify(_cameraMotionId, PyroAlertKind.intrusion, title, body, route: '/camera');
    _pulseVibration(const [0, 300, 120, 300], const [0, 200, 0, 200]);
  }

  // ── DEVICE STATUS → controller stopped / resumed reporting ────────
  static Future<void> notifyDeviceOffline(String deviceId, DateTime lastSeen) async {
    final body = '$deviceId stopped sending data (last seen '
        '${_clock(lastSeen)}). Alerts resume when it reconnects.';
    _inApp(PyroAlertKind.deviceStatus, 'Controller offline', body, '/device');
    await _notify(_deviceStatusId, PyroAlertKind.deviceStatus, 'Controller offline', body, route: '/device');
  }

  static Future<void> notifyDeviceOnline(String deviceId) async {
    final body = '$deviceId is reporting again. Live monitoring restored.';
    _inApp(PyroAlertKind.deviceStatus, 'Controller back online', body, '/dashboard');
    await _notify(_deviceStatusId, PyroAlertKind.deviceStatus, 'Controller back online', body, route: '/dashboard');
  }

  static String _clock(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  // ── Send welcome SMS on signup ────────────────────────────────────
  static Future<void> sendSignupSms(String phone, String name, String location) async {
    final msg = 'Welcome to PyroGuard, $name! Your fire detection system is now active at: $location. You will receive alerts here when fire or smoke is detected. ${bfpPhone.isNotEmpty
            ? 'For emergencies call your saved BFP contact: $bfpPhone.'
            : 'Add your local BFP contact in Settings for emergency calling.'}';
    final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  // ── Clearing alerts ───────────────────────────────────────────────
  /// Stops the fire siren, SOS vibration and repeating fire notification.
  static Future<void> stopFireAlarm() async {
    _reNotifyTimer?.cancel(); _reNotifyTimer = null;
    _vibTimer?.cancel(); _vibTimer = null;
    if (!kIsWeb) await Vibration.cancel();
    if (_alarmPlaying) { await _audio.stop(); _alarmPlaying = false; }
    alarmSoundBlocked = false;
    await _plugin?.cancel(_fireId);
  }

  static Future<void> clearWarning() async {
    await _plugin?.cancel(_warningId);
  }

  static Future<void> clearIntrusion() async {
    await _plugin?.cancel(_intrusionId);
  }

  /// Clears every hazard/security alert (used when the reading returns to
  /// normal, when the device goes offline, and by the manual reset).
  static Future<void> cancelAlarm() async {
    await stopFireAlarm();
    await clearWarning();
    await clearIntrusion();
  }

  // ── Vibration helpers ─────────────────────────────────────────────

  /// Short repeated pattern for warnings/intrusion; stops by itself.
  static void _pulseVibration(List<int> pattern, List<int> intensities, {int repeats = 1}) async {
    if (kIsWeb) return; // vibration API isn't meaningful/reliable on web
    if (_reNotifyTimer != null) return; // never interrupt an active fire SOS
    try {
      if ((await Vibration.hasVibrator()) != true) return;
      _vibTimer?.cancel();
      var left = repeats - 1;
      Vibration.vibrate(pattern: pattern, intensities: intensities);
      if (left <= 0) return;
      _vibTimer = Timer.periodic(const Duration(seconds: 4), (t) {
        Vibration.vibrate(pattern: pattern, intensities: intensities);
        if (--left <= 0) t.cancel();
      });
    } catch (e) {
      debugPrint('Vibration: $e');
    }
  }

  /// Red emergency: SOS pattern — fires even if phone is silent
  static void _sosVibration() async {
    if (kIsWeb) return;
    _vibTimer?.cancel();
    try {
      await Vibration.cancel();
      final has = (await Vibration.hasVibrator()) == true;
      if (!has) return;
      // SOS: . . .  — — —  . . .
      const pattern = [0,200,100,200,100,200, 400,600,400,600,400,600, 400,200,100,200,100,200];
      const intens  = [0,255,0,  255,0,  255, 0,  255,0,  255,0,  255, 0,  255,0,  255,0,  255];
      Vibration.vibrate(pattern: pattern, intensities: intens);
      _vibTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        Vibration.vibrate(pattern: pattern, intensities: intens);
      });
    } catch (e) {
      debugPrint('Vibration: $e');
    }
  }

  // ── Audio ─────────────────────────────────────────────────────────
  static final AudioPlayer _warnAudio = AudioPlayer();

  static Future<void> _playAlarm() async {
    if (_alarmPlaying) return;
    try {
      await _audio.setReleaseMode(ReleaseMode.loop);
      await _audio.setVolume(1.0);
      await _audio.play(AssetSource('sounds/fire_alarm.wav'));
      _alarmPlaying = true;
      alarmSoundBlocked = false;
    } catch (e) {
      debugPrint('Audio: $e');
      // Most likely the browser's autoplay policy blocked it because
      // this wasn't triggered by a user gesture. Leave _alarmPlaying
      // false and flag it so the UI can offer a one-tap retry, which
      // DOES count as a user gesture and will unblock playback.
      alarmSoundBlocked = true;
    }
  }

  /// Call this from a real button tap (e.g. the fire overlay's "enable
  /// sound" button) to retry playback after a browser blocked the
  /// automatic attempt above.
  static Future<void> retryAlarmSound() async {
    _alarmPlaying = false;
    await _playAlarm();
  }

  /// Short one-shot beep for a warning (dust/cooking smoke, no flame
  /// confirmed) — a separate player from the looping fire alarm so a
  /// warning beep never gets cut off by, or cuts off, an active
  /// emergency siren. Uses the same silent-autoplay-block detection as
  /// the fire alarm.
  static Future<void> _playWarningBeep() async {
    if (_alarmPlaying) return; // don't step on an active fire siren
    try {
      await _warnAudio.setReleaseMode(ReleaseMode.stop);
      await _warnAudio.setVolume(1.0);
      await _warnAudio.play(AssetSource('sounds/warning_beep.wav'));
    } catch (e) {
      debugPrint('Warning audio: $e');
      alarmSoundBlocked = true;
    }
  }

  // ── System notification (Android/iOS/web) ───────────────────────
  /// Returns true when a system notification was actually displayed.
  static Future<bool> _notify(int id, PyroAlertKind kind, String title, String body,
      {String route = '/dashboard', bool respectPreferences = true}) async {
    try {
      if (respectPreferences && !await _preferenceEnabled('push_notifications')) return false;
      final urgent = kind == PyroAlertKind.fire || kind == PyroAlertKind.intrusion;
      if (kIsWeb) {
        return webShowAlert(title: title, body: body, tag: 'pyroguard-$id', urgent: urgent);
      }
      final plugin = _plugin;
      if (plugin == null) return false;
      final channel = switch (kind) {
        PyroAlertKind.fire => _channels[0],
        PyroAlertKind.intrusion => _channels[1],
        PyroAlertKind.warning || PyroAlertKind.test => _channels[2],
        PyroAlertKind.deviceStatus => _channels[3],
      };
      final android = AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        importance: channel.importance,
        priority: urgent ? Priority.max : Priority.high,
        fullScreenIntent: kind == PyroAlertKind.fire,
        category: urgent ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.status,
        visibility: NotificationVisibility.public,
        color: switch (kind) {
          PyroAlertKind.fire => const Color(0xFFDC2626),
          PyroAlertKind.intrusion => const Color(0xFF7C3AED),
          PyroAlertKind.deviceStatus => const Color(0xFF2563EB),
          _ => const Color(0xFFEA580C),
        },
        styleInformation: BigTextStyleInformation(body),
        playSound: true,
        enableVibration: true,
        ticker: title,
      );
      final ios = DarwinNotificationDetails(
        presentAlert: true, presentBadge: true, presentSound: true,
        interruptionLevel: kind == PyroAlertKind.fire
            ? InterruptionLevel.critical
            : urgent ? InterruptionLevel.timeSensitive : InterruptionLevel.active,
      );
      await plugin.show(id, title, body, NotificationDetails(android: android, iOS: ios), payload: route);
      return true;
    } catch (e) {
      debugPrint('Device notification unavailable: $e');
      return false;
    }
  }

  // ── In-app banner ─────────────────────────────────────────────────
  // Shown on every platform while the app is open, so an alert is never
  // silent just because system notifications were refused. The fire
  // emergency has its own full-screen overlay in the dashboard shell.
  static void _inApp(PyroAlertKind kind, String title, String body, String route) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    final (color, icon) = switch (kind) {
      PyroAlertKind.fire => (const Color(0xFF991B1B), Icons.local_fire_department),
      PyroAlertKind.intrusion => (const Color(0xFF5B21B6), Icons.sensor_door_outlined),
      PyroAlertKind.deviceStatus => (const Color(0xFF1E3A8A), Icons.developer_board_outlined),
      PyroAlertKind.warning => (const Color(0xFF92400E), Icons.warning_amber),
      PyroAlertKind.test => (const Color(0xFF166534), Icons.notifications_active_outlined),
    };
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: kind == PyroAlertKind.intrusion ? 12 : 7),
      content: Row(children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 10),
        Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(body, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
        ])),
      ]),
      action: SnackBarAction(label: 'VIEW', textColor: Colors.white, onPressed: () => _openRoute(route)),
    ));
  }

  static Future<bool> _preferenceEnabled(String channel) async {
    final db = Supabase.instance.client;
    final uid = db.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final prefs = await db.from('user_preferences').select().eq('user_id', uid).maybeSingle();
      if (prefs == null) return channel == 'push_notifications';
      return prefs['notifications_enabled'] != false && prefs[channel] == true;
    } catch (e) {
      debugPrint('Notification preferences unavailable: $e');
      return channel == 'push_notifications';
    }
  }

  // ── SMS ───────────────────────────────────────────────────────────
  // If a photo/video URL is ever attached to the reading's incident
  // record (see _log below), it's included as a link — real SMS/MMS
  // gateways aside, a plain phone SMS composer can't embed an image
  // inline, so a tappable link is the honest version of "gets the
  // photo" through this path.
  static Future<void> _sendSms(String to, SensorReading r, bool emergency,
      {String prefix = '', String? photoUrl, bool respectPreferences = true}) async {
    try {
      if (respectPreferences && !await _preferenceEnabled('sms_alerts')) return;
      final u    = Supabase.instance.client.auth.currentUser;
      final loc  = u?.userMetadata?['location_text'] ?? 'Unknown';
      final name = u?.userMetadata?['full_name']      ?? 'PyroGuard User';
      // Prefer the device's OWN live GPS (if the GPS firmware phase is
      // enabled and has a fix) over the user's manually-set profile
      // location — the whole point of GPS hardware is that it's more
      // accurate and current than a location typed in once at signup.
      final lat  = r.deviceLat ?? u?.userMetadata?['latitude'];
      final lng  = r.deviceLng ?? u?.userMetadata?['longitude'];
      final gpsSource = r.deviceLat != null ? 'device GPS' : 'profile';

      final body = emergency
          ? '${prefix}FIRE EMERGENCY\n'
            'User: $name\nLocation: $loc\n'
            '${lat != null ? 'GPS ($gpsSource): $lat, $lng\n'
                            'Map: https://www.google.com/maps/search/?api=1&query=$lat,$lng\n' : ''}'
            'Smoke: ${r.smokeLevel.toStringAsFixed(0)}% | Temp: ${r.temperature.toStringAsFixed(1)}°C | Flame: YES\n'
            '${photoUrl != null ? 'Photo: $photoUrl\n' : ''}'
            'Device: ${r.deviceId} | ${DateTime.now().toLocal()}\nEVACUATE + CALL BFP!'
          : '${prefix}SMOKE ALERT\n'
            'User: $name\nLocation: $loc\n'
            'Smoke: ${r.smokeLevel.toStringAsFixed(0)}% | Temp: ${r.temperature.toStringAsFixed(1)}°C | No flame\n'
            'Device: ${r.deviceId} | ${DateTime.now().toLocal()}\nMonitoring...';

      final uri = Uri.parse('sms:$to?body=${Uri.encodeComponent(body)}');
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (e) { debugPrint('SMS: $e'); }
  }

  // ── Call BFP ─────────────────────────────────────────────────────
  /// Opens the phone dialer only after the user deliberately taps CALL BFP.
  /// The action is logged for traceability; PyroGuard does not claim that a
  /// station was automatically contacted or dispatched.
  static Future<bool> callBFP({SensorReading? reading, String? deviceIdOverride}) async {
    // Always load the canonical Settings/signup record before dialling.
    await loadBfpContact();
    final phone = bfpPhone.trim();
    if (phone.isEmpty || !bfpConfirmedByUser) return false;

    final uid = Supabase.instance.client.auth.currentUser?.id;
    final deviceId = deviceIdOverride ?? reading?.deviceId ??
        Supabase.instance.client.auth.currentUser?.userMetadata?['device_id']?.toString() ??
        'ESP32-001';
    final payload = <String, dynamic>{
      'device_id': deviceId,
      'event_type': 'CALL_BFP_TAPPED',
      'severity': 'EMERGENCY_ACTION',
      'message': 'User requested the dialer for the saved BFP contact; call completion is unverified.',
      'bfp_station': bfpStation ?? bfpName,
      'bfp_personnel': bfpPersonnel,
      'bfp_phone': phone,
      'user_id': uid,
      'occurred_at': DateTime.now().toUtc().toIso8601String(),
    };
    try {
      await Supabase.instance.client.from('emergency_action_logs').insert(payload);
      await DualSyncService.instance.writeMirror(
        recordType: 'emergency_action_logs',
        recordKey: '${deviceId}_${payload['occurred_at']}',
        payload: payload,
      );
    } catch (e) {
      debugPrint('Dual BFP action audit: $e');
    }
    try {
      await HistoricalService.instance.logEvent(payload);
    } catch (e) {
      debugPrint('MySQL BFP action audit: $e');
    }

    final normalized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri(scheme: 'tel', path: normalized);
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('BFP phone dialer unavailable: $e');
      return false;
    }
  }

  /// Optional manual SMS composer. It is intentionally never called
  /// automatically from fire detection.
  static Future<void> smsBFP(SensorReading? r) async {
    if (r == null || bfpSms.trim().isEmpty) return;
    await _sendSms(bfpSms, r, true, prefix: 'PYROGUARD EMERGENCY: ', respectPreferences: false);
  }

  // ── Dual-backend audit history ─────────────────────────────────────
  // Important incident/audit records are written to Supabase and mirrored
  // to MySQL after the local worker verifies the actual source records.
  static Future<void> _log(SensorReading r, String type, {String? photoUrl, String? videoUrl}) async {
    try {
      final u = Supabase.instance.client.auth.currentUser;
      await HistoricalService.instance.logIncident({
        'sensor_log_id': r.id,
        'user_id': u?.id,
        'device_id': r.deviceId,
        'alert_type': type,
        'event_type': type,
        'message': type == 'CRITICAL_FIRE' ? 'Confirmed flame/fire sensor alert' : 'Smoke/dust sensor warning',
        'created_at': r.createdAt.toUtc().toIso8601String(),
        'smoke_level': r.smokeLevel,
        'smoke_raw': r.smokeRaw,
        'flame_status': r.flameStatus,
        'temperature': r.temperature,
        'humidity': r.humidity,
        'severity_level': r.severityLevel,
        'location': r.location ?? u?.userMetadata?['location_text'],
        'latitude': r.deviceLat ?? u?.userMetadata?['latitude'],
        'longitude': r.deviceLng ?? u?.userMetadata?['longitude'],
        if (photoUrl != null) 'photo_url': photoUrl,
        if (videoUrl != null) 'video_url': videoUrl,
      });
    } catch (e) {
      debugPrint('MySQL incident log: $e');
    }
  }
}