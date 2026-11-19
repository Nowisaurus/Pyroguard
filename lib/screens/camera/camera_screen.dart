import 'dart:ui';
import 'package:flutter/material.dart';
import '../../responsive.dart';
import '../../theme.dart';
import '../../widgets/dual_camera_overview.dart';
import '../../widgets/camera_dashboard_summary.dart';
import '../../widgets/motion_events_panel.dart';

/// Unified camera dashboard. The former Camera 1 legacy view is intentionally removed.
///
/// Layout is chosen from the width actually available to this page (after the
/// sidebar), so it adapts to phones, tablets, laptops and large monitors:
///
/// * Wide   (>= 1000 px): heading on top, then camera (left) and
///   Wi-Fi + motion panels (right) starting on the same line.
/// * Medium (600–999 px, tablets / small laptops): heading + camera full
///   width, then Wi-Fi and motion panels side by side underneath.
/// * Narrow (< 600 px, phones): everything stacked.
///
/// Everything lives in one scroll view, so the columns never move separately.
class CameraTab extends StatefulWidget {
  const CameraTab({super.key});

  @override
  State<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends State<CameraTab> {
  static const double _wideBreakpoint = 1000;
  static const double _mediumBreakpoint = 600;

  /// Height of the camera card (wide layout); the right column matches it.
  double _cameraHeight = 560;

  @override
  Widget build(BuildContext context) {
    final phone = Responsive.isPhone(context);
    final topGap = phone ? 16.0 : 24.0; // space below the "Security Cameras" bar
    final gap = phone ? 14.0 : 20.0; // space between cards / columns

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Security Cameras'),
        backgroundColor: AppTheme.bg(context).withValues(alpha: .83),
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: const SizedBox.expand(),
          ),
        ),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        top: false, // the app bar already handles the top inset
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            Responsive.horizontalPadding(context),
            topGap,
            Responsive.horizontalPadding(context),
            90,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Responsive.maxContentWidth(context)),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;

                  // ── Narrow: phones ─────────────────────────────────────
                  if (width < _mediumBreakpoint) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const DualCameraOverview(),
                        SizedBox(height: gap),
                        const CameraDashboardSummary(),
                        SizedBox(height: gap),
                        const MotionEventsPanel(maxListHeight: 360),
                      ],
                    );
                  }

                  // ── Medium: tablets / small laptops ────────────────────
                  if (width < _wideBreakpoint) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const LiveCameraHeader(),
                        SizedBox(height: gap),
                        const DualCameraOverview(showHeader: false),
                        SizedBox(height: gap),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Expanded(child: CameraDashboardSummary()),
                            SizedBox(width: gap),
                            const Expanded(
                                child: MotionEventsPanel(maxListHeight: 340)),
                          ],
                        ),
                      ],
                    );
                  }

                  // ── Wide: laptops / desktops / monitors ────────────────
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const LiveCameraHeader(),
                      SizedBox(height: gap),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _MeasureHeight(
                              onHeight: (h) {
                                if ((h - _cameraHeight).abs() > 1) {
                                  setState(() => _cameraHeight = h);
                                }
                              },
                              child: const DualCameraOverview(showHeader: false),
                            ),
                          ),
                          SizedBox(width: gap),
                          // Same height as the camera card: the motion list
                          // scrolls inside its panel instead of running past
                          // the bottom of the camera.
                          Expanded(
                            flex: 2,
                            child: SizedBox(
                              // never shorter than the summary + a few events
                              height: _cameraHeight < 480 ? 480 : _cameraHeight,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const CameraDashboardSummary(),
                                  SizedBox(height: gap),
                                  const Expanded(
                                    child: MotionEventsPanel(fill: true),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports its child's height after layout (used to match the motion panel
/// to the camera card).
class _MeasureHeight extends StatefulWidget {
  const _MeasureHeight({required this.child, required this.onHeight});
  final Widget child;
  final ValueChanged<double> onHeight;

  @override
  State<_MeasureHeight> createState() => _MeasureHeightState();
}

class _MeasureHeightState extends State<_MeasureHeight> {
  double? _last;

  void _report() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        final h = box.size.height;
        if (_last == null || (h - _last!).abs() > 1) {
          _last = h;
          widget.onHeight(h);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _report();
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _report();
        return true;
      },
      child: SizeChangedLayoutNotifier(child: widget.child),
    );
  }
}
