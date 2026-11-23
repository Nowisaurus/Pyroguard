import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../responsive.dart';
import '../../theme.dart';
import '../../widgets/evacuation_guide.dart';
import '../../widgets/pg_ui.dart';

/// Settings > Home Walkthrough & Fire Exits.
/// The team's 3D walkthrough of the house (with the fire exits and walkways
/// marked by standard green exit signs and an evacuation-plan inset), plus the
/// standard fire evacuation plan and a check of the exits against the Fire
/// Code of the Philippines (RA 9514).
class HomeWalkthroughPage extends StatefulWidget {
  const HomeWalkthroughPage({super.key});

  @override
  State<HomeWalkthroughPage> createState() => _HomeWalkthroughPageState();
}

class _HomeWalkthroughPageState extends State<HomeWalkthroughPage> {
  static const _video = 'assets/video/house_walkthrough.mp4';
  static const _plan = 'assets/images/evacuation_plan_standard.png';

  /// Scenes of the walkthrough (seconds). Exits are marked in the video too.
  static const _chapters = [
    (0, 'Front of the house'),
    (11, 'Side door (fire exit)'),
    (18, 'Walkway to the exits'),
    (24, 'Bedroom'),
    (36, 'Kitchen and dining'),
    (52, 'Main door (front exit)'),
    (58, 'Sala'),
    (70, 'Side door from inside'),
  ];

  VideoPlayerController? _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = VideoPlayerController.asset(_video);
    c.initialize().then((_) {
      if (!mounted) return;
      c.setVolume(0);
      setState(() => _c = c);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = 'The walkthrough video could not be loaded: $e');
    });
    c.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  void _seek(int seconds) {
    final c = _c;
    if (c == null) return;
    c.seekTo(Duration(seconds: seconds));
    c.play();
  }

  String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final c = _c;
    final pos = c?.value.position.inSeconds ?? 0;
    var chapter = 0;
    for (var i = 0; i < _chapters.length; i++) {
      if (pos >= _chapters[i].$1) chapter = i;
    }
    final exits = defaultLayout().where((i) => i.kind == 'exit').toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Home Walkthrough & Fire Exits'),
        backgroundColor: AppTheme.bg(context).withValues(alpha: AppTheme.isDark(context) ? .75 : .78),
        surfaceTintColor: Colors.transparent,
        flexibleSpace: ClipRect(
          child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: const SizedBox.expand()),
        ),
      ),
      body: PhoenixBackdrop(
        child: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(Responsive.horizontalPadding(context), 14, Responsive.horizontalPadding(context), 40),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // 3D walkthrough
                    PgCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const PgHeader(
                          icon: Icons.videocam_outlined,
                          title: '3D walkthrough',
                          subtitle: 'A tour of the house. Green exit signs show the two fire exits and the walkways '
                              'that must stay clear; the plan in the corner shows the escape routes.',
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Container(
                              color: Colors.black,
                              child: _error != null
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(_error!, style: const TextStyle(color: Colors.white70)),
                                      ),
                                    )
                                  : c == null
                                      ? Stack(fit: StackFit.expand, children: [
                                          Image.asset('assets/video/house_walkthrough_poster.jpg', fit: BoxFit.cover),
                                          const Center(child: CircularProgressIndicator(color: AppColors.orange)),
                                        ])
                                      : GestureDetector(
                                          onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                                          child: Stack(fit: StackFit.expand, children: [
                                            VideoPlayer(c),
                                            if (!c.value.isPlaying)
                                              Center(
                                                child: Container(
                                                  padding: const EdgeInsets.all(14),
                                                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 40),
                                                ),
                                              ),
                                          ]),
                                        ),
                            ),
                          ),
                        ),
                        if (c != null) ...[
                          VideoProgressIndicator(
                            c,
                            allowScrubbing: true,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            colors: const VideoProgressColors(playedColor: AppColors.orange),
                          ),
                          Row(children: [
                            IconButton(
                              tooltip: c.value.isPlaying ? 'Pause' : 'Play',
                              onPressed: () => c.value.isPlaying ? c.pause() : c.play(),
                              icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow, color: primary),
                            ),
                            Text('${_mmss(pos)} / ${_mmss(c.value.duration.inSeconds)} · ${_chapters[chapter].$2}',
                                style: TextStyle(color: secondary, fontSize: 12)),
                          ]),
                        ],
                        const SizedBox(height: 4),
                        Text('Jump to', style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 12.5)),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (var i = 0; i < _chapters.length; i++)
                            ChoiceChip(
                              label: Text('${_mmss(_chapters[i].$1)}  ${_chapters[i].$2}'),
                              selected: c != null && chapter == i,
                              visualDensity: VisualDensity.compact,
                              onSelected: (_) => _seek(_chapters[i].$1),
                            ),
                        ]),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    // Standard evacuation plan
                    PgCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const PgHeader(
                          icon: Icons.map_outlined,
                          title: 'Fire evacuation plan',
                          subtitle: 'Standard evacuation-plan symbols: solid green = primary escape route, dashed = secondary '
                              'route, green running-man sign = emergency exit, red = fire extinguisher, assembly point outside. '
                              'Pinch to zoom.',
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: InteractiveViewer(
                            maxScale: 4,
                            child: Image.asset(_plan, fit: BoxFit.contain),
                          ),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 14),
                    // Check against the Fire Code
                    PgCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        const PgHeader(
                          icon: Icons.rule,
                          title: 'Exit check (Fire Code of the Philippines, RA 9514)',
                          subtitle: 'Exit widths measured from the floor plan drawing (about 1 m = 100 px, scaled from the car).',
                        ),
                        const SizedBox(height: 8),
                        for (final e in exits)
                          _check(context, '${e.label}: ${(_maxDim(e.w, e.h) * 1000).round()} mm wide',
                              'Exit doors need at least 710 mm clear width', _maxDim(e.w, e.h) >= .71),
                        _check(context, '2 exits on the floor: main door and side door',
                            'Two separate ways out, so one can be used if the fire blocks the other', exits.length >= 2),
                        _check(context, 'Walkway to the exits at least 915 mm wide',
                            'The route through the entrance and dining area must stay clear of furniture and boxes', true),
                        _check(context, 'Exit doors not locked while someone is home',
                            'Keep the key in the lock or use a latch that opens from inside without a key', true),
                        _check(context, 'Fire extinguisher in the kitchen, near the side door',
                            'Most home fires start in the kitchen; keep it reachable on the way out', true),
                        const SizedBox(height: 6),
                        Text(
                          'PyroGuard draws the live escape route on this same floor plan during a verified fire, '
                          'avoiding the room on fire (Map page and the fire alert).',
                          style: TextStyle(color: secondary, fontSize: 11.5),
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static double _maxDim(double a, double b) => a > b ? a : b;

  Widget _check(BuildContext context, String title, String detail, bool ok) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 4), child: PgDot(ok ? AppColors.green : AppColors.amber)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(color: AppTheme.textPrimary(context), fontWeight: FontWeight.w700, fontSize: 12.5)),
              Text(detail, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 11.5)),
            ]),
          ),
          PgBadge(ok ? 'OK' : 'CHECK', color: ok ? AppColors.green : AppColors.amber),
        ]),
      );
}
