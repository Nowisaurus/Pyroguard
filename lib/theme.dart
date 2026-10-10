import 'dart:ui';
import 'package:flutter/material.dart';

// ── PyroGuard Color Palette — Black / Red / Orange / Maroon ────────────
// This is the locked brand identity: a dark, glass "security control
// center" look. Blue is intentionally gone from the brand surface —
// it only survives as a neutral "info" tone deep in status utilities.
class AppColors {
  // Brand core
  static const black      = Color(0xFF05070A); // near-black base
  static const maroon      = Color(0xFF450A0A); // deep maroon — brand anchor
  static const maroonMid   = Color(0xFF7F1D1D); // maroon-red bridge
  static const red         = Color(0xFFDC2626); // primary brand red
  static const redBright   = Color(0xFFEF4444); // alert red
  static const redDeep     = Color(0xFFB91C1C); // critical red
  static const orange      = Color(0xFFF97316); // primary brand orange
  static const orangeDeep  = Color(0xFFC2410C); // burnt orange
  static const amber       = Color(0xFFF59E0B); // warning amber

  // Status (kept minimal — brand colors do most of the work)
  static const green  = Color(0xFF22C55E); // safe / normal
  static const blue   = Color(0xFF38BDF8); // neutral info only, used sparingly
  static const critical = Color(0xFFB91C1C);
  static const emergency = Color(0xFF7F1D1D);

  // Dark UI — the primary surface of the app
  static const darkBg      = Color(0xFF07090C);
  static const darkSurface = Color(0xFF0D0F13);
  static const darkCard    = Color(0xFF15100E); // warm near-black, maroon-tinted
  static const darkBorder  = Color(0xFF2A1B16);

  // Light UI (secondary — kept warm to match brand, not blue-neutral)
  static const lightBg      = Color(0xFFFFF8F3);
  static const lightSurface = Color(0xFFFFFCF9);
  static const lightCard    = Color(0xFFFFF3EA);
  static const lightBorder  = Color(0xFFF2CDBB);

  // Text - dark
  static const textPrimary   = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFFD7C1B7); // high-contrast warm secondary text
  static const textMuted     = Color(0xFFB99A8D); // readable muted text on dark glass

  // Text - light
  static const lightTextPrimary   = Color(0xFF1F0E09);
  static const lightTextSecondary = Color(0xFF644136); // darker for reliable light-mode contrast

  static const white       = Colors.white;
  static const transparent = Colors.transparent;
}

// ── Theme notifier (with SharedPreferences persistence) ───────────────
class ThemeNotifier extends ChangeNotifier {
  ThemeMode _mode;
  final dynamic _prefs; // SharedPreferences — dynamic to avoid import here

  ThemeNotifier({bool initialDark = true, dynamic prefs})
      : _mode = initialDark ? ThemeMode.dark : ThemeMode.light,
        _prefs = prefs;

  ThemeMode get mode => _mode;
  bool get isDark => _mode == ThemeMode.dark;

  void toggle() {
    _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    _prefs?.setBool('dark_mode', isDark);
    notifyListeners();
  }

  void setDark(bool dark) {
    _mode = dark ? ThemeMode.dark : ThemeMode.light;
    _prefs?.setBool('dark_mode', dark);
    notifyListeners();
  }
}

// ── Glassmorphism helpers ─────────────────────────────────────────────
// Two layers are offered:
//  1. GlassStyle — BoxDecoration for widgets that can't host a blur
//     (e.g. inside another ClipRRect, or where perf matters).
//  2. GlassPanel — a real widget using BackdropFilter(ImageFilter.blur)
//     for actual frosted-glass blur. Use GlassPanel wherever the panel
//     sits directly over the app background/other content.
class GlassStyle {
  static BoxDecoration glowCard(Color glowColor, {double radius = 16, bool light = false}) => BoxDecoration(
    gradient: light
        ? null
        : LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0.06), AppColors.darkCard.withValues(alpha: 0.55)],
          ),
    color: light ? AppColors.lightCard : null,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: glowColor.withValues(alpha: 0.35), width: 1),
    boxShadow: [
      BoxShadow(color: glowColor.withValues(alpha: 0.22), blurRadius: 26, spreadRadius: 1),
      BoxShadow(color: Colors.black.withValues(alpha: light ? 0.06 : 0.55), blurRadius: 30, offset: const Offset(0, 10)),
    ],
  );

  static BoxDecoration card({Color? border, double radius = 16, bool light = false}) => BoxDecoration(
    gradient: light
        ? null
        : LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Colors.white.withValues(alpha: 0.05), AppColors.darkCard.withValues(alpha: 0.6)],
          ),
    color: light ? AppColors.lightCard.withValues(alpha: 0.95) : null,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: border ?? (light ? AppColors.lightBorder : Colors.white.withValues(alpha: 0.08)), width: 1),
    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: light ? 0.08 : 0.45), blurRadius: 24, offset: const Offset(0, 8))],
  );

  /// Brand gradient used for hero surfaces (sidebar header, buttons, splash).
  static const brandGradient = LinearGradient(
    begin: Alignment.topLeft, end: Alignment.bottomRight,
    colors: [AppColors.orangeDeep, AppColors.red, AppColors.maroon],
    stops: [0.0, 0.55, 1.0],
  );

  static const emergencyGradient = LinearGradient(
    begin: Alignment.topCenter, end: Alignment.bottomCenter,
    colors: [AppColors.redDeep, AppColors.maroon],
  );
}

