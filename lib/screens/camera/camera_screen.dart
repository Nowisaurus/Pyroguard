import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/camera_audio_service.dart';
import '../../services/camera_service.dart';
import '../../services/camera_telemetry_service.dart';
import '../../services/historical_service.dart';
import '../../theme.dart';
import '../../responsive.dart';

class CameraTab extends StatefulWidget {
  const CameraTab({super.key});

  @override
  State<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends State<CameraTab> {
  final camera = CameraService.instance;
  final telemetry = CameraTelemetryService.instance;
  final audio = CameraAudioService.instance;
  Timer? _statusTimer;
  StreamSubscription<String>? _cameraMessageSub;
  CameraStatus? _status;
  bool _busySnapshot = false;
  String _message = 'Connecting...';
  List<Map<String, dynamic>> _cameraHistory = const [];
  bool _historyLoading = false;

  @override
  void initState() {
    super.initState();
    telemetry.startListening();
    telemetry.addListener(_refresh);
    camera.addListener(_refresh);
    audio.addListener(_refresh);
    _cameraMessageSub = camera.status.listen((s) {
      if (mounted) setState(() => _message = s);
    });
    _connect();
    _loadCameraHistory();
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStatus());
  }

  Future<void> _connect() async {
    await telemetry.refresh();
    await _refreshStatus();
    await camera.startStream();
  }

