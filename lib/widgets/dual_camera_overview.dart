import 'dart:async';
import '../config/camera_endpoint.dart';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'camera_overlay_style.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../config/camera_network_config.dart';
import '../config/pyroguard_config.dart';
import '../services/camera_telemetry_service.dart';
import '../config/coverage_config.dart';
import '../services/camera_motion_service.dart';
import '../services/mjpeg_live_feed.dart';
import '../screens/camera/camera_fullscreen_page.dart';
import 'mjpeg_frame_view.dart';

/// Camera slots are always displayed, even without an enrolled device or internet.
/// This dashboard is intentionally a launcher/overview only; detailed controls
/// are shown inside each camera's own screen to avoid redundant PTZ widgets.
class DualCameraOverview extends StatefulWidget {
  const DualCameraOverview({super.key, this.showHeader = true});

  /// When false, the "Live Camera" heading is drawn by the parent screen
  /// (wide layout) so the camera card and side panels start at the same level.
  final bool showHeader;
  @override
  State<DualCameraOverview> createState() => _DualCameraOverviewState();
}

class _DualCameraOverviewState extends State<DualCameraOverview> {
  static const _ids = ['pyroguard_camera_001']; // single camera: Camera 1 (two-way audio)
  Timer? _timer;
  final Map<String, Map<String, dynamic>> _registered = {};
  final Map<String, String> _workingVideoIps = {};
  String? _registryError;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    CameraNetworkConfig.instance.addListener(_localAddressChanged);
    CameraTelemetryService.instance.addListener(_localAddressChanged);
    CameraNetworkConfig.instance.load();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    CameraNetworkConfig.instance.removeListener(_localAddressChanged);
    CameraTelemetryService.instance.removeListener(_localAddressChanged);
    super.dispose();
  }

  void _localAddressChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) {
        if (mounted) {
          setState(() {
            _registryError = 'Sign in to connect your cameras.';
          });
        }
        return;
      }
      final rows = await client
          .from('pyroguard_camera_registry')
          .select(
              'device_id,display_name,model,ip_address,enabled,last_seen_at,ptz_enabled,audio_enabled')
          .inFilter('device_id', _ids);
      if (!mounted) return;
      setState(() {
        _registered.clear();
        for (final row in rows) {
          _registered[row['device_id'].toString()] = Map<String, dynamic>.from(row);
        }
        _registryError = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _registryError = e is PostgrestException && e.code == 'PGRST205'
              ? 'Database setup incomplete: apply the camera registry migration in Supabase.'
              : 'Camera registry could not load. Check your connection and device enrollment.';
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  bool _online(Map<String, dynamic>? d) {
    if (d == null || d['enabled'] != true) return false;
    final seen = DateTime.tryParse('${d['last_seen_at'] ?? ''}')?.toUtc();
    if (seen == null) return false;
    final age = DateTime.now().toUtc().difference(seen);
    return !age.isNegative && age < const Duration(seconds: 90);
  }

  Widget _cameraCard(int index, double width) {
    final id = _ids[index];
    final item = _registered[id];
    final alive = _online(item);
    final label = 'Camera ${index + 1}';
    final coverage = CoverageConfig.cameraCoverage(id);
    final batch = CoverageConfig.cameraBatch(id);
    const model = 'DFR1154 ESP32-S3';
    const motor = 'Pan/tilt • auto-follow';
    const audio = 'Two-way audio';
    final registeredIp = (item?['ip_address'] ?? '').toString();
    const fallbackIp = PyroGuardConfig.cameraFallbackIp;
    // A saved address wins. Use a FRESH camera-1 telemetry address before an
    // old or missing registry address.
    final cameraOneTelemetry = CameraTelemetryService.instance.latest;
    final freshTelemetryIp = index == 0 && cameraOneTelemetry != null &&
        cameraOneTelemetry.cameraDeviceId == id &&
        cameraOneTelemetry.isFresh &&
        CameraNetworkConfig.validIpv4(cameraOneTelemetry.cameraIp)
        ? cameraOneTelemetry.cameraIp : '';
    // Try only camera-specific recorded addresses, never borrow the other
    // camera's address. The old hard-coded fallback is the final candidate.
    final savedIp = CameraNetworkConfig.instance.resolve(id, '');
    final candidates = <String>[];
    for (final candidate in [savedIp, freshTelemetryIp, registeredIp, fallbackIp]) {
      if (CameraNetworkConfig.validIpv4(candidate) && !candidates.contains(candidate)) {
        candidates.add(candidate);
      }
    }
    final cameraIp = _workingVideoIps[id] ??
        (candidates.isNotEmpty ? candidates.first : '');
    // Preview availability is determined by the physical /capture endpoint,
    // not by optional Supabase registry enrollment or stale cloud heartbeat.

    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        // One tap opens the camera straight in full screen (root navigator,
        // so it covers the whole window, sidebar included).
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => CameraFullscreenPage(
              cameraDeviceId: id,
              cameraIp: cameraIp,
            ),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.darkCard,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: AppColors.orange.withValues(alpha: .5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.videocam_outlined, color: AppColors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$label • $coverage',
                      style: const TextStyle(
                        color: CameraOverlayStyle.foreground,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh camera registry',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, color: AppColors.orange),
                  ),
                ],
              ),
              Text(
                '$batch  •  $model  •  $motor',
                style: const TextStyle(color: CameraOverlayStyle.secondary, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 10,
                  child: _CameraLivePreview(
                    key: ValueKey('preview-$id-${candidates.join(",")}'),
                    index: index,
                    cameraId: id,
                    ips: candidates,
                    onFrame: (ip) {
                      if (_workingVideoIps[id] == ip || !mounted) return;
                      setState(() => _workingVideoIps[id] = ip);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _chip(Icons.memory_rounded, motor),
                  _chip(Icons.volume_up_outlined, audio),
                  _chip(Icons.network_ping_outlined, item == null ? 'Cloud registry pending' : (alive ? 'Cloud heartbeat fresh' : 'Cloud heartbeat stale')), 
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: CameraOverlayStyle.hairline(.05),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: CameraOverlayStyle.hairline(.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppColors.orange),
            const SizedBox(width: 6),
            Text(text, style: const TextStyle(color: CameraOverlayStyle.secondary, fontSize: 12)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showHeader) ...[
            LiveCameraHeader(onRefresh: _refresh),
            const SizedBox(height: 12),
          ],
          // Stacked layout: warning above the card. Side-by-side layout:
          // warning below it, so the card stays level with the right column.
          if (_registryError != null && widget.showHeader)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_registryError!, style: const TextStyle(color: AppColors.amber)),
            ),
          LayoutBuilder(builder: (context, c) {
            // One camera: full width on phones, capped on wide screens.
            // Beside the side panels (no header) the card fills its column.
            final cardWidth = (!widget.showHeader || c.maxWidth < 900) ? c.maxWidth : 860.0;
            return Wrap(spacing: 14, runSpacing: 14, children: [_cameraCard(0, cardWidth)]);
          }),
          if (_registryError != null && !widget.showHeader)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_registryError!, style: const TextStyle(color: AppColors.amber)),
            ),
        ],
      );
}