/// A true frosted-glass panel: blurred backdrop + translucent tint +
/// hairline border + soft ambient glow. This is the building block for
/// PyroGuard's "calm security" glassmorphism language.
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final double blur;
  final Color? tint;
  final Color? borderColor;
  final Color? glowColor;
  final EdgeInsetsGeometry? padding;
  final double borderWidth;

  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 20,
    this.blur = 18,
    this.tint,
    this.borderColor,
    this.glowColor,
    this.padding,
    this.borderWidth = 1,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = AppTheme.isDark(context);
    final effectiveTint = tint ??
        (isDark ? Colors.white.withValues(alpha: 0.055) : Colors.white.withValues(alpha: 0.82));
    final effectiveBorder = borderColor ??
        (isDark ? Colors.white.withValues(alpha: 0.09) : AppColors.lightBorder);

    Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: effectiveTint,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: effectiveBorder, width: borderWidth),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );

    content = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: content,
      ),
    );

    if (glowColor != null) {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [
            BoxShadow(color: glowColor!.withValues(alpha: 0.28), blurRadius: 30, spreadRadius: 0),
          ],
        ),
        child: content,
      );
    }

    return content;
  }
}


/// One canonical PyroGuard brand mark used everywhere in the application.
/// Keeping one asset and one physical size prevents headers, onboarding,
/// login, signup, tutorial and navigation from looking like different apps.
class PyroGuardLogo extends StatelessWidget {
  const PyroGuardLogo({super.key});

  static const double size = 48;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.orange.withValues(alpha: .30),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.orange.withValues(alpha: AppTheme.isDark(context) ? .16 : .10),
            blurRadius: 18,
            spreadRadius: 0,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/images/logo.jpg',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => DecoratedBox(
          decoration: const BoxDecoration(gradient: GlassStyle.brandGradient),
          child: Icon(
            Icons.shield_outlined,
            color: Colors.white,
            size: 26,
          ),
        ),
      ),
    );
  }
}

// ── App Theme ─────────────────────────────────────────────────────────
// ── App Theme ─────────────────────────────────────────────────────────
class AppTheme {
  static const _darkTextTheme = TextTheme(
    displayLarge: TextStyle(color: AppColors.textPrimary),
    displayMedium: TextStyle(color: AppColors.textPrimary),
    displaySmall: TextStyle(color: AppColors.textPrimary),
    headlineLarge: TextStyle(color: AppColors.textPrimary),
    headlineMedium: TextStyle(color: AppColors.textPrimary),
    headlineSmall: TextStyle(color: AppColors.textPrimary),
    bodyLarge: TextStyle(color: AppColors.textPrimary),
    bodyMedium: TextStyle(color: AppColors.textPrimary),
    bodySmall: TextStyle(color: AppColors.textSecondary),
    titleLarge: TextStyle(color: AppColors.textPrimary),
    titleMedium: TextStyle(color: AppColors.textPrimary),
    titleSmall: TextStyle(color: AppColors.textPrimary),
    labelLarge: TextStyle(color: AppColors.textPrimary),
    labelMedium: TextStyle(color: AppColors.textSecondary),
    labelSmall: TextStyle(color: AppColors.textSecondary),
  );

