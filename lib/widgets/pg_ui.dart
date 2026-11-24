import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Shared look for PyroGuard panels, so every page uses the same glass card,
/// header, colors and spacing as the original dashboard panels
/// (GlassStyle.card + outlined orange icon + 17 pt bold title).
class PgCard extends StatelessWidget {
  const PgCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.accent});
  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Border color; red during an alarm. Defaults to the normal glass border.
  final Color? accent;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: GlassStyle.card(
          light: !AppTheme.isDark(context),
          border: accent?.withValues(alpha: .55),
        ),
        child: child,
      );
}

/// Panel header: one outlined icon, title, optional subtitle and actions.
class PgHeader extends StatelessWidget {
  const PgHeader({super.key, required this.icon, required this.title, this.subtitle, this.actions = const []});
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: AppColors.orange, size: 19),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: AppTheme.textPrimary(context))),
          ),
          ...actions,
        ]),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text(subtitle!, style: TextStyle(fontSize: 12, color: AppTheme.textSecondary(context), height: 1.35)),
          ),
      ]);
}

/// Small rounded status label (same style as the room sensor cards).
class PgBadge extends StatelessWidget {
  const PgBadge(this.text, {super.key, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
        child: Text(text,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: AppTheme.statusForeground(context, color))),
      );
}

/// Inner tile used inside a PgCard (lighter glass, same as the sensor cells).
class PgTile extends StatelessWidget {
  const PgTile({super.key, required this.child, this.color, this.padding = const EdgeInsets.all(10), this.onTap});
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color?.withValues(alpha: .08) ??
            const Color(0xFFFFF9F5).withValues(alpha: AppTheme.isDark(context) ? .20 : .24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (color ?? AppTheme.border(context)).withValues(alpha: color == null ? 1 : .35)),
      ),
      child: child,
    );
    return onTap == null ? tile : InkWell(borderRadius: BorderRadius.circular(10), onTap: onTap, child: tile);
  }
}

/// Small 8 px colored dot used instead of extra icons in lists.
class PgDot extends StatelessWidget {
  const PgDot(this.color, {super.key, this.size = 9});
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}


/// Centered frosted-glass dialog used by Evidence, Recordings and incident
/// details: blurred glass with a near-solid surface so text stays readable
/// on top of any page, orange glass border, icon + title + close button.
class PgGlassDialog extends StatelessWidget {
  const PgGlassDialog({
    super.key,
    required this.title,
    required this.child,
    this.icon = Icons.info_outline_rounded,
    this.subtitle,
    this.accent = AppColors.orange,
    this.maxWidth = 720,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color accent;
  final double maxWidth;
  final Widget child;
  final List<Widget> actions;

  /// Shows [dialog] over a soft dark blur of the page.
  static Future<T?> show<T>(BuildContext context, Widget dialog) => showDialog<T>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: .45),
        builder: (_) => dialog,
      );

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final primary = AppTheme.textPrimary(context);
    final secondary = AppTheme.textSecondary(context);
    final radius = BorderRadius.circular(22);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: MediaQuery.sizeOf(context).height * .88),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark
                      ? [const Color(0xFF2A1A16).withValues(alpha: .94), AppColors.darkCard.withValues(alpha: .96)]
                      : [Colors.white.withValues(alpha: .95), const Color(0xFFFFF4EE).withValues(alpha: .94)],
                ),
                border: Border.all(color: accent.withValues(alpha: .45)),
                boxShadow: [
                  BoxShadow(color: accent.withValues(alpha: .18), blurRadius: 28, spreadRadius: 1),
                  BoxShadow(color: Colors.black.withValues(alpha: dark ? .5 : .12), blurRadius: 30, offset: const Offset(0, 12)),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 8, 10),
                  child: Row(children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(11),
                        border: Border.all(color: accent.withValues(alpha: .35)),
                      ),
                      child: Icon(icon, color: AppTheme.statusForeground(context, accent), size: 19),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: primary, fontSize: 16.5, fontWeight: FontWeight.w900)),
                        if (subtitle != null)
                          Text(subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: secondary, fontSize: 11.5, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                    ...actions,
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: primary),
                    ),
                  ]),
                ),
                Divider(height: 1, color: accent.withValues(alpha: .18)),
                Flexible(child: child),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