/// "Live Camera" heading + coverage note. Shared by the overview (stacked
/// layout) and the camera tab (wide layout, drawn above both columns).
class LiveCameraHeader extends StatelessWidget {
  const LiveCameraHeader({super.key, this.onRefresh});
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.grid_view_rounded, color: AppColors.orange),
              const SizedBox(width: 9),
              const Expanded(child: Text('Live Camera', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700))),
              if (onRefresh != null)
                IconButton(tooltip: 'Refresh camera', onPressed: onRefresh, icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Camera 1 covers Entrance & Sala (ESP32-001). Kitchen & Bedroom are covered by the ESP32-002 sensors. Tap the camera for live video, motion status, two-way audio and pan/tilt.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      );
}

class InternetAddressPattern {
  static bool valid(String value) {
    final parts = value.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255 && p == n.toString();
    });
  }
}

/// Polls each camera's own /capture endpoint for a near-live preview.
/// It does not depend on the Supabase registry, which may be missing or stale.
/// The detail page and overview can independently reach the same physical camera.
class _CameraLivePreview extends StatefulWidget {
  const _CameraLivePreview({super.key, required this.index, required this.cameraId, required this.ips, required this.onFrame});
  final int index;
  final String cameraId;
  final List<String> ips;
  final ValueChanged<String> onFrame;

