import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

enum PgNoticeKind { info, success, warning, error, fire, intrusion, device }

class _Notice {
  _Notice(this.id, this.kind, this.title, this.message, this.duration, this.actionLabel, this.onAction);
  final int id;
  final PgNoticeKind kind;
  final String title;
  final String message;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// App notifications shown at the TOP of the screen like a phone's heads-up
/// notification (logo, app name, "now", title and message, glass card),
/// instead of a colored bar at the bottom. Works from anywhere, no context
/// needed. Swipe up or tap the card to dismiss.
class PgNotice {
  PgNotice._();
  static final ValueNotifier<_Notice?> _current = ValueNotifier(null);
  static int _seq = 0;
  static Timer? _timer;

  static void show(
    String message, {
    PgNoticeKind kind = PgNoticeKind.info,
    String? title,
    Duration? duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final text = message.replaceFirst(RegExp(r'^(Exception|StateError|Bad state): '), '').trim();
    final d = duration ??
        switch (kind) {
          PgNoticeKind.fire || PgNoticeKind.intrusion => const Duration(seconds: 12),
          PgNoticeKind.error || PgNoticeKind.warning => const Duration(seconds: 6),
          _ => const Duration(seconds: 4),
        };
    _timer?.cancel();
    _current.value = _Notice(++_seq, kind, title ?? _defaultTitle(kind), text, d, actionLabel, onAction);
    _timer = Timer(d, hide);
  }

  static void hide() {
    _timer?.cancel();
    _current.value = null;
  }

  static String _defaultTitle(PgNoticeKind k) => switch (k) {
        PgNoticeKind.success => 'Done',
        PgNoticeKind.warning => 'Attention',
        PgNoticeKind.error => 'Something went wrong',
        PgNoticeKind.fire => 'Fire alert',
        PgNoticeKind.intrusion => 'Security alert',
        PgNoticeKind.device => 'Device status',
        PgNoticeKind.info => 'PyroGuard',
      };

  /// Picks error / warning / info from the wording of an existing message.
  static PgNoticeKind guess(String message) {
    final m = message.toLowerCase();
    if (RegExp(r"could not|couldn't|failed|error|unavailable|not available|invalid|denied|blocked").hasMatch(m)) {
      return PgNoticeKind.error;
    }
    if (RegExp(r'only the|first|please|not a confirmed|pending|still|try again').hasMatch(m)) {
      return PgNoticeKind.warning;
    }
    if (RegExp(r'sent|saved|submitted|done|allowed').hasMatch(m)) return PgNoticeKind.success;
    return PgNoticeKind.info;
  }
}

/// Put once around the app (MaterialApp builder) so notices float above
/// every page and dialog.
class PgNoticeHost extends StatelessWidget {
  const PgNoticeHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: ValueListenableBuilder<_Notice?>(
            valueListenable: PgNotice._current,
            builder: (context, n, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (w, a) => SlideTransition(
                position: Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(a),
                child: FadeTransition(opacity: a, child: w),
              ),
              child: n == null ? const SizedBox.shrink(key: ValueKey(0)) : _NoticeCard(key: ValueKey(n.id), notice: n),
            ),
          ),
        ),
      ]);
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({super.key, required this.notice});
  final _Notice notice;

  (Color, IconData) get _style => switch (notice.kind) {
        PgNoticeKind.success => (AppColors.green, Icons.check_circle_outline),
        PgNoticeKind.warning => (AppColors.amber, Icons.warning_amber_rounded),
        PgNoticeKind.error => (AppColors.red, Icons.error_outline),
        PgNoticeKind.fire => (AppColors.red, Icons.local_fire_department),
        PgNoticeKind.intrusion => (AppColors.redDeep, Icons.sensor_door_outlined),
        PgNoticeKind.device => (const Color(0xFF3B82F6), Icons.developer_board_outlined),
        PgNoticeKind.info => (AppColors.orange, Icons.notifications_none_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (color, icon) = _style;
    final primary = dark ? Colors.white : const Color(0xFF1F1410);
    final secondary = dark ? Colors.white70 : const Color(0xFF5B4A42);
    final width = MediaQuery.sizeOf(context).width;

    return SafeArea(
      bottom: false,
      child: Align(
        alignment: width >= 700 ? Alignment.topRight : Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Dismissible(
              key: ValueKey('notice-${notice.id}'),
              direction: DismissDirection.up,
              onDismissed: (_) => PgNotice.hide(),
              child: Material(
                type: MaterialType.transparency,
                child: GestureDetector(
                  onTap: () {
                    PgNotice.hide();
                    notice.onAction?.call();
                  },
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        decoration: BoxDecoration(
                          color: (dark ? AppColors.darkCard : Colors.white).withValues(alpha: dark ? .88 : .92),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: color.withValues(alpha: .45)),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: dark ? .45 : .14), blurRadius: 24, offset: const Offset(0, 8)),
                          ],
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          // App row, like a phone notification header.
                          Row(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: Image.asset('assets/images/logo_phoenix.png', width: 18, height: 18, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.local_fire_department, size: 18, color: AppColors.orange)),
                            ),
                            const SizedBox(width: 6),
                            Text('PyroGuard', style: TextStyle(color: secondary, fontSize: 11.5, fontWeight: FontWeight.w700)),
                            Text('  ·  now', style: TextStyle(color: secondary, fontSize: 11.5)),
                            const Spacer(),
                            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                          ]),
                          const SizedBox(height: 8),
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
                              child: Icon(icon, color: color, size: 20),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(notice.title,
                                    style: TextStyle(color: primary, fontWeight: FontWeight.w800, fontSize: 13.5)),
                                const SizedBox(height: 2),
                                Text(notice.message,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: secondary, fontSize: 12.5, height: 1.35)),
                              ]),
                            ),
                            if (notice.actionLabel != null) ...[
                              const SizedBox(width: 8),
                              TextButton(
                                style: TextButton.styleFrom(foregroundColor: color, visualDensity: VisualDensity.compact),
                                onPressed: () {
                                  PgNotice.hide();
                                  notice.onAction?.call();
                                },
                                child: Text(notice.actionLabel!, style: const TextStyle(fontWeight: FontWeight.w800)),
                              ),
                            ],
                          ]),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
