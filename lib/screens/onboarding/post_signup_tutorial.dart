import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../../services/dual_sync_service.dart';
import '../../theme.dart';

class _TutorialCue {
  final int startSecond;
  final IconData icon;
  final String title;
  final String body;
  final Color accent;

  const _TutorialCue({
    required this.startSecond,
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
  });
}

class _TutorialVideo {
  final String speaker;
  final String section;
  final String asset;
  final List<_TutorialCue> cues;

  const _TutorialVideo({
    required this.speaker,
    required this.section,
    required this.asset,
    required this.cues,
  });
}

const _tutorialVideos = <_TutorialVideo>[
  _TutorialVideo(
    speaker: 'Nowel',
    section: 'PyroGuard Overview',
    asset: 'assets/tutorial/narration/nowellastna.mp4',
    cues: [
      _TutorialCue(
        startSecond: 0,
        icon: Icons.shield_outlined,
        title: 'One security dashboard',
        body: 'PyroGuard brings home security, environmental sensing, camera status and system controls into one responsive application.',
        accent: AppColors.orange,
      ),
      _TutorialCue(
        startSecond: 13,
        icon: Icons.cloud_done_outlined,
        title: 'Cloud online and hardware online are different states',
        body: 'The application can stay connected while the ESP32 is offline. Hardware values remain unavailable until fresh telemetry and heartbeat data arrive.',
        accent: AppColors.green,
      ),
      _TutorialCue(
        startSecond: 27,
        icon: Icons.monitor_heart_outlined,
        title: 'Realtime monitoring starts automatically',
        body: 'When the controller and camera begin publishing fresh data, the dashboard updates automatically without inventing placeholder readings.',
        accent: AppColors.red,
      ),
    ],
  ),
  _TutorialVideo(
    speaker: 'Debb',
    section: 'Security Modes & Controls',
    asset: 'assets/tutorial/narration/debbb.mp4',
    cues: [
      _TutorialCue(
        startSecond: 0,
        icon: Icons.lock_outline,
        title: 'ARM AWAY',
        body: 'Use ARM AWAY when the property should be fully guarded. Door, window and motion protection can participate in intrusion decisions.',
        accent: AppColors.red,
      ),
      _TutorialCue(
        startSecond: 16,
        icon: Icons.home_outlined,
        title: 'ARM HOME',
        body: 'ARM HOME keeps selected perimeter protection active while allowing expected movement inside the residence.',
        accent: AppColors.orange,
      ),
      _TutorialCue(
        startSecond: 32,
        icon: Icons.lock_open_outlined,
        title: 'DISARM does not disable safety sensing',
        body: 'Intrusion rules can be disarmed, while smoke/gas and flame monitoring remain active safety functions and continue to be recorded.',
        accent: AppColors.amber,
      ),
    ],
  ),
  _TutorialVideo(
    speaker: 'Danaya',
    section: 'Safety & Emergency Response',
    asset: 'assets/tutorial/narration/danayaa.mp4',
    cues: [
      _TutorialCue(
        startSecond: 0,
        icon: Icons.local_fire_department_outlined,
        title: 'Hazards stay visible',
        body: 'Smoke/gas, flame, temperature and related safety conditions stay visible together with separate sensor-health information.',
        accent: AppColors.redBright,
      ),
      _TutorialCue(
        startSecond: 15,
        icon: Icons.contact_phone_outlined,
        title: 'BFP contact information is saved',
        body: 'The registered BFP station, personnel/contact person, phone number and address are available in Settings and during a confirmed emergency.',
        accent: AppColors.orangeDeep,
      ),
      _TutorialCue(
        startSecond: 30,
        icon: Icons.phone_in_talk_outlined,
        title: 'CALL BFP remains a deliberate user action',
        body: 'PyroGuard can warn, record and present the emergency contact, but the homeowner deliberately taps CALL BFP to place the actual telephone call.',
        accent: AppColors.maroonMid,
      ),
    ],
  ),
  _TutorialVideo(
    speaker: 'Benedict',
    section: 'Heartbeat, Evidence & Records',
    asset: 'assets/tutorial/narration/benediktuspaktus.mp4',
    cues: [
      _TutorialCue(
        startSecond: 0,
        icon: Icons.sensors_outlined,
        title: 'Reading and connection health are separate',
        body: 'A previous SAFE smoke reading does not prove the MQ-2 is still connected. Heartbeat health shows ONLINE, DELAYED or OFFLINE independently.',
        accent: AppColors.green,
      ),
      _TutorialCue(
        startSecond: 17,
        icon: Icons.storage_outlined,
        title: 'Important records are stored in both databases',
        body: 'Supabase and MySQL retain the same important sensor, event, camera, configuration and audit records, with retry support when a MySQL mirror is temporarily unavailable.',
        accent: AppColors.orange,
      ),
      _TutorialCue(
        startSecond: 34,
        icon: Icons.history_outlined,
        title: 'Review what happened later',
        body: 'Events, evidence, settings changes and security actions remain traceable so the homeowner can review the sequence of an incident.',
        accent: AppColors.red,
      ),
    ],
  ),
];

