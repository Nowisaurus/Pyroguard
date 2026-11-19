import 'dart:async';
import 'package:flutter/material.dart';
import 'camera_overlay_style.dart';
import '../services/camera_one_ptz_service.dart';
import '../config/coverage_config.dart';
import '../theme.dart';

/// Transparent pan/tilt overlay drawn ON TOP of the live camera view.
///
/// * Camera 1: AUTO-FOLLOW is performed by the hardware (Camera 1 detects
///   motion, ESP32-001 moves the servos). The pill turns it on/off.
///   Manual buttons go to Camera 1 over the local Wi-Fi, which relays them to
///   ESP32-001; any manual move pauses auto-follow for 20 s.
///   Tap = one 10° step, press and hold = keep moving, release = stop there.
///   Delivered commands are stored in Supabase `ptz_commands`.
/// PyroGuard has a single camera (Camera 1 with two-way audio); the panel
/// shows nothing for any other device id.
class PtzControlPanel extends StatefulWidget {
  const PtzControlPanel({
    super.key,
    required this.cameraDeviceId,
    this.cameraIp = '',
    this.dialSize = 112,
    this.leading,
    this.trailing,
  });

  final String cameraDeviceId;

  /// Camera 1 LAN address (the same one that serves the live video).
  final String cameraIp;

  /// Diameter of the transparent direction pad (compact by default).
  final double dialSize;

  /// Optional controls shown left/right of the pad (e.g. ZM and CH).
  final Widget? leading;
  final Widget? trailing;

  @override
  State<PtzControlPanel> createState() => _PtzControlPanelState();
}

class _PtzControlPanelState extends State<PtzControlPanel> {
  CameraOnePtzService? _one; // Camera 1
  final bool _busy = false;
  String? _message;
  Timer? _repeat;
  String? _heldAction;

  bool get _first => widget.cameraDeviceId == CoverageConfig.cameraOne;

  @override
  void initState() {
    super.initState();
    _createServices();
  }

  void _createServices() {
    if (!_first) return; // only Camera 1 has pan/tilt
    _one = CameraOnePtzService(widget.cameraIp)
      ..addListener(_onUpdate)
      ..start();
  }