  static const _lightTextTheme = TextTheme(
    displayLarge: TextStyle(color: AppColors.lightTextPrimary),
    displayMedium: TextStyle(color: AppColors.lightTextPrimary),
    displaySmall: TextStyle(color: AppColors.lightTextPrimary),
    headlineLarge: TextStyle(color: AppColors.lightTextPrimary),
    headlineMedium: TextStyle(color: AppColors.lightTextPrimary),
    headlineSmall: TextStyle(color: AppColors.lightTextPrimary),
    bodyLarge: TextStyle(color: AppColors.lightTextPrimary),
    bodyMedium: TextStyle(color: AppColors.lightTextPrimary),
    bodySmall: TextStyle(color: AppColors.lightTextSecondary),
    titleLarge: TextStyle(color: AppColors.lightTextPrimary),
    titleMedium: TextStyle(color: AppColors.lightTextPrimary),
    titleSmall: TextStyle(color: AppColors.lightTextPrimary),
    labelLarge: TextStyle(color: AppColors.lightTextPrimary),
    labelMedium: TextStyle(color: AppColors.lightTextSecondary),
    labelSmall: TextStyle(color: AppColors.lightTextSecondary),
  );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.darkBg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.orange,
          secondary: AppColors.red,
          tertiary: AppColors.maroon,
          error: AppColors.redBright,
          surface: AppColors.darkSurface,
          onSurface: AppColors.textPrimary,
        ),
        fontFamily: 'Roboto',
        textTheme: _darkTextTheme,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
        ),
        listTileTheme: const ListTileThemeData(
          textColor: AppColors.textPrimary,
          iconColor: AppColors.textSecondary,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
                color: states.contains(WidgetState.selected)
                    ? AppColors.orange
                    : AppColors.textSecondary,
                fontSize: 11,
                fontWeight: states.contains(WidgetState.selected)
                    ? FontWeight.w800
                    : FontWeight.w600,
              )),
          iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
                color: states.contains(WidgetState.selected)
                    ? AppColors.orange
                    : AppColors.textSecondary,
              )),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.orangeDeep,
            foregroundColor: AppColors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            elevation: 0,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF17110E).withValues(alpha: .92),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: AppColors.orange, width: 2),
          ),
          errorBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: AppColors.redBright),
          ),
          labelStyle: const TextStyle(color: AppColors.textSecondary),
          hintStyle: const TextStyle(color: AppColors.textMuted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        cardColor: AppColors.darkCard,
        dividerColor: AppColors.darkBorder,
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.darkSurface,
          titleTextStyle: TextStyle(color: AppColors.textPrimary, fontSize: 20, fontWeight: FontWeight.w800),
          contentTextStyle: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF221713),
          contentTextStyle: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
          actionTextColor: AppColors.orange,
        ),
        tooltipTheme: const TooltipThemeData(
          decoration: BoxDecoration(color: Color(0xFF221713), borderRadius: BorderRadius.all(Radius.circular(8))),
          textStyle: TextStyle(color: AppColors.textPrimary, fontSize: 12),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: AppColors.darkSurface,
          textStyle: TextStyle(color: AppColors.textPrimary),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.darkSurface,
          modalBackgroundColor: AppColors.darkSurface,
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orangeDeep : AppColors.darkSurface),
          checkColor: const WidgetStatePropertyAll(Colors.white),
          side: const BorderSide(color: AppColors.textSecondary),
        ),
        radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orangeDeep : AppColors.textSecondary),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? Colors.white : AppColors.textSecondary),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orange : AppColors.darkBorder),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.orange),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.darkBorder),
          ),
        ),
      );

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.lightBg,
        colorScheme: const ColorScheme.light(
          primary: AppColors.orangeDeep,
          secondary: AppColors.redDeep,
          tertiary: AppColors.maroon,
          error: AppColors.redDeep,
          surface: AppColors.lightSurface,
          onSurface: AppColors.lightTextPrimary,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
        ),
        fontFamily: 'Roboto',
        textTheme: _lightTextTheme,
        iconTheme: const IconThemeData(color: AppColors.lightTextPrimary),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.lightTextPrimary,
          elevation: 0,
        ),
        listTileTheme: const ListTileThemeData(
          textColor: AppColors.lightTextPrimary,
          iconColor: AppColors.lightTextSecondary,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
                color: states.contains(WidgetState.selected)
                    ? AppColors.orangeDeep
                    : AppColors.lightTextSecondary,
                fontSize: 11,
                fontWeight: states.contains(WidgetState.selected)
                    ? FontWeight.w800
                    : FontWeight.w600,
              )),
          iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
                color: states.contains(WidgetState.selected)
                    ? AppColors.orangeDeep
                    : AppColors.lightTextSecondary,
              )),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.orangeDeep,
            foregroundColor: AppColors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            elevation: 0,
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: .94),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.lightBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.lightBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.orangeDeep, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.redDeep),
          ),
          labelStyle: const TextStyle(color: AppColors.lightTextSecondary),
          hintStyle: TextStyle(color: AppColors.lightTextSecondary.withValues(alpha: .75)),
          prefixIconColor: AppColors.lightTextSecondary,
          suffixIconColor: AppColors.lightTextSecondary,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        cardColor: AppColors.lightCard,
        dividerColor: AppColors.lightBorder,
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.lightSurface,
          titleTextStyle: TextStyle(color: AppColors.lightTextPrimary, fontSize: 20, fontWeight: FontWeight.w800),
          contentTextStyle: TextStyle(color: AppColors.lightTextSecondary, fontSize: 14),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF3A1E15),
          contentTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          actionTextColor: Color(0xFFFFC59A),
        ),
        tooltipTheme: const TooltipThemeData(
          decoration: BoxDecoration(color: Color(0xFF3A1E15), borderRadius: BorderRadius.all(Radius.circular(8))),
          textStyle: TextStyle(color: Colors.white, fontSize: 12),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          color: AppColors.lightSurface,
          textStyle: TextStyle(color: AppColors.lightTextPrimary),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: AppColors.lightSurface,
          modalBackgroundColor: AppColors.lightSurface,
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orangeDeep : Colors.white),
          checkColor: const WidgetStatePropertyAll(Colors.white),
          side: const BorderSide(color: AppColors.lightTextSecondary),
        ),
        radioTheme: RadioThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orangeDeep : AppColors.lightTextSecondary),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? Colors.white : AppColors.lightTextSecondary),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? AppColors.orangeDeep : AppColors.lightBorder),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: AppColors.orangeDeep),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.lightTextPrimary,
            side: const BorderSide(color: AppColors.lightBorder),
          ),
        ),
      );

  static bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;
  static Color bg(BuildContext context) => isDark(context) ? AppColors.darkBg : AppColors.lightBg;
  static Color surface(BuildContext context) => isDark(context) ? AppColors.darkSurface : AppColors.lightSurface;
  static Color card(BuildContext context) => isDark(context) ? AppColors.darkCard : AppColors.lightCard;
  static Color border(BuildContext context) => isDark(context) ? AppColors.darkBorder : AppColors.lightBorder;
  static Color textPrimary(BuildContext context) => isDark(context) ? AppColors.textPrimary : AppColors.lightTextPrimary;
  static Color textSecondary(BuildContext context) => isDark(context) ? AppColors.textSecondary : AppColors.lightTextSecondary;
  static Color fillColor(BuildContext context) => isDark(context) ? const Color(0xFF1A1410) : Colors.white.withValues(alpha: .94);

  /// Brand/status foreground colors are deepened in light mode so labels and
  /// numbers remain readable on warm light surfaces while preserving the same
  /// orange/red/maroon/green visual identity.
  static Color brandForeground(BuildContext context) => isDark(context) ? AppColors.orange : AppColors.orangeDeep;
  static Color safeForeground(BuildContext context) => isDark(context) ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
  static Color warningForeground(BuildContext context) => isDark(context) ? AppColors.amber : const Color(0xFF9A6700);
  static Color dangerForeground(BuildContext context) => isDark(context) ? AppColors.redBright : AppColors.redDeep;

  static Color statusForeground(BuildContext context, Color color) {
    if (isDark(context)) return color;
    if (color == AppColors.green) return safeForeground(context);
    if (color == AppColors.amber) return warningForeground(context);
    if (color == AppColors.orange) return brandForeground(context);
    if (color == AppColors.red || color == AppColors.redBright) return dangerForeground(context);
    return color;
  }

  static BoxDecoration ambientBackground(BuildContext context) => BoxDecoration(
        color: bg(context),
        gradient: RadialGradient(
          center: const Alignment(-0.75, -0.9),
          radius: 1.45,
          colors: isDark(context)
              ? [AppColors.orange.withValues(alpha: .16), AppColors.darkBg.withValues(alpha: .0)]
              : [AppColors.orange.withValues(alpha: .12), AppColors.lightBg.withValues(alpha: .0)],
        ),
      );
}