  Future<void> _refreshStatus() async {
    final s = await camera.getStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _loadCameraHistory() async {
    if (_historyLoading || Supabase.instance.client.auth.currentSession == null) return;
    if (mounted) setState(() => _historyLoading = true);
    try {
      final rows = await HistoricalService.instance.fetchCameraEvents(limit: 20);
      if (mounted) setState(() => _cameraHistory = rows);
    } catch (e) {
      debugPrint('Camera mirrored history: $e');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _cameraMessageSub?.cancel();
    camera.stopStream();
    audio.stopListening();
    audio.stopPushToTalk();
    telemetry.removeListener(_refresh);
    camera.removeListener(_refresh);
    audio.removeListener(_refresh);
    telemetry.stopListening();
    super.dispose();
  }

  Future<void> _snapshot() async {
    if (_busySnapshot) return;
    setState(() {
      _busySnapshot = true;
      _message = 'Capturing and saving snapshot...';
    });
    final url = await camera.captureAndStoreSnapshot();
    if (url != null) await _loadCameraHistory();
    if (!mounted) return;
    setState(() {
      _busySnapshot = false;
      _message = url != null
          ? 'Snapshot saved; metadata is being synchronized to both databases'
          : (camera.lastError ?? 'Snapshot finished; check Supabase storage setup');
    });
  }

  Future<void> _toggleCamera(bool value) async {
    setState(() => _message = value ? 'Starting camera...' : 'Stopping camera...');
    final ok = await camera.setCameraEnabled(value);
    if (ok && value) await camera.startStream();
    await _refreshStatus();
  }

  Future<void> _toggleMic(bool value) async {
    await camera.setMicEnabled(value);
    await _refreshStatus();
  }

  Future<void> _toggleSpeaker(bool value) async {
    await camera.setSpeakerEnabled(value);
    await _refreshStatus();
  }

  Future<void> _toggleListen() async {
    if (audio.listening) {
      await audio.stopListening();
    } else {
      // Deliberately not awaited: this method loops until Stop is pressed.
      audio.startListening();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = telemetry.latest;
    final cameraOnline = (_status?.wifiConnected == true && _status?.cameraReady == true) || telemetry.online;
    final width = MediaQuery.sizeOf(context).width;
    final desktop = width >= 1000;

    final preview = _preview(cameraOnline);
    final controls = _controls(t);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(width < 390 ? 'AI Camera' : 'AI Camera & Two-Way Audio'),
        backgroundColor: Colors.transparent,
        actions: width < 430
            ? null
            : [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: _statusPill(
                    cameraOnline ? 'CAMERA ONLINE' : 'CAMERA OFFLINE',
                    cameraOnline ? AppColors.green : AppColors.red,
                  ),
                ),
              ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await telemetry.refresh();
          await _refreshStatus();
          await _loadCameraHistory();
          if (!camera.isStreaming) await camera.startStream();
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            Responsive.horizontalPadding(context),
            10,
            Responsive.horizontalPadding(context),
            92,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
              child: desktop
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: preview),
                        const SizedBox(width: 16),
                        Flexible(
                          flex: 2,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: controls,
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [preview, const SizedBox(height: 16), controls],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(bool cameraOnline) {
    return Column(
      children: [
        GlassPanel(
          radius: 18,
          padding: EdgeInsets.zero,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                StreamBuilder<Uint8List>(
                  stream: camera.frames,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return Container(
                        color: Colors.black87,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(cameraOnline ? Icons.videocam_outlined : Icons.videocam_off_outlined,
                                  size: 54, color: Colors.white70),
                              const SizedBox(height: 10),
                              Text(
                                cameraOnline ? 'Waiting for live frames...' : 'Camera is not reachable',
                                style: TextStyle(color: AppTheme.textSecondary(context)),
                              ),
                              const SizedBox(height: 8),
                              Text('Camera IP: ${telemetry.cameraIp}',
                                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
                            ],
                          ),
                        ),
                      );
                    }
                    return Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true);
                  },
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  child: _statusPill(camera.isStreaming ? 'LIVE' : 'STREAM STOPPED', camera.isStreaming ? AppColors.red : Colors.white70),
                ),
                Positioned(
                  bottom: 12,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: .58), borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      'http://${telemetry.cameraIp}:81/stream',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GlassPanel(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(child: _mini('Camera IP', telemetry.cameraIp, Icons.router_outlined, AppColors.orange)),
              Expanded(child: _mini('Motion', telemetry.latest?.motionDetected == true ? 'DETECTED' : 'Clear', Icons.directions_run, telemetry.latest?.motionDetected == true ? AppColors.red : AppColors.green)),
              Expanded(child: _mini('Wi-Fi', telemetry.latest == null ? '--' : '${telemetry.latest!.wifiRssi} dBm', Icons.wifi, AppColors.maroonMid)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _motionHistory(),
      ],
    );
  }

  Widget _controls(CameraTelemetry? t) {
    final s = _status;
    return Column(
      children: [
        _section(
          'DEVICE CONTROLS',
          Icons.tune,
          Column(
            children: [
              _toggleRow('Camera', Icons.videocam, s?.cameraEnabled ?? true, _toggleCamera),
              const Divider(height: 1),
              _toggleRow('Built-in microphone', Icons.mic, s?.micEnabled ?? true, _toggleMic),
              const Divider(height: 1),
              _toggleRow('SPK speaker', Icons.volume_up, s?.speakerEnabled ?? true, _toggleSpeaker),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _section(
          'TWO-WAY AUDIO',
          Icons.record_voice_over,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: _toggleListen,
                icon: Icon(audio.listening ? Icons.stop_circle_outlined : Icons.hearing),
                label: Text(audio.listening ? 'Stop Listening' : 'Listen to Camera'),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTapDown: (_) => audio.startPushToTalk(),
                onTapUp: (_) => audio.stopPushToTalk(),
                onTapCancel: () => audio.stopPushToTalk(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  height: 58,
                  decoration: BoxDecoration(
                    gradient: audio.talking ? GlassStyle.emergencyGradient : GlassStyle.brandGradient,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [BoxShadow(color: AppColors.red.withValues(alpha: audio.talking ? .45 : .18), blurRadius: 20)],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(audio.talking ? Icons.mic : Icons.mic_none, color: Colors.white),
                      const SizedBox(width: 10),
                      Text(audio.talking ? 'TALKING — RELEASE TO STOP' : 'HOLD TO TALK',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Half-duplex mode prevents the camera speaker from feeding back into its microphone.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)),
              ),
              const SizedBox(height: 8),
              Text(audio.status, style: TextStyle(fontSize: 11, color: AppTheme.brandForeground(context), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _section(
          'CAPTURE & SUPABASE',
          Icons.cloud_upload_outlined,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: _busySnapshot ? null : _snapshot,
                icon: _busySnapshot
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.camera_alt_outlined),
                label: const Text('Capture & Save Snapshot'),
              ),
              const SizedBox(height: 8),
              Text(
                'Motion telemetry is read from Supabase. Snapshots are uploaded to the incident-media bucket.',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _section(
          'CAMERA STATUS',
          Icons.info_outline,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Camera', s?.cameraReady == true ? 'Ready' : 'Unknown / offline'),
              _kv('Microphone', s?.micReady == true ? 'Ready' : 'Unknown / offline'),
              _kv('Speaker', s?.speakerReady == true ? 'Ready' : 'Unknown / offline'),
              _kv('Motion samples', '${s?.motionSamples ?? t?.motionPixels ?? 0}'),
              _kv('Virtual pan / tilt', '${s?.pan ?? t?.panAngle ?? 90}° / ${s?.tilt ?? t?.tiltAngle ?? 90}°'),
              const SizedBox(height: 8),
              Text(_message, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context))),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassPanel(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.open_with, color: AppTheme.textSecondary(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pan/tilt is currently virtual because no servos are installed. The app keeps the reported angles but does not claim physical movement.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _motionHistory() {
    if (_historyLoading && _cameraHistory.isEmpty) {
      return _section(
        'RECENT CAMERA EVENTS · MYSQL',
        Icons.history,
        const Center(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.orange),
          ),
        ),
      );
    }

    final rows = _cameraHistory.take(5).toList();
    return _section(
      'RECENT CAMERA EVENTS · MYSQL',
      Icons.history,
      rows.isEmpty
          ? Text(
              'No permanent camera events loaded yet. Live camera state still comes from Supabase.',
              style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12),
            )
          : Column(
              children: rows.map((row) {
                final created = DateTime.tryParse((row['created_at'] ?? '').toString());
                final type = (row['event_type'] ?? 'camera_event')
                    .toString()
                    .replaceAll('_', ' ');
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.videocam_outlined, color: AppTheme.brandForeground(context)),
                  title: Text(
                    type.toUpperCase(),
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    created?.toLocal().toString() ?? 'Time unavailable',
                    style: const TextStyle(fontSize: 10),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _toggleRow(String label, IconData icon, bool value, Future<void> Function(bool) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: value ? AppTheme.safeForeground(context) : AppTheme.textSecondary(context)),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _mini(String label, String value, IconData icon, Color color) => Column(
        children: [
          Icon(icon, color: AppTheme.statusForeground(context, color), size: 18),
          const SizedBox(height: 5),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          Text(label, style: TextStyle(fontSize: 9, color: AppTheme.textSecondary(context))),
        ],
      );

  Widget _kv(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: 11, color: AppTheme.textSecondary(context)))),
            Text(value, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _section(String title, IconData icon, Widget child) => GlassPanel(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Icon(icon, size: 18, color: AppTheme.brandForeground(context)), const SizedBox(width: 8), Text(title, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8))]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      );

  Widget _statusPill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: .35)),
        ),
        child: Text(text, style: TextStyle(color: AppTheme.statusForeground(context, color), fontSize: 10, fontWeight: FontWeight.w800)),
      );
}
