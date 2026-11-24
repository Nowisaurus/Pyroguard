import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/recording_video.dart';
import '../../theme.dart';
import '../../widgets/pg_notice.dart';
import '../../widgets/pg_ui.dart';

/// Evidence > Recordings: every camera recording, playable in the app and
/// downloadable as a video file (MJPEG .avi: VLC, Windows Media Player,
/// Movies & TV, most phone players).
class RecordingsTab extends StatefulWidget {
  const RecordingsTab({super.key});

  @override
  State<RecordingsTab> createState() => _RecordingsTabState();
}

class _RecordingsTabState extends State<RecordingsTab> {
  static final _when = DateFormat('MMM d, yyyy  h:mm:ss a');
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  String? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('camera_history')
          .select('id,image_url,metadata_json,created_at')
          .eq('event_type', 'recording')
          .order('created_at', ascending: false)
          .limit(100);
      _rows = [for (final r in rows as List) Map<String, dynamic>.from(r as Map)];
      _error = null;
    } catch (e) {
      _error = 'Recordings could not be loaded: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic> _meta(Map<String, dynamic> r) =>
      r['metadata_json'] is Map ? Map<String, dynamic>.from(r['metadata_json'] as Map) : <String, dynamic>{};

  List<String> _frames(Map<String, dynamic> r) {
    final f = _meta(r)['frame_urls'];
    if (f is List) return [for (final u in f) '$u'];
    final first = r['image_url'];
    return first == null ? const [] : ['$first'];
  }

  String _fileName(Map<String, dynamic> r) {
    final d = DateTime.tryParse('${r['created_at']}')?.toLocal() ?? DateTime.now();
    return 'PyroGuard_Camera1_${DateFormat('yyyyMMdd_HHmmss').format(d)}.avi';
  }

  Future<void> _download(Map<String, dynamic> r) async {
    final id = (r['id'] as num).toInt();
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      var url = '${_meta(r)['video_url'] ?? ''}';
      if (url.isEmpty) {
        // Older recording without a video file: build it now from its frames.
        final frames = _frames(r);
        final folder = frames.isEmpty ? null : RecordingVideo.folderOf(frames.first);
        if (folder == null) throw StateError('This recording has no frames.');
        final secs = (_meta(r)['duration_seconds'] as num?)?.toInt() ?? frames.length;
        final int fps = secs <= 0 ? 1 : (frames.length / secs).round().clamp(1, 30).toInt();
        url = await RecordingVideo.buildAndStore(frames, folder, fps: fps);
      }
      final ok = await RecordingVideo.download(url, _fileName(r));
      if (!ok) throw StateError('The browser blocked the download.');
    } catch (e) {
      PgNotice.show('$e', kind: PgNoticeKind.error, title: 'Download failed');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _play(Map<String, dynamic> r) {
    final frames = _frames(r);
    if (frames.isEmpty) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .45),
      builder: (_) => _PlayerDialog(
        frames: frames,
        title: _when.format(DateTime.parse('${r['created_at']}').toLocal()),
        onDownload: () => _download(r),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.red));
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: AppTheme.warningForeground(context))));
    }
    if (_rows.isEmpty) {
      return Center(
        child: Text('No recordings yet. Press Record on the camera page.',
            style: TextStyle(color: secondary, fontSize: 15)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: _rows.length,
        itemBuilder: (context, i) {
          final r = _rows[i];
          final m = _meta(r);
          final frames = _frames(r);
          final secs = (m['duration_seconds'] as num?)?.toInt() ?? frames.length;
          final busy = _busy.contains((r['id'] as num).toInt());
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PgCard(
                  child: Row(children: [
                    InkWell(
                      onTap: () => _play(r),
                      borderRadius: BorderRadius.circular(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 128,
                          height: 80,
                          child: Stack(fit: StackFit.expand, children: [
                            if (frames.isNotEmpty)
                              Image.network(frames.first, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black)),
                            const Center(child: Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 36)),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Camera 1 recording',
                            style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 14)),
                        const SizedBox(height: 2),
                        Text(_when.format(DateTime.parse('${r['created_at']}').toLocal()),
                            style: TextStyle(color: secondary, fontSize: 12)),
                        Text('${secs}s · ${frames.length} frames',
                            style: TextStyle(color: secondary, fontSize: 12)),
                      ]),
                    ),
                    // Play and Download on one line.
                    IconButton(
                      tooltip: 'Play',
                      onPressed: () => _play(r),
                      icon: Icon(Icons.play_arrow_rounded, color: AppTheme.brandForeground(context)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.red, foregroundColor: Colors.white),
                      onPressed: busy ? null : () => _download(r),
                      icon: busy
                          ? const SizedBox(
                              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.download_rounded, size: 18),
                      label: Text(busy ? 'Preparing' : 'Download'),
                    ),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Plays a recording's frames in order (1 per second, as recorded).
class _PlayerDialog extends StatefulWidget {
  const _PlayerDialog({required this.frames, required this.title, required this.onDownload});
  final List<String> frames;
  final String title;
  final VoidCallback onDownload;

  @override
  State<_PlayerDialog> createState() => _PlayerDialogState();
}

class _PlayerDialogState extends State<_PlayerDialog> {
  int _i = 0;
  bool _playing = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    for (final u in widget.frames.take(10)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) precacheImage(NetworkImage(u), context);
      });
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_playing || !mounted) return;
      setState(() => _i = (_i + 1) % widget.frames.length);
      final next = (_i + 5) % widget.frames.length;
      precacheImage(NetworkImage(widget.frames[next]), context);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    return PgGlassDialog(
      title: 'Recording',
      subtitle: '${widget.title} · Camera 1',
      icon: Icons.videocam_outlined,
      maxWidth: 900,
      actions: [
        TextButton.icon(
          onPressed: widget.onDownload,
          icon: Icon(Icons.download_rounded, color: AppTheme.brandForeground(context), size: 18),
          label: Text('Download', style: TextStyle(color: AppTheme.brandForeground(context), fontWeight: FontWeight.w800)),
        ),
      ],
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Fits the window: the picture shrinks so the controls stay visible.
        Flexible(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.network(widget.frames[_i], fit: BoxFit.contain, gaplessPlayback: true),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 14, 10),
          child: Row(children: [
            IconButton(
              tooltip: _playing ? 'Pause' : 'Play',
              onPressed: () => setState(() => _playing = !_playing),
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: primary),
            ),
            Expanded(
              child: Slider(
                value: _i.toDouble(),
                max: (widget.frames.length - 1).clamp(1, 100000).toDouble(),
                activeColor: AppColors.orange,
                onChanged: (v) => setState(() => _i = v.round().clamp(0, widget.frames.length - 1).toInt()),
              ),
            ),
            Text('${_i + 1}/${widget.frames.length}',
                style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      ]),
    );
  }
}
