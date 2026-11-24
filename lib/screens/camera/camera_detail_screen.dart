import 'dart:async';
import '../../config/camera_endpoint.dart';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../widgets/pg_notice.dart';
import '../../widgets/camera_overlay_style.dart';
import 'package:http/http.dart' as http;
import '../../services/camera_audio_service.dart';
import '../../config/camera_network_config.dart';
import '../../services/camera_service.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/mjpeg_live_feed.dart';
import '../../services/camera_motion_service.dart';
import '../../config/coverage_config.dart';
import '../../theme.dart';
import '../../responsive.dart';
import '../../widgets/mjpeg_frame_view.dart';
import '../../services/camera_actions_controller.dart';
import '../../widgets/camera_controls_overlay.dart';
import 'camera_fullscreen_page.dart';

/// Dedicated camera screen. Never falls back to the other camera's IP or controller.
/// Camera interaction lives on this page so the overview can stay clean and non-redundant.
class CameraDetailScreen extends StatefulWidget {
  const CameraDetailScreen({super.key, required this.cameraDeviceId, required this.cameraIp});
  final String cameraDeviceId;
  final String cameraIp;

  @override
  State<CameraDetailScreen> createState() => _CameraDetailScreenState();
}

class _CameraDetailScreenState extends State<CameraDetailScreen> {
  Timer? _timer;
  late final MjpegLiveFeed _live;
  int _consecutiveFrameFailures = 0;
  DateTime? _nextFrameAttempt;
  Uint8List? _frame;
  bool _loading = false;
  bool _cameraBusy = false;
  bool _cameraEnabled = true;
  bool _cameraReachable = false;
  bool _streamLive = false;
  bool _autoListenAttempted = false;
  late final CameraMotionMonitor _motion;
  bool _motionAttached = false;
  late final CameraActionsController _actions;
  String? _error;

