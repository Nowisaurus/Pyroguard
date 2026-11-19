import 'package:flutter/material.dart';
import '../theme.dart';

/// Colours for controls drawn over live video, taken only from the
/// PyroGuard palette in theme.dart (AppColors / GlassStyle).
///
/// Video overlays always use the dark glass style (warm maroon-tinted
/// near-black, like GlassStyle.card) so they stay readable on any picture.
class CameraOverlayStyle {
  CameraOverlayStyle._();

  /// Translucent glass fill (AppColors.darkCard).
  static Color glass([double alpha = .45]) =>
      AppColors.darkCard.withValues(alpha: alpha);

  /// Hairline border (AppColors.textPrimary, as GlassStyle uses white).
  static Color hairline([double alpha = .20]) =>
      AppColors.textPrimary.withValues(alpha: alpha);

  static const foreground = AppColors.textPrimary;
  static Color disabled([double alpha = .35]) =>
      AppColors.textPrimary.withValues(alpha: alpha);
  static const secondary = AppColors.textSecondary;

  static const accent = AppColors.orange;        // brand orange: active / PTZ ring
  static const accentDeep = AppColors.orangeDeep;
  static const live = AppColors.green;           // safe / connected
  static const warning = AppColors.amber;        // waiting / paused
  static const alert = AppColors.redBright;      // motion / recording dot
  static const emergency = AppColors.red;        // Call BFP, recording fill

  /// Brand gradient (orangeDeep → red → maroon) for the PTZ home button.
  static const brandGradient = GlassStyle.brandGradient;

  /// Soft text/icon shadow: AppColors.black at 80 %.
  static const shadow = [Shadow(color: Color(0xCC05070A), blurRadius: 6)];

  /// Scaffold background behind full-screen video.
  static const videoBackground = AppColors.black;
}
