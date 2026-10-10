import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'sensor_service.dart';
import 'historical_service.dart';
import 'dual_sync_service.dart';

class NotificationService {
  static FlutterLocalNotificationsPlugin? _plugin;
  static final AudioPlayer _audio = AudioPlayer();
  static bool _alarmPlaying = false;
  static Timer? _vibTimer;
  static Timer? _reNotifyTimer;

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
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final row = await Supabase.instance.client
          .from('emergency_contacts')
          .select()
          .eq('user_id', uid)
          .eq('is_primary', true)
          .maybeSingle();
      if (row != null) {
        bfpPhone = (row['phone'] as String?)?.trim() ?? '';
        bfpSms   = bfpPhone;
        bfpStation = (row['station_name'] ?? row['name'])?.toString();
        bfpName = bfpStation;
        bfpPersonnel = row['personnel_name']?.toString();
        bfpRank = row['rank_position']?.toString();
        bfpAddress = row['address']?.toString();
        bfpConfirmedByUser = (row['is_confirmed'] as bool?) ?? bfpPhone.isNotEmpty;
      }
    } catch (e) {
      debugPrint('loadBfpContact: $e');
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
  static Future<void> initialize(FlutterLocalNotificationsPlugin plugin) async {
    _plugin = plugin;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await plugin.initialize(const InitializationSettings(android: android, iOS: ios));
    await requestPermission();
  }

  /// Explicitly re-asks for notification permission — called once at
  /// startup, and also exposed here so Settings can offer a visible
  /// "Enable Notifications" action for anyone who dismissed the system
  /// prompt the first time and wants to grant it now.
  static Future<void> requestPermission() async {
    if (kIsWeb) return; // flutter_local_notifications has no web implementation
    // iOS/macOS permission is already requested inline by
    // DarwinInitializationSettings during initialize() above (which
    // already ran once by the time this is ever called again from
    // Settings) — Android is the only platform with a separate,
    // explicitly re-callable permission request.
    await _plugin
        ?.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  // ── WARNING → notifies only the app's own user, never BFP ─────────
  // A warning (smoke/dust, no confirmed flame) is not a confirmed
  // emergency, so only the signed-in user/client gets it — in-app
  // notification, beep, SMS to their own phone, and the permanent log.
  // BFP is never contacted automatically; the saved contact is shown only for a deliberate user action.
  static Future<void> triggerWarning(SensorReading r) async {
    await _notify(0, 'PyroGuard Warning', 'Smoke/Dust: ${r.smokeLevel.toStringAsFixed(0)}% — No flame. Monitoring.', false);
    _yellowVibration();
    await _playWarningBeep();
    final phone = _userPhone();
    if (phone != null && phone.isNotEmpty) {
      await _sendSms(phone, r, false);
    }
    await _log(r, 'WARNING');
  }

  // ── CRITICAL → alarm + homeowner notification; BFP call is manual ─
  // Re-fires the OS notification every 20s while the alarm stays
  // active — a single notification is easy to swipe away by accident
  // and forget about while a real fire keeps burning; repeating it
  // (like an alarm clock does) is what actually makes it hard to miss.
  static Future<void> triggerFireAlarm(SensorReading r) async {
    await _notify(1, 'Fire Emergency',
        'Smoke: ${r.smokeLevel.toStringAsFixed(0)}% | Flame: CONFIRMED | EVACUATE NOW!', true);
    _sosVibration();       // no user approval needed — like NDRRMC
    await _playAlarm();
    final phone = _userPhone();
    if (phone != null && phone.isNotEmpty) {
      await _sendSms(phone, r, true, prefix: 'YOUR PYROGUARD: ');
    }
    // Do not auto-call or auto-message the BFP. The emergency overlay
    // displays the saved BFP contact and requires the user to tap CALL BFP.
    await _log(r, 'CRITICAL_FIRE');

    _reNotifyTimer?.cancel();
    _reNotifyTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _notify(1, 'Fire Emergency — Still Active',
          'Smoke: ${r.smokeLevel.toStringAsFixed(0)}% | Flame: CONFIRMED | EVACUATE NOW!', true);
    });
  }

  // ── Send welcome SMS on signup ────────────────────────────────────
  static Future<void> sendSignupSms(String phone, String name, String location) async {
    final msg = 'Welcome to PyroGuard, $name! '
        'Your fire detection system is now active at: $location. '
        'You will receive alerts here when fire or smoke is detected. ' +
        (bfpPhone.isNotEmpty
            ? 'For emergencies call your saved BFP contact: $bfpPhone.'
            : 'Add your local BFP contact in Settings for emergency calling.');
    final uri = Uri.parse('sms:$phone?body=${Uri.encodeComponent(msg)}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  // ── Vibration helpers ─────────────────────────────────────────────

  /// Yellow warning: 2 short pulses, repeating
  static void _yellowVibration() async {
    if (kIsWeb) return; // vibration API isn't meaningful/reliable on web
    _vibTimer?.cancel();
    await Vibration.cancel();
    final has = (await Vibration.hasVibrator()) == true;
    if (!has) return;
    _vibTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      Vibration.vibrate(pattern: [0, 300, 200, 300], intensities: [0, 150, 0, 150]);
    });
    Vibration.vibrate(pattern: [0, 300, 200, 300], intensities: [0, 150, 0, 150]);
  }

  /// Red emergency: SOS pattern — fires even if phone is silent
  static void _sosVibration() async {
    if (kIsWeb) return;
    _vibTimer?.cancel();
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
  }

  static Future<void> cancelAlarm() async {
    _vibTimer?.cancel(); _vibTimer = null;
    _reNotifyTimer?.cancel(); _reNotifyTimer = null;
    if (!kIsWeb) await Vibration.cancel();
    if (_alarmPlaying) { await _audio.stop(); _alarmPlaying = false; }
    alarmSoundBlocked = false;
    await _plugin?.cancel(0);
    await _plugin?.cancel(1);
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

  // ── Push notification ─────────────────────────────────────────────
  static Future<void> _notify(int id, String title, String body, bool emergency) async {
    final android = AndroidNotificationDetails(
      emergency ? 'pyroguard_fire' : 'pyroguard_warn',
      emergency ? 'Fire Alerts' : 'Warnings',
      importance: emergency ? Importance.max : Importance.high,
      priority:   emergency ? Priority.max   : Priority.high,
      fullScreenIntent: emergency,
      category: emergency ? AndroidNotificationCategory.alarm : AndroidNotificationCategory.reminder,
      visibility: NotificationVisibility.public,
      color: emergency ? const Color(0xFFDC2626) : const Color(0xFFEA580C),
      playSound: true,
      enableVibration: true,
    );
    const ios = DarwinNotificationDetails(
      presentAlert: true, presentBadge: true, presentSound: true,
      interruptionLevel: InterruptionLevel.critical,
    );
    await _plugin?.show(id, title, body, NotificationDetails(android: android, iOS: ios));
  }

  // ── SMS ───────────────────────────────────────────────────────────
  // If a photo/video URL is ever attached to the reading's incident
  // record (see _log below), it's included as a link — real SMS/MMS
  // gateways aside, a plain phone SMS composer can't embed an image
  // inline, so a tappable link is the honest version of "gets the
  // photo" through this path.
  static Future<void> _sendSms(String to, SensorReading r, bool emergency,
      {String prefix = '', String? photoUrl}) async {
    try {
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
  static Future<bool> callBFP({SensorReading? reading}) async {
    final phone = bfpPhone.trim();
    if (phone.isEmpty) return false;

    final uid = Supabase.instance.client.auth.currentUser?.id;
    final deviceId = reading?.deviceId ??
        Supabase.instance.client.auth.currentUser?.userMetadata?['device_id']?.toString() ??
        'ESP32-001';
    final payload = <String, dynamic>{
      'device_id': deviceId,
      'event_type': 'CALL_BFP_TAPPED',
      'severity': 'EMERGENCY_ACTION',
      'message': 'User opened the dialer for the saved BFP contact.',
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

    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      return true;
    }
    return false;
  }

  /// Optional manual SMS composer. It is intentionally never called
  /// automatically from fire detection.
  static Future<void> smsBFP(SensorReading? r) async {
    if (r == null || bfpSms.trim().isEmpty) return;
    await _sendSms(bfpSms, r, true, prefix: 'PYROGUARD EMERGENCY: ');
  }

  // ── Dual-backend audit history ─────────────────────────────────────
  // Important incident/audit records are written to Supabase and mirrored
  // immediately to MySQL through the secure Edge Function.
  static Future<void> _log(SensorReading r, String type, {String? photoUrl, String? videoUrl}) async {
    try {
      final u = Supabase.instance.client.auth.currentUser;
      await HistoricalService.instance.logIncident({
        'sensor_log_id': r.id,
        'user_id': u?.id,
        'device_id': r.deviceId,
        'alert_type': type,
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