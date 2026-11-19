import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import '../services/mjpeg_live_feed.dart';

/// Paints the newest frame of an MJPEG feed smoothly.
///
/// * Decoding is latest-wins: while one JPEG decodes, newer frames replace
///   the pending one, so a slow phone drops frames instead of lagging behind.
/// * Frames bypass Flutter's ImageCache (Image.memory cached every frame).
/// * Only this widget repaints for a new frame, not the whole screen.
/// * A screen hidden under another route stops decoding until visible again.
/// * During a brief reconnect the last picture is held for [holdLastFrame]
///   instead of flashing the placeholder.
class MjpegFrameView extends StatefulWidget {
  const MjpegFrameView({
    super.key,
    required this.feed,
    required this.placeholder,
    this.fallback,
    this.fit = BoxFit.contain,
    this.holdLastFrame = const Duration(seconds: 3),
  });

  /// Live stream; null when the camera is switched off.
  final MjpegLiveFeed? feed;

  /// Still JPEG (from /capture) shown only while the stream is not live.
  final Uint8List? fallback;

  final Widget placeholder;
  final BoxFit fit;
  final Duration holdLastFrame;

  @override
  State<MjpegFrameView> createState() => _MjpegFrameViewState();
}

class _MjpegFrameViewState extends State<MjpegFrameView> {
  ui.Image? _image;
  Uint8List? _shown;
  Uint8List? _pending;
  bool _decoding = false;
  bool _disposed = false;
  bool _visible = true;
  Timer? _clearTimer;

  @override
  void initState() {
    super.initState();
    widget.feed?.addListener(_onSource);
    _onSource();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // False while another route covers this one.
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible != _visible) {
      _visible = visible;
      if (visible) _onSource();
    }
  }

  @override
  void didUpdateWidget(covariant MjpegFrameView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed?.removeListener(_onSource);
      widget.feed?.addListener(_onSource);
    }
    if (!identical(oldWidget.feed, widget.feed) ||
        !identical(oldWidget.fallback, widget.fallback)) {
      _onSource();
    }
  }

  Uint8List? get _sourceBytes {
    final feed = widget.feed;
    if (feed != null && feed.connected && feed.frame != null) {
      return feed.frame;
    }
    return widget.fallback;
  }

  void _onSource() {
    if (_disposed) return;
    final bytes = _sourceBytes;
    if (bytes == null) {
      // Hold the last picture briefly so a quick reconnect does not flicker.
      if (_image != null && _clearTimer == null) {
        _clearTimer = Timer(widget.holdLastFrame, () {
          _clearTimer = null;
          if (_disposed || _sourceBytes != null) return;
          final old = _image;
          setState(() {
            _image = null;
            _shown = null;
          });
          old?.dispose();
        });
      }
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    if (!_visible) return;
    if (identical(bytes, _shown) || identical(bytes, _pending)) return;
    _pending = bytes;
    if (!_decoding) _decodeLoop();
  }

  Future<void> _decodeLoop() async {
    _decoding = true;
    while (_pending != null && !_disposed) {
      final bytes = _pending!;
      _pending = null;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frameInfo = await codec.getNextFrame();
        codec.dispose();
        if (_disposed) {
          frameInfo.image.dispose();
          break;
        }
        final old = _image;
        setState(() {
          _image = frameInfo.image;
          _shown = bytes;
        });
        // RawImage hands the render object its own clone, so releasing our
        // handle to the previous frame is safe.
        old?.dispose();
      } catch (_) {
        // A damaged JPEG is skipped; the next frame replaces it.
      }
    }
    _decoding = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _clearTimer?.cancel();
    widget.feed?.removeListener(_onSource);
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) return widget.placeholder;
    return RepaintBoundary(
      child: SizedBox.expand(
        child: RawImage(
          image: image,
          fit: widget.fit,
          // Smooth (bilinear + mipmaps) scaling keeps the enlarged picture
          // crisp instead of blocky.
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
