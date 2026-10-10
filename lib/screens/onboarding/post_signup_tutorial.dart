import 'dart:async';
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
    await _controller?.pause();
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

  Widget _card(int index) {
    final clip = _tutorialVideos[index];
    final cueIndex = index == _videoIndex ? _cueIndex : 0;
    final cue = clip.cues[cueIndex];
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    return AnimatedSwitcher(
      duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 550),
      transitionBuilder: (child, animation) => FadeTransition(opacity: animation,
        child: SlideTransition(position: Tween<Offset>(begin: const Offset(0, .12), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: ScaleTransition(scale: Tween<double>(begin: .92, end: 1).animate(animation), child: child))),
      child: GlassPanel(key: ValueKey('$index:$cueIndex'), radius: 28,
        padding: const EdgeInsets.all(22), child: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(cue.icon, color: cue.accent, size: 36),
          const SizedBox(height: 14),
          Text(cue.title, style: TextStyle(color: AppTheme.textPrimary(context), fontSize: 23, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          Text(cue.body, style: TextStyle(color: AppTheme.textSecondary(context), fontSize: 16, height: 1.5)),
          const SizedBox(height: 18),
          Row(children: [for (var i = 0; i < clip.cues.length; i++)
            Expanded(child: Container(height: 4, margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(color: i == cueIndex ? cue.accent : AppTheme.border(context), borderRadius: BorderRadius.circular(8))))]),
        ])),
    );
  }

  Widget _stage(int index) => LayoutBuilder(builder: (context, size) {
    final wide = size.maxWidth >= 760;
    final drawing = _drawing(index);
    final cards = SingleChildScrollView(child: _card(index));
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: wide
      ? Row(children: [Expanded(flex: 5, child: Center(child: cards)), Expanded(flex: 4, child: drawing)])
      : Column(children: [Expanded(flex: 5, child: cards), Expanded(flex: 4, child: drawing)]));
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(backgroundColor: AppTheme.bg(context), body: AmbientBackdrop(child: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 10), child: Row(children: [
        const PyroGuardLogo(), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Welcome to PyroGuard', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          Text('${_videoIndex + 1}/4 · ${_tutorialVideos[_videoIndex].section}', style: const TextStyle(fontSize: 12)),
        ])),
        if (_videoIndex == 3) TextButton(onPressed: _finishing ? null : _finish, child: const Text('Skip')),
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
    ]))));
  }
}
