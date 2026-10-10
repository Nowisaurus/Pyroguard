import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../theme.dart';

class _Slide {
  final Color start;
  final Color end;
  final Color glow;
  final String badge;
  final IconData icon;
  final String title;
  final String subtitle;
  final String description;

  const _Slide({
    required this.start,
    required this.end,
    required this.glow,
    required this.badge,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.description,
  });
}

const _slides = <_Slide>[
  _Slide(
    start: AppColors.orange,
    end: AppColors.red,
    glow: Color(0x40F97316),
    badge: 'HOME MONITORING & SECURITY',
    icon: Icons.shield_outlined,
    title: 'PyroGuard',
    subtitle: 'One professional home-safety workspace',
    description: 'Monitor intrusion protection, fire and gas hazards, connected hardware, evidence, emergency contacts and system health from one responsive application.',
  ),
  _Slide(
    start: AppColors.red,
    end: AppColors.maroonMid,
    glow: Color(0x40DC2626),
    badge: 'ARM HOME · ARM AWAY · DISARM',
    icon: Icons.security_outlined,
    title: 'Control Your Security',
    subtitle: 'Choose the protection mode that fits the moment',
    description: 'Control door, window and motion protection while smoke/gas and flame safety monitoring continue independently of intrusion mode.',
  ),
  _Slide(
    start: AppColors.redDeep,
    end: AppColors.maroon,
    glow: Color(0x40B91C1C),
    badge: 'PINNED HOME & EMERGENCY DETAILS',
    icon: Icons.location_on_outlined,
    title: 'Verified Property Context',
    subtitle: 'Keep the right home location and contacts available',
    description: 'Pin the monitored property, save stakeholders and BFP information, and reuse the same verified details in monitoring, history and emergency review.',
  ),
  _Slide(
    start: AppColors.maroonMid,
    end: AppColors.orangeDeep,
    glow: Color(0x40C2410C),
    badge: 'ESP32 + AI CAMERA + HEARTBEAT',
    icon: Icons.sensors_outlined,
    title: 'Connected Hardware',
    subtitle: 'Realtime sensing begins automatically when hardware connects',
    description: 'PyroGuard keeps cloud status separate from device health. Until a fresh heartbeat arrives, hardware readings remain unavailable instead of showing invented values.',
  ),
  _Slide(
    start: AppColors.maroon,
    end: AppColors.orange,
    glow: Color(0x40450A0A),
    badge: 'SUPABASE + MYSQL DUAL RECORDING',
    icon: Icons.storage_outlined,
    title: 'Every Important Record Is Retained',
    subtitle: 'The same application data is recorded in both databases',
    description: 'Sensor history, events, camera records, configuration, controls, settings and audit actions are retained in Supabase and MySQL with retry tracking when either mirror is temporarily unavailable.',
  ),
  _Slide(
    start: AppColors.red,
    end: AppColors.maroon,
    glow: Color(0x40DC2626),
    badge: 'ONE LOGIN · ROLE-BASED ACCESS',
    icon: Icons.verified_user_outlined,
    title: 'Built for Homeowners and Administrators',
    subtitle: 'One login screen, protected role-specific destinations',
    description: 'Homeowners enter the monitoring application while the four fixed administrator accounts are routed directly to the protected Admin Console. The same responsive experience supports phone, tablet and web.',
  ),
];

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  double _offset = 0;
  bool _dragging = false;
  late final AnimationController _controller;
  Animation<double>? _animation;

  static const double _threshold = 58;
  static const double _flyDistance = 460;
  static const double _desktopBreakpoint = 900;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _cancelAnimation() {
    if (_controller.isAnimating) {
      _controller.stop();
      _animation = null;
    }
  }

  void _onPanStart(DragStartDetails _) {
    _cancelAnimation();
    setState(() => _dragging = true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_controller.isAnimating) {
      setState(() => _offset += details.delta.dx);
    }
  }

  void _onPanEnd(DragEndDetails details) {
    setState(() => _dragging = false);
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (_offset < -_threshold || velocity < -400) {
      _animateTo((_index + 1) % _slides.length, -_flyDistance);
    } else if (_offset > _threshold || velocity > 400) {
      _animateTo((_index - 1 + _slides.length) % _slides.length, _flyDistance);
    } else {
      _snapBack();
    }
  }

  void _animateTo(int next, double target) {
    final start = _offset;
    _animation = Tween<double>(begin: start, end: target).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInCubic),
    )..addListener(() {
        if (mounted) setState(() => _offset = _animation!.value);
      });
    _controller
      ..duration = const Duration(milliseconds: 210)
      ..forward(from: 0).then((_) {
        if (mounted) {
          setState(() {
            _index = next;
            _offset = 0;
            _animation = null;
          });
        }
      });
  }

  void _snapBack() {
    final start = _offset;
    _animation = Tween<double>(begin: start, end: 0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    )..addListener(() {
        if (mounted) setState(() => _offset = _animation!.value);
      });
    _controller
      ..duration = const Duration(milliseconds: 360)
      ..forward(from: 0).then((_) {
        if (mounted) {
          setState(() {
            _offset = 0;
            _animation = null;
          });
        }
      });
  }

  void _goTo(int index) {
    if (index == _index) return;
    _cancelAnimation();
    setState(() {
      _index = index;
      _offset = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg(context),
      body: PhoenixBackdrop(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= _desktopBreakpoint) {
                return _desktop(context, constraints);
              }
              return _mobile(context, constraints);
            },
          ),
        ),
      ),
    );
  }

  Widget _mobile(BuildContext context, BoxConstraints constraints) {
    final size = MediaQuery.sizeOf(context);
    final cardWidth = math.min(constraints.maxWidth - 40, 420.0);
    final cardHeight = (size.height * .43).clamp(290.0, 360.0);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        children: [
          const SizedBox(height: 14),
          _brandPill(context),
          const SizedBox(height: 16),
          ClipRect(
            child: SizedBox(
              height: cardHeight + 22,
              child: Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.hardEdge,
                children: [
                  _backCard(2, cardWidth, cardHeight, .88, 18, .28),
                  _backCard(1, cardWidth, cardHeight, .94, 9, .52),
                  _frontCard(cardWidth, cardHeight),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_slides.length, (i) {
              final active = i == _index;
              return Semantics(
                button: true,
                selected: active,
                label: 'Overview ${i + 1}',
                child: InkWell(
                  onTap: () => _goTo(i),
                  borderRadius: BorderRadius.circular(99),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    width: active ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(99),
                      gradient: active
                          ? LinearGradient(colors: [_slides[_index].start, _slides[_index].end])
                          : null,
                      color: active ? null : AppTheme.border(context),
                    ),
                  ),
                ),
              );
            }),
          ),
          Text(
            'Swipe the cards or select a step',
            style: TextStyle(
              color: AppTheme.textSecondary(context),
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: cardWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _primaryAction(
                      context,
                      label: 'Get Started — Create Account',
                      icon: Icons.person_add_alt_1_outlined,
                      onTap: () => context.go('/signup'),
                    ),
                    const SizedBox(height: 10),
                    _secondaryAction(
                      context,
                      label: 'I Already Have an Account',
                      icon: Icons.login_outlined,
                      onTap: () => context.go('/login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktop(BuildContext context, BoxConstraints constraints) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1380),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 4,
                child: GlassPanel(
                  radius: 28,
                  blur: 22,
                  padding: const EdgeInsets.all(30),
                  borderColor: AppColors.orange.withValues(alpha: .20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _brandPill(context),
                      const SizedBox(height: 24),
                      ShaderMask(
                        shaderCallback: (rect) => const LinearGradient(
                          colors: [AppColors.orange, AppColors.red],
                        ).createShader(rect),
                        child: const Text(
                          'PyroGuard',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 46,
                            height: 1.02,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Home Monitoring & Security',
                        style: TextStyle(
                          color: AppTheme.textPrimary(context),
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'A responsive home-security workspace that connects realtime sensing, security controls, camera evidence, emergency information and traceable records.',
                        style: TextStyle(
                          color: AppTheme.textSecondary(context),
                          fontSize: 14,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 30),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _primaryAction(
                              context,
                              label: 'Get Started — Create Account',
                              icon: Icons.person_add_alt_1_outlined,
                              onTap: () => context.go('/signup'),
                            ),
                            const SizedBox(height: 10),
                            _secondaryAction(
                              context,
                              label: 'I Already Have an Account',
                              icon: Icons.login_outlined,
                              onTap: () => context.go('/login'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 28),
              Expanded(
                flex: 6,
                child: LayoutBuilder(
                  builder: (context, grid) {
                    final width = (grid.maxWidth - 14) / 2;
                    return Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        for (final slide in _slides)
                          SizedBox(
                            width: width,
                            child: _DesktopFeatureCard(slide: slide),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _brandPill(BuildContext context) {
    return GlassPanel(
      radius: 18,
      blur: 14,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PyroGuardLogo(),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PYROGUARD',
                style: TextStyle(
                  color: AppTheme.textPrimary(context),
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
              Text(
                'Home Monitoring & Security',
                style: TextStyle(
                  color: AppTheme.textSecondary(context),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _backCard(
    int offset,
    double width,
    double height,
    double scale,
    double yOffset,
    double opacity,
  ) {
    final slide = _slides[(_index + offset) % _slides.length];
    return Positioned(
      top: yOffset,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.bottomCenter,
        child: Opacity(
          opacity: opacity,
          child: Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [slide.start, slide.end]),
              borderRadius: BorderRadius.circular(24),
            ),
          ),
        ),
      ),
    );
  }

  Widget _frontCard(double width, double height) {
    final slide = _slides[_index];
    final opacity = (1 - _offset.abs() / 390).clamp(.52, 1.0);
    return Positioned(
      top: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: _onPanStart,
        onHorizontalDragUpdate: _onPanUpdate,
        onHorizontalDragEnd: _onPanEnd,
        child: Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(_offset, 0),
            child: Container(
              width: width,
              height: height,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [slide.start, slide.end],
                ),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: .18)),
                boxShadow: [
                  BoxShadow(
                    color: slide.glow,
                    blurRadius: 30,
                    spreadRadius: 1,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .24),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(99),
                          border: Border.all(color: Colors.white.withValues(alpha: .22)),
                        ),
                        child: Text(
                          slide.badge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withValues(alpha: .22)),
                        ),
                        child: Icon(slide.icon, color: Colors.white, size: 29),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .24),
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(color: Colors.white.withValues(alpha: .15)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              slide.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: .80),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              slide.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                height: 1.08,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              slide.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: .90),
                                fontSize: 12,
                                height: 1.42,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: TextButton.icon(
                      onPressed: () => context.go('/login'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.black.withValues(alpha: .18),
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.skip_next_outlined, size: 16),
                      label: const Text('Skip'),
                    ),
                  ),
                  if (_dragging && _offset.abs() > 40)
                    Positioned(
                      top: 72,
                      left: 0,
                      right: 0,
                      child: Align(
                        alignment: _offset < 0 ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .25),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _offset < 0 ? 'NEXT' : 'BACK',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: .8,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _primaryAction(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      label: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(label),
      ),
    );
  }

  Widget _secondaryAction(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 19),
      label: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(label),
      ),
    );
  }
}

class _DesktopFeatureCard extends StatefulWidget {
  const _DesktopFeatureCard({required this.slide});
  final _Slide slide;

  @override
  State<_DesktopFeatureCard> createState() => _DesktopFeatureCardState();
}

class _DesktopFeatureCardState extends State<_DesktopFeatureCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final slide = widget.slide;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppTheme.card(context).withValues(alpha: _hover ? .88 : .72),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: (_hover ? slide.start : AppTheme.border(context)).withValues(alpha: _hover ? .40 : .75),
          ),
          boxShadow: _hover
              ? [BoxShadow(color: slide.glow, blurRadius: 24, offset: const Offset(0, 8))]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [slide.start, slide.end]),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(slide.icon, color: Colors.white, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    slide.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary(context),
                      fontSize: 15.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              slide.subtitle,
              style: TextStyle(
                color: AppTheme.statusForeground(context, slide.start),
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              slide.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textSecondary(context),
                fontSize: 12.2,
                height: 1.48,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
