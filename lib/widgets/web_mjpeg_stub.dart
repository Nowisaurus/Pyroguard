import 'package:flutter/widgets.dart';

/// Phone / desktop builds: the MJPEG feed is decoded in Dart instead.
Widget webMjpegImage(String url, BoxFit fit) => const SizedBox.shrink();