class PostSignupTutorialScreen extends StatefulWidget {
  const PostSignupTutorialScreen({super.key});

  @override
  State<PostSignupTutorialScreen> createState() => _PostSignupTutorialScreenState();
}

class _PostSignupTutorialScreenState extends State<PostSignupTutorialScreen> {
  final _pages = PageController();
  Timer? _ticker;
  final _interpolation = Stopwatch();
  Duration _lastPosition = const Duration(milliseconds: -1);
  VideoPlayerController? _controller;
  Map<String, dynamic> _manifest = {};
  int _videoIndex = 0;
  int _cueIndex = 0;
  int _frame = 0;
  int _generation = 0;
  bool _loading = true;
  bool _finishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 83), (_) => _tick());
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _manifest = jsonDecode(await rootBundle.loadString('assets/tutorial/transparent/manifest.json')) as Map<String, dynamic>;
      await _load(_videoIndex);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'The tutorial could not load. Please try again.'; });
    }
  }

  Future<void> _load(int index) async {
    final generation = ++_generation;
    _lastPosition = const Duration(milliseconds: -1);
    _interpolation.reset();
    final old = _controller;
    _controller = null;
    old?.removeListener(_tick);
    if (mounted) setState(() { _loading = true; _error = null; _frame = 0; _cueIndex = 0; });
    await old?.dispose();
    if (!mounted || generation != _generation) return;
    // The original media provides narration and a single clock. Only the
    // extracted RGBA drawings are rendered; the opaque video never enters UI.
    final next = VideoPlayerController.asset(_tutorialVideos[index].asset);
    try {
      await next.initialize();
      if (!mounted || generation != _generation) { await next.dispose(); return; }
      _controller = next;
      next.addListener(_tick);
      setState(() => _loading = false);
      try { await next.play(); } catch (_) {
        // Browsers can block audible autoplay. Continue the animation silently.
        await next.setVolume(0);
        await next.play();
      }
    } catch (_) {
      if (_controller == next) _controller = null;
      await next.dispose();
      if (mounted && generation == _generation) setState(() { _loading = false; _error = 'Narration could not load. Tap Retry or swipe to the next guide.'; });
    }
  }

  String _stem(int index) => _tutorialVideos[index].asset.split('/').last.split('.').first;
  void _tick() {
    final c = _controller;
    if (!mounted || c == null || !c.value.isInitialized) return;
    final clip = _tutorialVideos[_videoIndex];
    final info = _manifest[_stem(_videoIndex)] as Map?;
    final count = (info?['count'] as num?)?.toInt() ?? 1;
    final fps = (info?['fps'] as num?)?.toInt() ?? 12;
    if (c.value.position != _lastPosition) {
      _lastPosition = c.value.position;
      _interpolation.reset();
    }
    if (c.value.isPlaying) { _interpolation.start(); } else { _interpolation.stop(); _interpolation.reset(); }
    final positionMs = (c.value.position.inMilliseconds + _interpolation.elapsedMilliseconds)
      .clamp(0, c.value.duration.inMilliseconds).toInt();
    final frame = (positionMs * fps ~/ 1000).clamp(0, count - 1).toInt();
    var cue = 0;
    for (var i = 0; i < clip.cues.length; i++) {
      if (c.value.position.inSeconds >= clip.cues[i].startSecond) cue = i;
    }
    if (frame != _frame || cue != _cueIndex) setState(() { _frame = frame; _cueIndex = cue; });
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    try { await _controller?.pause(); } catch (_) {}
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await Supabase.instance.client.auth.updateUser(UserAttributes(data: {
          ...?user.userMetadata, 'onboarding_completed': true,
        }));
        await DualSyncService.instance.writeMirror(recordType: 'onboarding', recordKey: 'tutorial', payload: {
          'onboarding_completed': true, 'tutorial_video_count': 4,
          'completed_at': DateTime.now().toUtc().toIso8601String(),
        });
      }
      if (mounted) context.go('/dashboard');
    } catch (_) {
      if (mounted) {
        setState(() => _finishing = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not save tutorial completion. Please try again.')));
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _ticker?.cancel();
    _controller?.removeListener(_tick);
    _controller?.dispose();
    _pages.dispose();
    super.dispose();
  }

  Widget _drawing(int index) {
    final current = index == _videoIndex;
    final frame = current ? _frame : 0;
    return Image.asset('assets/tutorial/transparent/${_stem(index)}/${frame.toString().padLeft(4, '0')}.webp',
      fit: BoxFit.contain, gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.school_outlined, size: 80)));
  }

  // One cue as a real card: centred text, accent header glow, a round icon
  // badge sitting on the top edge, and a "speaker · 1 of 3" chip.
  Widget _cueCard(_TutorialVideo clip, _TutorialCue cue, int cueIndex, {Key? key}) {
    final cardColor = AppTheme.card(context);
    return Container(
      key: key,
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: cue.accent.withValues(alpha: .35), width: 1.4),
        boxShadow: [
          BoxShadow(color: cue.accent.withValues(alpha: .22), blurRadius: 30, offset: const Offset(0, 14)),
          BoxShadow(color: Colors.black.withValues(alpha: .10), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
        Positioned(top: 0, left: 0, right: 0, child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Container(height: 70, decoration: BoxDecoration(gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [cue.accent.withValues(alpha: .20), cue.accent.withValues(alpha: 0)]))))),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 46, 24, 22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(color: cue.accent.withValues(alpha: .12), borderRadius: BorderRadius.circular(99)),
              child: Text('${clip.speaker.toUpperCase()} · ${cueIndex + 1} OF ${clip.cues.length}',
                style: TextStyle(color: cue.accent, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .8)),
            ),
            const SizedBox(height: 12),
            Text(cue.title, textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 21, fontWeight: FontWeight.w900, height: 1.2)),
            const SizedBox(height: 10),
            Text(cue.body, textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 15.5, height: 1.55)),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < clip.cues.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: i == cueIndex ? 22 : 8, height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i == cueIndex ? cue.accent : AppTheme.border(context),
                    borderRadius: BorderRadius.circular(8)),
                ),
            ]),
          ]),
        ),
        Positioned(top: -30, child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [cue.accent, Color.lerp(cue.accent, Colors.black, .25)!]),
            border: Border.all(color: cardColor, width: 4),
            boxShadow: [BoxShadow(color: cue.accent.withValues(alpha: .45), blurRadius: 16, offset: const Offset(0, 6))],
          ),
          child: Icon(cue.icon, color: Colors.white, size: 28),
        )),
      ]),
    );
  }

  // The current cue sits on top of a small deck: the cues still to come peek
  // out behind it, slightly rotated, so it reads as a stack of cards.
  Widget _cardDeck(int index) {
    final clip = _tutorialVideos[index];
    final cueIndex = index == _videoIndex ? _cueIndex : 0;
    final cue = clip.cues[cueIndex];
    final behind = math.min(clip.cues.length - cueIndex - 1, 2);
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    return Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
      for (var i = behind; i >= 1; i--)
        Positioned.fill(child: Transform.translate(
          offset: Offset(0, 10.0 * i),
          child: Transform.rotate(
            angle: (i.isOdd ? -0.03 : 0.024) * i,
            child: DecoratedBox(decoration: BoxDecoration(
              color: Color.alphaBlend(clip.cues[cueIndex + i].accent.withValues(alpha: .10), AppTheme.card(context)),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: clip.cues[cueIndex + i].accent.withValues(alpha: .25)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .08), blurRadius: 18, offset: const Offset(0, 8))],
            )),
          ),
        )),
      AnimatedSwitcher(
        duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 550),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter,
          children: [...previous, if (current != null) current]),
        transitionBuilder: (child, animation) => FadeTransition(opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, .10), end: Offset.zero).animate(animation),
            child: ScaleTransition(scale: Tween<double>(begin: .94, end: 1).animate(animation), child: child))),
        child: _cueCard(clip, cue, cueIndex, key: ValueKey('$index:$cueIndex')),
      ),
    ]);
  }

  // Desktop: comfortably inset side-by-side card and transparent animation.
  // Mobile: animation crosses the upper edge of the card in a responsive stage.
  Widget _stage(int index) => LayoutBuilder(builder: (context, size) {
    final wide = size.maxWidth >= 760;
    if (wide) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: Row(children: [
          Expanded(flex: 10, child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 475),
            child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(14, 38, 14, 28),
              child: _cardDeck(index))))),
          const SizedBox(width: 34),
          Expanded(flex: 11, child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 475), child: _drawing(index)))),
        ]),
      );
    }
    final animationHeight = (size.maxHeight * .54).clamp(190.0, 390.0);
    // A small, smooth lateral motion follows the drawing frame, allowing the
    // speaker to overlap either side of the cue card without clipping it.
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final movement = reducedMotion ? 0.0 :
        math.sin((_frame / 12.0) * 1.2 + (_cueIndex.isEven ? 0 : math.pi)) * math.min(42.0, size.maxWidth * .10);
    return Stack(clipBehavior: Clip.none, children: [
      Positioned.fill(top: animationHeight * .70, child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(width: math.min(size.maxWidth - 36, 450),
          child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 38, 10, 28),
            child: _cardDeck(index))),
      )),
      Positioned(top: 0, left: 14, right: 14, height: animationHeight,
        child: IgnorePointer(child: Transform.translate(
          offset: Offset(movement, 0), child: _drawing(index)))),
    ]);
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: Colors.transparent, body: AmbientBackdrop(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1120), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 10), child: Row(children: [
        const PyroGuardLogo(), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Welcome to PyroGuard', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          Text('${_videoIndex + 1}/4 · ${_tutorialVideos[_videoIndex].section}', style: const TextStyle(fontSize: 12)),
        ])),
        TextButton(onPressed: _finishing ? null : _finish, child: const Text('Skip')),
      ])),
      Expanded(child: PageView.builder(controller: _pages, itemCount: 4,
        onPageChanged: (index) { setState(() => _videoIndex = index); _load(index); },
        itemBuilder: (_, index) => _stage(index))),
      if (_loading) const LinearProgressIndicator(color: AppColors.orange),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: Row(children: [
        Expanded(child: Text(_error!)), TextButton(onPressed: () => _load(_videoIndex), child: const Text('Retry'))])),
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: Row(children: [
        IconButton(tooltip: 'Previous guide', onPressed: _videoIndex == 0 ? null : () => _pages.previousPage(duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic), icon: const Icon(Icons.arrow_back)),
        Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < 4; i++)
          Semantics(label: 'Guide ${i + 1}', selected: i == _videoIndex, child: InkWell(
            onTap: () => _pages.animateToPage(i, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic),
            child: Padding(padding: const EdgeInsets.all(8), child: AnimatedContainer(duration: const Duration(milliseconds: 200),
              width: i == _videoIndex ? 26 : 8, height: 8,
              decoration: BoxDecoration(color: i == _videoIndex ? AppColors.orange : AppTheme.border(context), borderRadius: BorderRadius.circular(10))))))])),
        FilledButton(onPressed: _finishing ? null : _videoIndex == 3 ? _finish
          : () => _pages.nextPage(duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic),
          child: Text(_finishing ? 'Saving…' : _videoIndex == 3 ? 'Get started' : 'Next')),
      ])),
    ]))))));
  }
}
