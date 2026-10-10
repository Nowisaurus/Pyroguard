import 'package:flutter/material.dart';
import 'config/pyroguard_config.dart';

/// Centralized responsive helpers so every PyroGuard screen uses the same
/// breakpoints and content-width behavior.
class Responsive {
  Responsive._();

  static Size size(BuildContext context) => MediaQuery.sizeOf(context);

  static bool isCompact(BuildContext context) =>
      size(context).width < PyroGuardConfig.compactBreakpoint;

  static bool isPhone(BuildContext context) =>
      size(context).width < PyroGuardConfig.phoneBreakpoint;

  static bool isTablet(BuildContext context) {
    final w = size(context).width;
    return w >= PyroGuardConfig.phoneBreakpoint &&
        w < PyroGuardConfig.desktopBreakpoint;
  }

  static bool isDesktop(BuildContext context) =>
      size(context).width >= PyroGuardConfig.desktopBreakpoint;

  static double horizontalPadding(BuildContext context) {
    final w = size(context).width;
    if (w < 360) return 12;
    if (w < 600) return 16;
    if (w < 900) return 22;
    return 28;
  }

  static double maxContentWidth(BuildContext context) =>
      isDesktop(context) ? 1240 : 1040;

  static int gridColumns(
    BuildContext context, {
    int phone = 1,
    int tablet = 2,
    int desktop = 3,
  }) {
    final w = size(context).width;
    if (w >= PyroGuardConfig.desktopBreakpoint) return desktop;
    if (w >= PyroGuardConfig.phoneBreakpoint) return tablet;
    return phone;
  }

  static Widget page({
    required BuildContext context,
    required Widget child,
    EdgeInsetsGeometry? padding,
    double? maxWidth,
  }) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? maxContentWidth(context),
        ),
        child: Padding(
          padding: padding ??
              EdgeInsets.symmetric(horizontal: horizontalPadding(context)),
          child: child,
        ),
      ),
    );
  }
}