  bool get _first => widget.cameraDeviceId == CoverageConfig.cameraOne;
  String get _name => _first ? 'Camera 1' : 'Unknown camera';
  String get _model => 'DFR1154';
  String get _coverage => CoverageConfig.cameraCoverage(widget.cameraDeviceId);
  // The overview supplies the address that actually returned a JPEG.
  // Do not replace it with a possibly stale local override on navigation.
  String get _ip => CameraNetworkConfig.validIpv4(widget.cameraIp)
      ? widget.cameraIp
      : CameraNetworkConfig.instance.resolve(
          widget.cameraDeviceId,
          _first ? CameraTelemetryService.instance.cameraIp : '',
        );
  bool get _validIp {
    final parts = _ip.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final v = int.tryParse(p);
      return v != null && v >= 0 && v <= 255;
    });
  }
  // Camera 1 (DFR1154) is the only camera and has two-way audio.
  CameraAudioService get _audio => CameraAudioService.instance;
  bool get _audioConfigured => _first;

  @override
  void initState() {
    super.initState();
    // Shared with the overview card: the ESP32 serves one stream at a time.
    _live = MjpegFeedHub.instance
        .acquire(widget.cameraDeviceId, _validIp ? [_ip] : []);
    _live.addListener(_liveChanged);
    _streamLive = _live.connected;
    _cameraReachable = _live.connected;
    _motion = CameraMotionMonitor.forCamera(widget.cameraDeviceId)
      ..addListener(_motionChanged);
    if (_validIp) {
      _motion.attach(_ip);
      _motionAttached = true;
    }
    _actions = CameraActionsController(
      cameraId: widget.cameraDeviceId,
      feed: _live,
    )..addListener(_actionsChanged);
    if (_first) _audio.addListener(_audioChanged);
    CameraNetworkConfig.instance.addListener(_audioChanged);
    CameraNetworkConfig.instance.load().then((_) {
      if (mounted) _refresh();
    });
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_cameraEnabled && !_live.connected) _refresh();
    });
  }

  // Frames are painted by MjpegFrameView; this screen only rebuilds when
  // the stream goes live or drops, never once per video frame.
  void _liveChanged() {
    if (!mounted || !_cameraEnabled) return;
    final live = _live.connected;
    if (live == _streamLive) return;
    setState(() {
      _streamLive = live;
      if (live) {
        _cameraReachable = true;
        _error = null;
        _frame = null; // drop the still snapshot; live video takes over
      }
    });
    if (!live) _refresh(force: true); // snapshot fallback while reconnecting
  }

  // Buttons on the overlay report results here (saved, errors, ...).
  void _actionsChanged() {
    if (!mounted) return;
    final text = _actions.message;
    if (text != null) {
      final error = _actions.messageIsError;
      _actions.clearMessage();
      if (!error) { setState(() {}); return; } // success shows in the UI itself
      PgNotice.show(text, kind: PgNoticeKind.error);
    }
    setState(() {}); // zoom / recording indicator
  }


  void _motionChanged() {
    if (mounted) setState(() {});
  }

  void _audioChanged() {
    if (_validIp) {
      _live.updateAddresses([_ip]);
      if (_motionAttached) {
        _motion.setIp(_ip);
      } else {
        _motion.attach(_ip);
        _motionAttached = true;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _startListen() async {
    if (!_audioConfigured) {
      if (mounted) setState(() => _error = 'Audio ESP32 IP is not configured for this camera.');
      return;
    }
    if (_first && !_validIp) {
      if (mounted) setState(() => _error = 'Camera 1 requires a valid camera/audio IP address.');
      return;
    }
    try {
      // A listening session runs until stopped; do not await it on the UI thread.
      unawaited(_audio.startListening().catchError((Object e) {
        if (mounted) setState(() => _error = 'Audio stream unavailable: $e');
      }));
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Listening unavailable: $e');
    }
  }

  Future<void> _refresh({bool force = false}) async {
    if (MjpegLiveFeed.localBlocked) {
      // HTTPS website: the browser blocks http://<camera>/capture.
      if (mounted && _error != MjpegLiveFeed.localBlockedMessage) {
        setState(() { _frame = null; _error = MjpegLiveFeed.localBlockedMessage; });
      }
      return;
    }
    if (_live.connected && _cameraEnabled) return;
    if (_loading || !_cameraEnabled) return;
    if (!force && _nextFrameAttempt != null && DateTime.now().isBefore(_nextFrameAttempt!)) return;
    if (!_validIp) {
      if (mounted) setState(() { _frame = null; _cameraReachable = false; _error = 'No valid $_name IP configured. Check device provisioning / registry.'; });
      return;
    }
    _loading = true;
    try {
      final response = await http
          .get(
            CameraEndpoint.url(
              widget.cameraDeviceId, _ip, '/capture',
              query: {'v': DateTime.now().millisecondsSinceEpoch.toString()},
            ),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw StateError('HTTP ${response.statusCode} from /capture');
      }
      if (response.bodyBytes.length < 4 || response.bodyBytes[0] != 0xFF || response.bodyBytes[1] != 0xD8) {
        throw const FormatException('Invalid JPEG frame returned by camera');
      }
      if (_audioConfigured && !_autoListenAttempted) {
        _autoListenAttempted = true;
        unawaited(_startListen());
      }
      if (mounted) {
        if (_live.connected) return;
        setState(() {
          _frame = response.bodyBytes;
          _cameraReachable = true;
          _error = null;
          _consecutiveFrameFailures = 0;
          _nextFrameAttempt = null;
        });
      }
    } catch (e) {
      _consecutiveFrameFailures++;
      final retrySeconds = (_consecutiveFrameFailures * 3).clamp(3, 30);
      _nextFrameAttempt = DateTime.now().add(Duration(seconds: retrySeconds));
      if (mounted) {
        if (_live.connected) return;
        setState(() {
          _cameraReachable = false;
          _frame = null;
          _error = '$_name video unavailable at http://$_ip/capture: $e. Check Wi-Fi connection and browser access.';
        });
      }
    } finally {
      _loading = false;
    }
  }

  Future<void> _toggleCamera() async {
    if (_cameraBusy || !_validIp) return;
    setState(() => _cameraBusy = true);
    final next = !_cameraEnabled;
    try {
      final ok = _first
          ? await CameraService.instance.setCameraEnabled(next)
          : (await http
                      .post(CameraEndpoint.url(widget.cameraDeviceId, _ip, next ? '/api/camera/on' : '/api/camera/off'))
                      .timeout(const Duration(seconds: 4)))
                  .statusCode ==
              200;
      if (!ok) throw StateError('Camera rejected request');
      if (mounted) {
        setState(() {
          _cameraEnabled = next;
          _error = null;
          if (!next) {
            _live.stop();
            _streamLive = false;
            _frame = null;
            _cameraReachable = false;
          }
        });
      }
      if (next) {
        _live.start();
        await _refresh();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera control failed');
    } finally {
      if (mounted) setState(() => _cameraBusy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _actions.removeListener(_actionsChanged);
    _actions.dispose();
    _live.removeListener(_liveChanged);
    MjpegFeedHub.instance.release(widget.cameraDeviceId, _live);
    _motion.removeListener(_motionChanged);
    if (_motionAttached) _motion.detach();
    CameraNetworkConfig.instance.removeListener(_audioChanged);
    if (_first) {
      _audio.removeListener(_audioChanged);
      _audio.stopListening();
      _audio.stopPushToTalk();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$_name • $_coverage', maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              '$_model • ${CoverageConfig.cameraBatch(widget.cameraDeviceId)}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          Responsive.horizontalPadding(context), 16,
          Responsive.horizontalPadding(context), 24,
        ),
        // Centered and capped on large monitors so the video never stretches
        // edge to edge; full width on phones and tablets.
        child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _cameraCard(),
            const SizedBox(height: 12),
            Text(
              _first
                  ? _audio.status
                  : 'Unknown camera. PyroGuard uses Camera 1 (DFR1154, two-way audio) only.',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              SelectableText(_error!, style: TextStyle(color: AppTheme.isDark(context) ? AppColors.amber : AppColors.orangeDeep)),
            ],
          ],
        ),
        )),
      ),
    );
  }

  void _openFullscreen() {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CameraFullscreenPage(
        cameraDeviceId: widget.cameraDeviceId,
        cameraIp: _validIp ? _ip : '',
      ),
    ));
  }

  Widget _cameraCard() {
    return LayoutBuilder(builder: (context, constraints) {
      // The live view (with its transparent PTZ overlay) fills the screen
      // height instead of a fixed 16:10 box that pushed controls off-screen.
      final screenH = MediaQuery.sizeOf(context).height;
      final height = (constraints.maxWidth * 10 / 16)
          .clamp(260.0, (screenH - 190).clamp(260.0, 2000.0))
          .toDouble();
      return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.orange.withValues(alpha: .45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: AnimatedScale(
                scale: _actions.zoom,
                duration: const Duration(milliseconds: 180),
                child: MjpegFrameView(
              feed: _cameraEnabled ? _live : null,
              fallback: _cameraEnabled ? _frame : null,
              fit: BoxFit.contain,
              placeholder: const ColoredBox(
                color: AppColors.black,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.videocam_off_outlined, color: CameraOverlayStyle.secondary, size: 56),
                      SizedBox(height: 10),
                      Text('Camera preview unavailable', style: TextStyle(color: CameraOverlayStyle.secondary)),
                    ],
                  ),
                ),
              ),
                ),
              ),
            ),
            Positioned(
              top: 14,
              left: 14,
              child: _glassPill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 10, color: _cameraReachable ? CameraOverlayStyle.live : AppColors.orange),
                    const SizedBox(width: 8),
                    Text(
                      _streamLive ? 'LIVE' : (_cameraReachable ? 'ONLINE • SNAPSHOT' : 'OFFLINE'),
                      style: const TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 58,
              left: 14,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _motionPill(),
                  if (_actions.recording) ...[
                    const SizedBox(height: 8),
                    _glassPill(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.fiber_manual_record, size: 12, color: CameraOverlayStyle.alert),
                        const SizedBox(width: 6),
                        Text('REC ${_actions.recordedFrames} frames',
                            style: const TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700, fontSize: 12)),
                      ]),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              top: 14,
              right: 14,
              child: Column(
                children: [
                  if (_first) ...[
                    // Camera on/off is a Camera 1 firmware command.
                    _overlayIconButton(
                      icon: _cameraEnabled ? Icons.videocam : Icons.videocam_off,
                      tooltip: _cameraEnabled ? 'Turn camera off' : 'Turn camera on',
                      onPressed: _cameraBusy ? null : _toggleCamera,
                    ),
                    const SizedBox(height: 8),
                  ],
                  _overlayIconButton(
                    icon: Icons.refresh,
                    tooltip: 'Reconnect live video',
                    onPressed: () {
                      _live.reconnect();
                      _refresh(force: true);
                    },
                  ),
                  const SizedBox(height: 8),
                  _overlayIconButton(
                    icon: Icons.fullscreen_rounded,
                    tooltip: 'Full screen',
                    onPressed: _openFullscreen,
                  ),
                  const SizedBox(height: 8),
                  _overlayIconButton(
                    icon: Icons.photo_camera_rounded,
                    tooltip: 'Snapshot to Evidence',
                    onPressed: _actions.snapshotBusy ? null : _actions.snapshot,
                  ),
                ],
              ),
            ),
            // Compact, transparent controls ON the live video.
            Positioned(
              left: 8,
              right: 64,
              top: height * 0.34,
              bottom: 10,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: CameraControlsOverlay(
                    actions: _actions,
                    cameraIp: _validIp ? _ip : '',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    });
  }

  Widget _motionPill() {
    final state = _motion.state;
    if (!_first && (state == null || !state.reachable)) return const SizedBox.shrink();
    final active = state?.motionNow ?? false;
    final color = state == null || !state.reachable
        ? CameraOverlayStyle.secondary
        : active
            ? CameraOverlayStyle.alert
            : (state.enabled && state.fresh ? CameraOverlayStyle.live : AppColors.amber);
    return _glassPill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(active ? Icons.directions_run_rounded : Icons.motion_photos_on_outlined,
              size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            state?.label ?? 'Checking motion…',
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _glassPill({required Widget child}) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: CameraOverlayStyle.glass(.26),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: CameraOverlayStyle.hairline(.12)),
            ),
            child: child,
          ),
        ),
      );

  Widget _overlayIconButton({required IconData icon, required String tooltip, required VoidCallback? onPressed}) => Tooltip(
        message: tooltip,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Material(
              color: CameraOverlayStyle.glass(.26),
              child: IconButton(
                onPressed: onPressed,
                icon: Icon(icon, color: CameraOverlayStyle.foreground),
              ),
            ),
          ),
        ),
      );
}