  @override
  State<_CameraLivePreview> createState() => _CameraLivePreviewState();
}

class _CameraLivePreviewState extends State<_CameraLivePreview> {
  Timer? _timer;
  late final MjpegLiveFeed _live;
  late final CameraMotionMonitor _motion;
  bool _motionAttached = false;
  Uint8List? _frame; // /capture snapshot, used only while the stream is down
  bool _busy = false;
  bool _online = false;
  String? _message;
  int _requestGeneration = 0;
  int _consecutiveFailures = 0;
  DateTime? _nextAttempt;
  String? _activeIp;

  @override
  void initState() {
    super.initState();
    // Shared with the camera detail screen (one ESP32 stream per camera).
    _live = MjpegFeedHub.instance.acquire(widget.cameraId, widget.ips);
    _live.addListener(_liveChanged);
    _online = _live.connected;
    _motion = CameraMotionMonitor.forCamera(widget.cameraId)
      ..addListener(_motionChanged);
    if (widget.ips.isNotEmpty) {
      _motion.attach(widget.ips.first);
      _motionAttached = true;
    }
    _start();
  }

  // Only rebuild when the stream goes live/drops or changes address; the
  // video itself is painted by MjpegFrameView without rebuilding this card.
  void _liveChanged() {
    if (!mounted) return;
    final ip = _live.activeIp;
    if (_live.connected && ip != null) {
      widget.onFrame(ip);
      _motion.setIp(ip);
    }
    final online = _live.connected || _frame != null;
    if (online != _online || (_live.connected && _activeIp != ip)) {
      setState(() {
        _online = online;
        if (_live.connected) {
          _activeIp = ip;
          _message = null;
          _frame = null;
        }
      });
    }
  }