  void _disposeServices() {
    _repeat?.cancel();
    _repeat = null;
    _heldAction = null;
    _one?.removeListener(_onUpdate);
    _one?.dispose();
    _one = null;
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PtzControlPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameraDeviceId != widget.cameraDeviceId) {
      _disposeServices();
      _message = null;
      _createServices();
    } else if (oldWidget.cameraIp != widget.cameraIp) {
      _one?.updateCameraIp(widget.cameraIp);
    }
  }

  @override
  void dispose() {
    _disposeServices();
    super.dispose();
  }

  // ---------------- Camera 1 (direct LAN) ----------------

  Future<void> _jog(String action, {bool record = true}) async {
    final one = _one;
    if (one == null || one.sending) return;
    await one.command(action, record: record);
  }

  void _holdStart(String action) {
    _heldAction = action;
    _repeat?.cancel();
    _jog(action); // the hold is stored once
    _repeat = Timer.periodic(const Duration(milliseconds: 350), (_) {
      if (_heldAction == action) _jog(action, record: false);
    });
  }

  void _holdEnd() {
    if (_heldAction == null) return;
    _heldAction = null;
    _repeat?.cancel();
    _repeat = null;
    _one?.stopAfterCurrent();
  }

  // ---------------- UI ----------------

  static const _shadow = CameraOverlayStyle.shadow;

  Widget _glass({required Widget child, Color? border, EdgeInsets? padding}) =>
      Container(
        padding: padding ??
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: CameraOverlayStyle.glass(.38),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: border ?? CameraOverlayStyle.hairline(.18)),
        ),
        child: child,
      );

  Widget _arrow({
    required IconData icon,
    required String tooltip,
    required bool active,
    VoidCallback? onPressed,
    String? holdAction,
  }) {
    final size = widget.dialSize * .27;
    final button = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: active ? onPressed : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon,
              size: size * .72,
              shadows: _shadow,
              color: active ? CameraOverlayStyle.foreground : CameraOverlayStyle.disabled()),
        ),
      ),
    );
    final holdable = holdAction != null;
    return Tooltip(
      message: tooltip,
      triggerMode:
          holdable ? TooltipTriggerMode.manual : TooltipTriggerMode.longPress,
      child: holdable
          ? GestureDetector(
              onLongPressStart: active ? (_) => _holdStart(holdAction) : null,
              onLongPressEnd: (_) => _holdEnd(),
              onLongPressCancel: _holdEnd,
              child: button,
            )
          : button,
    );
  }

  Widget _dial(bool enabled) {
    final first = _first;
    final d = widget.dialSize;
    final home = d * .34;
    return SizedBox(
      width: d,
      height: d,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Transparent so the live video stays visible underneath.
          color: CameraOverlayStyle.glass(.18),
          border: Border.all(
              color: AppColors.orange.withValues(alpha: enabled ? .85 : .30),
              width: 1.6),
          boxShadow: [
            BoxShadow(
                color: AppColors.orange.withValues(alpha: enabled ? .25 : 0),
                blurRadius: 14),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 2,
              child: _arrow(
                icon: Icons.keyboard_arrow_up_rounded,
                tooltip: first ? 'Tilt up (hold to keep moving)' : 'Tilt not installed',
                active: first && enabled,
                onPressed: first ? () => _jog('up') : null,
                holdAction: first ? 'up' : null,
              ),
            ),
            Positioned(
              bottom: 2,
              child: _arrow(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: first ? 'Tilt down (hold to keep moving)' : 'Tilt not installed',
                active: first && enabled,
                onPressed: first ? () => _jog('down') : null,
                holdAction: first ? 'down' : null,
              ),
            ),
            Positioned(
              left: 2,
              child: _arrow(
                icon: Icons.keyboard_arrow_left_rounded,
                tooltip: first ? 'Pan left (hold to keep moving)' : 'Pan left',
                active: enabled,
                onPressed: first ? () => _jog('left') : null,
                holdAction: first ? 'left' : null,
              ),
            ),
            Positioned(
              right: 2,
              child: _arrow(
                icon: Icons.keyboard_arrow_right_rounded,
                tooltip: first ? 'Pan right (hold to keep moving)' : 'Pan right',
                active: enabled,
                onPressed: first ? () => _jog('right') : null,
                holdAction: first ? 'right' : null,
              ),
            ),
            Tooltip(
              message: 'Return to center',
              child: Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: Ink(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: CameraOverlayStyle.brandGradient,
                    border: Border.all(color: AppColors.orange.withValues(alpha: enabled ? .9 : .3)),
                  ),
                  child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: enabled
                      ? (first ? () => _jog('center') : null)
                      : null,
                  child: SizedBox(
                    width: home,
                    height: home,
                    child: (_busy || (_one?.sending ?? false))
                        ? Padding(
                            padding: EdgeInsets.all(home * .3),
                            child: const CircularProgressIndicator(
                                strokeWidth: 2, color: CameraOverlayStyle.foreground),
                          )
                        : Icon(Icons.home_rounded,
                            size: home * .5,
                            color: enabled ? CameraOverlayStyle.foreground : CameraOverlayStyle.disabled(),
                            shadows: _shadow),
                  ),
                ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ({String text, Color color}) _status() {
    final one = _one;
    if (_first && one != null) {
      if (one.viaCloud) {
        final pos = one.pan != null && one.tilt != null
            ? ' ${one.pan}°/${one.tilt}°'
            : '';
        return (text: 'PTZ via cloud$pos', color: CameraOverlayStyle.live);
      }
      if (!one.validIp) return (text: 'Camera IP not set', color: AppColors.amber);
      if (!one.cameraReachable) return (text: 'Camera offline', color: AppColors.amber);
      if (!one.firmwareSupportsPtz) {
        return (text: 'Update Camera 1 sketch', color: AppColors.amber);
      }
      if (!one.controllerLinked) {
        return (text: 'Waiting for ESP32-001', color: AppColors.amber);
      }
      final pos = one.pan != null && one.tilt != null
          ? ' ${one.pan}°/${one.tilt}°'
          : '';
      return (text: 'PTZ$pos', color: CameraOverlayStyle.live);
    }
    return (text: 'Camera 1 unavailable', color: AppColors.amber);
  }

  Widget _autoFollowPill(CameraOnePtzService one) {
    final on = one.autoFollow;
    final paused = on && one.autoPaused;
    final color = !on
        ? CameraOverlayStyle.secondary
        : paused
            ? AppColors.amber
            : CameraOverlayStyle.live;
    final label = !on
        ? 'AUTO OFF'
        : paused
            ? 'AUTO PAUSED'
            : 'AUTO-FOLLOW';
    return Tooltip(
      message: on
          ? 'ESP32-001 turns the camera toward motion. Tap to switch off.'
          : 'Tap to let ESP32-001 follow motion automatically.',
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: one.ready && !one.sending ? () => one.setAutoFollow(!on) : null,
        child: _glass(
          border: color.withValues(alpha: .55),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.track_changes_rounded, size: 12, color: color, shadows: _shadow),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                    shadows: _shadow)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_first) return const SizedBox.shrink(); // only Camera 1 has PTZ
    final first = _first;
    final one = _one;
    final enabled = one?.ready ?? false;
    final status = _status();
    final note = first ? one?.message : _message;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 12)],
            _dial(enabled),
            if (widget.trailing != null) ...[const SizedBox(width: 12), widget.trailing!],
          ],
        ),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          _glass(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.circle, size: 7, color: status.color),
              const SizedBox(width: 5),
              Text(status.text,
                  style: TextStyle(
                      color: CameraOverlayStyle.hairline(.9),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      shadows: _shadow)),
            ]),
          ),
          if (first && one != null) ...[
            const SizedBox(width: 6),
            _autoFollowPill(one),
          ],
        ]),
        if (note != null) ...[
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.dialSize + 160),
            child: Text(note,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.amber, fontSize: 10, shadows: _shadow)),
          ),
        ],
      ],
    );
  }
}
