import 'package:flutter/material.dart';
import '../config/coverage_config.dart';
import '../services/security_activity_service.dart';
import '../services/security_control_service.dart';
import '../theme.dart';

/// ARM / DISARM together with every door/window OPEN and CLOSE, for both
/// batches (two reed switches per ESP32):
///   Batch 1 · ESP32-001: Entrance door, Sala window
///   Batch 2 · ESP32-002: Fire exit door, Bedroom window
/// Every opening/closing shows whether the system was ARMED or DISARMED.
class DoorWindowActivityPanel extends StatefulWidget {
  const DoorWindowActivityPanel({super.key, this.limit = 12});
  final int limit;

  @override
  State<DoorWindowActivityPanel> createState() => _DoorWindowActivityPanelState();
}

class _DoorWindowActivityPanelState extends State<DoorWindowActivityPanel> {
  final _activity = SecurityActivityService.instance;
  final _security = SecurityControlService.instance;

  @override
  void initState() {
    super.initState();
    _activity.addListener(_changed);
    _security.addListener(_changed);
    _activity.start();
  }

  @override
  void dispose() {
    _activity.removeListener(_changed);
    _security.removeListener(_changed);
    _activity.stop();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _time(DateTime? dt) {
    if (dt == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.month)}/${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Widget _armChip(bool armed, {String? mode, bool small = false}) {
    final color = armed ? AppColors.red : AppColors.amber;
    final text = armed ? (mode != null && mode.startsWith('ARM_') ? mode.replaceAll('_', ' ') : 'ARMED') : 'DISARMED';
    return _chip(color, armed ? Icons.lock_rounded : Icons.lock_open_rounded, text, small);
  }

  Widget _chip(Color color, IconData icon, String text, bool small) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: .55)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: small ? 10 : 12, color: AppTheme.statusForeground(context, color)),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(
                color: AppTheme.statusForeground(context, color),
                fontSize: small ? 9 : 10,
                fontWeight: FontWeight.w900)),
      ]),
    );
  }

  Color _stateColor(String state, bool armedNow, bool protectedNow) => state == 'OPEN'
      ? (armedNow && protectedNow ? AppColors.red : AppColors.orange)
      : state == 'CLOSED'
          ? AppColors.green
          : AppColors.amber;

  /// Current arm state of one controller: its own latest ARMED/DISARMED
  /// confirmation. Until it has confirmed one, the home's confirmed mode.
  bool _deviceArmed(String deviceId) {
    final e = _activity.lastArmEvent(deviceId);
    return e != null ? e.type == 'ARMED' : _security.mode != SecurityMode.disarmed;
  }

  String? _deviceMode(String deviceId) {
    final e = _activity.lastArmEvent(deviceId);
    if (e != null) return e.armModeAtTime;
    return _security.mode == SecurityMode.armAway
        ? 'ARM_AWAY'
        : _security.mode == SecurityMode.armHome
            ? 'ARM_HOME'
            : null;
  }

  Widget _contactRow(String deviceId, String contact) {
    final st = _activity.contactState(deviceId, contact);
    final armedNow = _deviceArmed(deviceId);
    final protectedNow = contact == 'door' ? _security.doorEnabled : _security.windowEnabled;
    final color = _stateColor(st.state, armedNow, protectedNow);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(children: [
        Icon(contact == 'door' ? Icons.door_front_door_outlined : Icons.window_outlined,
            size: 20, color: AppTheme.statusForeground(context, color)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(CoverageConfig.contactLabel(deviceId, contact),
                style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800, fontSize: 12.5)),
            Text(
              st.at == null
                  ? (protectedNow ? 'Protected when armed' : 'Not protected')
                  : '${st.source == 'reed-switch' ? 'Updated' : 'Changed'} ${_time(st.at)}',
              style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5),
            ),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(st.state,
              style: TextStyle(
                  color: AppTheme.statusForeground(context, color),
                  fontWeight: FontWeight.w900,
                  fontSize: 13)),
          // The CURRENT arm state of this door/window's controller (it used to
          // show the state at the time of the last open/close, so it stayed
          // "DISARMED" after arming until the contact moved again).
          const SizedBox(height: 2),
          armedNow && !protectedNow
              // Armed, but this contact's protection switch is off.
              ? _chip(AppColors.amber, Icons.shield_outlined, 'NOT PROTECTED', true)
              : _armChip(armedNow, mode: _deviceMode(deviceId), small: true),
        ]),
      ]),
    );
  }

  Widget _batchCard(String deviceId) {
    final lastArm = _activity.lastArmEvent(deviceId);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card(context).withValues(alpha: .35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text('${CoverageConfig.batchName(deviceId)} • $deviceId',
                style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 12)),
          ),
          if (lastArm != null) _armChip(lastArm.type == 'ARMED', mode: lastArm.armModeAtTime, small: true),
        ]),
        Text(CoverageConfig.controllerCoverage(deviceId),
            style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5)),
        for (final contact in CoverageConfig.contactKeys) _contactRow(deviceId, contact),
      ]),
    );
  }

  Widget _eventRow(SecurityEvent e) {
    final (IconData icon, Color color) = e.isArmChange
        ? (e.type == 'ARMED'
            ? (Icons.lock_rounded, AppColors.red)
            : (Icons.lock_open_rounded, AppColors.amber))
        : e.isOpen
            ? (e.contact == 'door' ? Icons.door_front_door_rounded : Icons.window_rounded,
                e.intrusion ? AppColors.red : AppColors.orange)
            : (e.contact == 'door' ? Icons.door_front_door_outlined : Icons.window_outlined,
                AppColors.green);
    final title = e.isArmChange
        ? (e.type == 'ARMED' ? 'System ARMED' : 'System DISARMED')
        : '${e.label} ${e.isOpen ? 'OPENED' : 'CLOSED'}${e.intrusion ? ' • INTRUSION' : ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: .30)),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: AppTheme.statusForeground(context, color)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 12.5, fontWeight: FontWeight.w700)),
            Text('${_time(e.createdAt)}  •  ${e.batch} (${e.deviceId})',
                style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 10.5)),
          ]),
        ),
        _armChip(e.armedAtTime, mode: e.armModeAtTime, small: true),
        const SizedBox(width: 6),
        Text(e.mysqlSynced ? 'MySQL ✓' : 'MySQL …',
            style: TextStyle(
                color: AppTheme.statusForeground(context, e.mysqlSynced ? AppColors.green : AppColors.amber),
                fontSize: 10,
                fontWeight: FontWeight.w800)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final armed = _security.mode != SecurityMode.disarmed;
    // Either controller can confirm the home's arm state (both receive every
    // ARM/DISARM command); use the most recent confirmation.
    SecurityEvent? lastArm;
    for (final id in CoverageConfig.controllers) {
      final e = _activity.lastArmEvent(id);
      if (e == null) continue;
      final a = e.createdAt, b = lastArm?.createdAt;
      if (lastArm == null || (a != null && (b == null || a.isAfter(b)))) lastArm = e;
    }
    final confirmed = lastArm != null && (lastArm.type == 'ARMED') == armed;
    final dark = AppTheme.isDark(context);
    final rows = _activity.events.take(widget.limit).toList();

    return GlassPanel(
      radius: 22,
      blur: 18,
      borderColor: AppColors.orange.withValues(alpha: .26),
      tint: dark ? AppColors.darkCard.withValues(alpha: .66) : AppColors.lightCard.withValues(alpha: .68),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.sensor_door_outlined, color: AppTheme.brandForeground(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Text('DOOR & WINDOW ACTIVITY',
                style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w900, fontSize: 13)),
          ),
          _armChip(armed, mode: armed ? (_security.mode == SecurityMode.armAway ? 'ARM_AWAY' : 'ARM_HOME') : null),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _activity.refresh,
            icon: Icon(Icons.refresh_rounded, color: AppTheme.brandForeground(context)),
          ),
        ]),
        Text(
          lastArm == null
              ? 'Waiting for an ESP32 to confirm the arm state.'
              : confirmed
                  ? 'Arm state confirmed by ${lastArm.deviceId} at ${_time(lastArm.createdAt)}.'
                  : 'Arm change sent • each ESP32 applies it within about 2 s of connecting.',
          style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth > 620;
          final cards = [for (final id in CoverageConfig.controllers) _batchCard(id)];
          return wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 10),
                  Expanded(child: cards[1]),
                ])
              : Column(children: [cards[0], const SizedBox(height: 10), cards[1]]);
        }),
        const SizedBox(height: 12),
        Text('Openings, closings and arm changes',
            style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        if (_activity.loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(color: AppColors.orange)),
          )
        else if (_activity.error != null)
          Text(_activity.error!, style: TextStyle(color: AppTheme.warningForeground(context), fontSize: 12))
        else if (rows.isEmpty)
          Text('Nothing recorded yet. Open or close a door/window, or arm/disarm the system.',
              style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12))
        else
          for (final e in rows) _eventRow(e),
      ]),
    );
  }
}