  void _motionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant _CameraLivePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ips.join(',') != widget.ips.join(',')) {
      _live.updateAddresses(widget.ips);
      _timer?.cancel();
      _requestGeneration++;
      _busy = false;
      _frame = null;
      _online = false;
      _activeIp = null;
      _consecutiveFailures = 0;
      _nextAttempt = null;
      _start();
    }
  }

  void _start() {
    // Snapshots remain a compatibility fallback for cameras without MJPEG.
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_live.connected) _fetch();
    });
  }

  Future<void> _fetch({bool force = false}) async {
    if (_live.connected) return;
    if (_busy || !mounted) return;
    if (!force && _nextAttempt != null && DateTime.now().isBefore(_nextAttempt!)) return;
    if (widget.ips.isEmpty) {
      setState(() {
        _online = false;
        _frame = null;
        _message = 'Camera ${widget.index + 1} has no registered or saved LAN address.';
      });
      return;
    }
    _busy = true;
    final generation = _requestGeneration;
    try {
      // Prefer the last reachable address; check other *known* addresses if
      // this camera moved to a new DHCP lease.
      final addresses = <String>[
        if (_activeIp != null && widget.ips.contains(_activeIp)) _activeIp!,
        ...widget.ips.where((ip) => ip != _activeIp),
      ];
      Object? lastError;
      Uint8List? jpeg;
      String? goodIp;
      for (final ip in addresses) {
        try {
          final response = await http.get(CameraEndpoint.url(
            widget.cameraId, ip, '/capture',
            query: {'v': '${DateTime.now().millisecondsSinceEpoch}'},
          )).timeout(const Duration(seconds: 4));
          final bytes = response.bodyBytes;
          if (response.statusCode != 200 || bytes.length < 4 ||
              bytes[0] != 0xFF || bytes[1] != 0xD8 ||
              bytes[bytes.length - 2] != 0xFF || bytes.last != 0xD9) {
            throw StateError('HTTP ${response.statusCode} or invalid JPEG from $ip');
          }
          jpeg = bytes;
          goodIp = ip;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (jpeg == null || goodIp == null) {
        throw StateError('All known camera addresses failed: $lastError');
      }
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _activeIp = goodIp;
        _frame = jpeg;
        _online = true;
        _message = null;
        _consecutiveFailures = 0;
        _nextAttempt = null;
      });
      widget.onFrame(goodIp);
    } catch (e) {
      if (!mounted || generation != _requestGeneration) return;
      _consecutiveFailures++;
      final seconds = (_consecutiveFailures * 3).clamp(3, 30);
      _nextAttempt = DateTime.now().add(Duration(seconds: seconds));
      setState(() {
        _online = false;
        _frame = null; // Never show a stale image as a live feed.
        _message = 'Video unavailable from known addresses ${widget.ips.join(', ')}: $e. Confirm the camera HTTP server is running and the correct IP is registered.';
      });
    } finally {
      if (generation == _requestGeneration) _busy = false;
    }
  }

  @override
  void dispose() {
    _requestGeneration++;
    _timer?.cancel();
    _live.removeListener(_liveChanged);
    MjpegFeedHub.instance.release(widget.cameraId, _live);
    _motion.removeListener(_motionChanged);
    if (_motionAttached) _motion.detach();
    super.dispose();
  }

  Widget _motionBadge() {
    final state = _motion.state;
    if (state == null || !state.reachable) return const SizedBox.shrink();
    final active = state.motionNow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (active ? AppColors.redDeep : CameraOverlayStyle.videoBackground).withValues(alpha: active ? .92 : .55),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: CameraOverlayStyle.hairline(.12)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(active ? Icons.directions_run_rounded : Icons.motion_photos_on_outlined,
            color: CameraOverlayStyle.foreground, size: 14),
        const SizedBox(width: 5),
        Text(active ? 'MOTION' : (state.enabled && state.fresh ? 'No motion' : state.label),
            style: const TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700, fontSize: 11)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    // Narrow previews (small phones): shorter message, icon-only "Open" pill.
    final narrow = box.maxWidth < 380;
    return ColoredBox(
    color: AppColors.black,
    child: Stack(fit: StackFit.expand, children: [
      MjpegFrameView(
        feed: _live,
        fallback: _frame,
        fit: BoxFit.cover,
        placeholder: Center(child: Padding(
          padding: const EdgeInsets.all(16),
          // Shrinks to fit short previews (phones / landscape) — never overflows.
          child: FittedBox(fit: BoxFit.scaleDown, child: SizedBox(
            width: (box.maxWidth - 32).clamp(220.0, 2000.0).toDouble(),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_off_outlined, color: CameraOverlayStyle.secondary, size: 44),
            const SizedBox(height: 8),
            Text('Camera ${widget.index + 1} • No video',
              style: const TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(_message ?? 'Connecting to ${widget.ips.join(', ')}…',
              maxLines: narrow ? 2 : 4, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: const TextStyle(color: CameraOverlayStyle.secondary, fontSize: 11)),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: _busy ? null : () => _fetch(force: true),
              icon: const Icon(Icons.refresh_rounded, color: AppColors.orange, size: 17),
              label: const Text('Retry video', style: TextStyle(color: CameraOverlayStyle.foreground)),
            ),
          ]),
          )),
        )),
      ),
      Positioned(top: 12, left: 12, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (_online ? AppColors.green.withValues(alpha: .35) : AppColors.maroon.withValues(alpha: .85)),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: CameraOverlayStyle.hairline(.12)),
        ),
        child: Text(_live.connected ? 'VIDEO LIVE' : (_online ? 'SNAPSHOT' : 'NO VIDEO'),
          style: const TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700, fontSize: 11)),
      )),
      Positioned(top: 12, right: 12, child: _motionBadge()),
      Positioned(
        bottom: 10,
        right: 10,
        child: Material(
          color: CameraOverlayStyle.glass(.5),
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: 'Full screen with pan/tilt controls',
            icon: const Icon(Icons.fullscreen_rounded, color: CameraOverlayStyle.foreground),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => CameraFullscreenPage(
                cameraDeviceId: widget.cameraId,
                cameraIp: _live.activeIp ??
                    (widget.ips.isNotEmpty ? widget.ips.first : ''),
              ),
            )),
          ),
        ),
      ),
      Positioned(right: 64, bottom: 17, child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: CameraOverlayStyle.glass(.60),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: CameraOverlayStyle.hairline(.12)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.open_in_full_rounded, color: CameraOverlayStyle.foreground, size: 16),
          if (!narrow) ...const [
            SizedBox(width: 6),
            Text('Open camera', style: TextStyle(color: CameraOverlayStyle.foreground, fontWeight: FontWeight.w700)),
          ],
        ]),
      )),
    ]),
  );
  });
}
