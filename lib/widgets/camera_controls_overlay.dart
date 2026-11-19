import 'package:flutter/material.dart';
import 'camera_overlay_style.dart';
import '../services/camera_actions_controller.dart';
import '../theme.dart';
import 'ptz_control_panel.dart';

/// Compact, transparent camera controls drawn over the live video.
///
/// Camera 1 (two-way audio, the only PyroGuard camera):
/// Listen/Mute, Record, Speak, Call BFP, ZM and the PTZ pad.
/// Every button is wired to [CameraActionsController] or the PTZ services.
class CameraControlsOverlay extends StatelessWidget {
  const CameraControlsOverlay({
    super.key,
    required this.actions,
    required this.cameraIp,
    this.dialSize = 112,
  });

  final CameraActionsController actions;
  final String cameraIp;

  final double dialSize;

  static const _shadow = CameraOverlayStyle.shadow;

  Widget _label(String text, {Color color = CameraOverlayStyle.foreground}) => Text(
        text,
        style: TextStyle(
            color: color, fontSize: 10.5, fontWeight: FontWeight.w600, shadows: _shadow),
      );

  Widget _circle({
    required IconData icon,
    required String label,
    required String tooltip,
    VoidCallback? onTap,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    VoidCallback? onTapCancel,
    Color? fill,
    Color iconColor = CameraOverlayStyle.foreground,
    bool busy = false,
  }) {
    const size = 46.0;
    final circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill ?? CameraOverlayStyle.glass(.35),
        border: Border.all(color: CameraOverlayStyle.hairline(.22)),
      ),
      child: busy
          ? const Padding(
              padding: EdgeInsets.all(13),
              child: CircularProgressIndicator(strokeWidth: 2, color: CameraOverlayStyle.foreground),
            )
          : Icon(icon, size: 21, color: iconColor, shadows: _shadow),
    );
    return Tooltip(
      message: tooltip,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          child: circle,
        ),
        const SizedBox(height: 4),
        _label(label),
      ]),
    );
  }

  Widget _verticalPill({
    required String label,
    required IconData upIcon,
    required IconData downIcon,
    required String upTooltip,
    required String downTooltip,
    required VoidCallback? onUp,
    required VoidCallback? onDown,
  }) {
    Widget button(IconData icon, String tip, VoidCallback? onTap) => Tooltip(
          message: tip,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 36,
              height: 32,
              child: Icon(icon,
                  size: 20,
                  color: onTap == null ? CameraOverlayStyle.disabled() : CameraOverlayStyle.foreground,
                  shadows: _shadow),
            ),
          ),
        );
    return Container(
      width: 38,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: CameraOverlayStyle.glass(.30),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: CameraOverlayStyle.hairline(.18)),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          button(upIcon, upTooltip, onUp),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _label(label),
          ),
          button(downIcon, downTooltip, onDown),
        ]),
      ),
    );
  }

  String _recLabel() {
    final s = actions.recordElapsed.inSeconds;
    return 'REC ${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([actions, actions.audio]),
      builder: (context, _) {
        final listening = actions.listening;
        final talking = actions.talking;
        final zoomText = actions.zoom == 1.0
            ? 'ZM'
            : '${actions.zoom.toStringAsFixed(1)}x';
        final zoomPill = _verticalPill(
          label: zoomText,
          upIcon: Icons.add_rounded,
          downIcon: Icons.remove_rounded,
          upTooltip: 'Zoom in (digital)',
          downTooltip: 'Zoom out',
          onUp: actions.zoom < CameraActionsController.maxZoom ? actions.zoomIn : null,
          onDown: actions.zoom > CameraActionsController.minZoom ? actions.zoomOut : null,
        );
        final recordButton = _circle(
          icon: actions.recording ? Icons.stop_rounded : Icons.fiber_manual_record_rounded,
          label: actions.recording ? _recLabel() : 'Record',
          tooltip: actions.recording
              ? 'Stop and save the evidence recording'
              : 'Record evidence frames (1 per second, up to 60 s)',
          onTap: actions.toggleRecord,
          iconColor: actions.recording ? CameraOverlayStyle.foreground : CameraOverlayStyle.alert,
          fill: actions.recording ? CameraOverlayStyle.emergency : null,
        );
        final bfpButton = _circle(
          icon: Icons.call_rounded,
          label: 'Call BFP',
          tooltip: 'Call the saved BFP fire station',
          onTap: actions.callBfp,
          fill: CameraOverlayStyle.emergency.withValues(alpha: .92),
        );

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _circle(
                  icon: listening ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                  label: listening ? 'Mute' : 'Listen',
                  tooltip: listening
                      ? 'Mute the camera microphone audio'
                      : 'Listen to the camera microphone',
                  onTap: actions.audioBusy ? null : actions.toggleListen,
                  busy: actions.audioBusy,
                  fill: listening ? AppColors.orange.withValues(alpha: .55) : null,
                ),
                const SizedBox(width: 14),
                recordButton,
                const SizedBox(width: 14),
                _circle(
                  icon: talking ? Icons.mic_rounded : Icons.mic_none_rounded,
                  label: talking ? 'Talking' : 'Speak',
                  tooltip: 'Hold to talk through the camera speaker',
                  onTapDown: (_) => actions.talkStart(),
                  onTapUp: (_) => actions.talkStop(),
                  onTapCancel: actions.talkStop,
                  fill: talking ? AppColors.orange.withValues(alpha: .7) : null,
                ),
                const SizedBox(width: 14),
                bfpButton,
              ],
            ),
            const SizedBox(height: 10),
            PtzControlPanel(
              key: ValueKey(actions.cameraId),
              cameraDeviceId: actions.cameraId,
              cameraIp: cameraIp,
              dialSize: dialSize,
              leading: zoomPill,
            ),
          ],
        );
      },
    );
  }
}
