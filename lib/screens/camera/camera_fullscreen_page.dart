import 'package:flutter/material.dart';
import '../../widgets/pg_notice.dart';
import '../../widgets/camera_overlay_style.dart';
import 'package:flutter/services.dart';
import '../../config/camera_network_config.dart';
import '../../config/coverage_config.dart';
import '../../services/camera_actions_controller.dart';
import '../../services/camera_motion_service.dart';
import '../../services/mjpeg_live_feed.dart';
import '../../theme.dart';
import '../../widgets/camera_controls_overlay.dart';
import '../../widgets/mjpeg_frame_view.dart';

/// Full-screen live view for Camera 1 (two-way audio) with compact, transparent
/// controls over the video (Mute, Record, Speak, Call BFP, ZM, PTZ, CH,
/// Snapshot). Tap the picture to hide/show the controls. Uses the same
/// shared stream as the other camera screens.
class CameraFullscreenPage extends StatefulWidget {
  const CameraFullscreenPage({
    super.key,
    required this.cameraDeviceId,
    required this.cameraIp,
  });

  final String cameraDeviceId;
  final String cameraIp;

  @override
  State<CameraFullscreenPage> createState() => _CameraFullscreenPageState();
}

class _CameraFullscreenPageState extends State<CameraFullscreenPage> {
  late final MjpegLiveFeed _live;
  late final CameraMotionMonitor _motion;
  late final CameraActionsController _actions;
  bool _motionAttached = false;
  bool _showControls = true;
  bool _wasLive = false;

  bool get _validIp => CameraNetworkConfig.validIpv4(widget.cameraIp);
  bool get _first => widget.cameraDeviceId == CoverageConfig.cameraOne;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _live = MjpegFeedHub.instance
        .acquire(widget.cameraDeviceId, _validIp ? [widget.cameraIp] : []);
    _live.addListener(_liveChanged);
    _motion = CameraMotionMonitor.forCamera(widget.cameraDeviceId)
      ..addListener(_motionChanged);
    if (_validIp) {
      _motion.attach(widget.cameraIp);
      _motionAttached = true;
    }
    _actions = CameraActionsController(
      cameraId: widget.cameraDeviceId,
      feed: _live,
    )..addListener(_actionsChanged);
  }

  // Rebuild only when the stream goes live/drops, never once per frame
  // (MjpegFrameView paints the frames itself).
  void _liveChanged() {
    if (!mounted || _live.connected == _wasLive) return;
    setState(() => _wasLive = _live.connected);
  }

  void _motionChanged() {
    if (mounted) setState(() {});
  }

  void _actionsChanged() {
    if (!mounted) return;
    final text = _actions.message;
    if (text != null) {
      final error = _actions.messageIsError;
      _actions.clearMessage();
      if (!error) { setState(() {}); return; } // success shows in the UI itself
      PgNotice.show(text, kind: PgNoticeKind.error);
    }
    setState(() {});
  }


  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _actions.removeListener(_actionsChanged);
    _actions.dispose();
    _live.removeListener(_liveChanged);
    MjpegFeedHub.instance.release(widget.cameraDeviceId, _live);
    _motion.removeListener(_motionChanged);
    if (_motionAttached) _motion.detach();
    super.dispose();
  }

  Widget _pill(Widget child) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: CameraOverlayStyle.glass(.45),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: CameraOverlayStyle.hairline(.15)),
        ),
        child: child,
      );

  Widget _roundIcon(IconData icon, String tooltip, VoidCallback? onPressed) =>
      Tooltip(
        message: tooltip,
        child: Material(
          color: CameraOverlayStyle.glass(.45),
          shape: const CircleBorder(),
          child: IconButton(
            icon: Icon(icon, color: onPressed == null ? CameraOverlayStyle.disabled() : CameraOverlayStyle.foreground),
            onPressed: onPressed,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = _motion.state;
    final motionNow = state?.motionNow ?? false;
    final name = _first ? 'Camera 1' : 'Unknown camera';
    return Scaffold(
      backgroundColor: CameraOverlayStyle.videoBackground,
      body: LayoutBuilder(builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showControls = !_showControls),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRect(
                child: AnimatedScale(
                  scale: _actions.zoom,
                  duration: const Duration(milliseconds: 180),
                  child: MjpegFrameView(
                    feed: _live,
                    fit: BoxFit.contain,
                    placeholder: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                            MjpegLiveFeed.localBlocked
                                ? MjpegLiveFeed.localBlockedMessage
                                : 'Connecting to live video…',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: CameraOverlayStyle.secondary)),
                      ),
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Stack(
                  children: [
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _pill(Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.circle,
                                size: 10,
                                color: _live.connected
                                    ? CameraOverlayStyle.live
                                    : AppColors.orange),
                            const SizedBox(width: 8),
                            Text(
                              '${_live.connected ? 'LIVE' : MjpegLiveFeed.localBlocked ? 'WEB VIEW' : 'CONNECTING'}  •  $name  •  '
                              '${CoverageConfig.cameraCoverage(widget.cameraDeviceId)}',
                              style: const TextStyle(
                                  color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700),
                            ),
                          ])),
                          const SizedBox(height: 8),
                          if (state != null)
                            _pill(Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(
                                  motionNow
                                      ? Icons.directions_run_rounded
                                      : Icons.motion_photos_on_outlined,
                                  size: 15,
                                  color: motionNow
                                      ? CameraOverlayStyle.alert
                                      : CameraOverlayStyle.secondary),
                              const SizedBox(width: 6),
                              Text(state.label,
                                  style: TextStyle(
                                      color: motionNow
                                          ? CameraOverlayStyle.alert
                                          : CameraOverlayStyle.secondary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12)),
                            ])),
                          if (_actions.recording) ...[
                            const SizedBox(height: 8),
                            _pill(Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.fiber_manual_record,
                                  size: 12, color: CameraOverlayStyle.alert),
                              const SizedBox(width: 6),
                              Text('REC ${_actions.recordedFrames} frames',
                                  style: const TextStyle(
                                      color: CameraOverlayStyle.foreground,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12)),
                            ])),
                          ],
                        ],
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Column(children: [
                        _roundIcon(Icons.fullscreen_exit_rounded, 'Exit full screen',
                            () => Navigator.of(context).maybePop()),
                        const SizedBox(height: 8),
                        _roundIcon(Icons.refresh_rounded, 'Reconnect live video',
                            () => _live.reconnect()),
                        const SizedBox(height: 8),
                        _roundIcon(Icons.photo_camera_rounded, 'Snapshot to Evidence',
                            _actions.snapshotBusy ? null : _actions.snapshot),
                      ]),
                    ),
                    // Compact, transparent controls over the video. Kept
                    // mounted while hidden so the controller link stays live.
                    Positioned(
                      left: 12,
                      right: 12,
                      top: constraints.maxHeight * 0.38,
                      bottom: 14,
                      child: IgnorePointer(
                        ignoring: !_showControls,
                        child: AnimatedOpacity(
                          opacity: _showControls ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: CameraControlsOverlay(
                                actions: _actions,
                                cameraIp: _validIp ? widget.cameraIp : '',
                                dialSize: 124,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