/// Shared application background. The Phoenix is deliberately visible behind
/// the glass panels in both themes, while a soft overlay preserves text contrast.
class PhoenixBackdrop extends StatelessWidget {
  const PhoenixBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark(context);
    final size = MediaQuery.sizeOf(context);
    // The Phoenix uses one deterministic viewport-relative size/position on
    // every normal application screen. Individual pages must not add their
    // own Phoenix layer; this keeps the background fixed while content scrolls.
    final phoenixSize = (size.shortestSide * 1.10).clamp(430.0, 860.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: AppTheme.bg(context)),
        IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: SizedBox.square(
              dimension: phoenixSize,
              child: Opacity(
                opacity: dark ? .16 : .095,
                child: Image.asset(
                  'assets/images/logo_phoenix.png',
                  fit: BoxFit.contain,
                  alignment: Alignment.center,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? [
                        AppColors.darkBg.withValues(alpha: .10),
                        AppColors.darkBg.withValues(alpha: .38),
                      ]
                    : [
                        Colors.white.withValues(alpha: .18),
                        AppColors.lightBg.withValues(alpha: .34),
                      ],
              ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(decoration: AppTheme.ambientBackground(context)),
        ),
        child,
      ],
    );
  }
}

class AmbientBackdrop extends StatelessWidget {
  final Widget child;
  const AmbientBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) => PhoenixBackdrop(child: child);
}
