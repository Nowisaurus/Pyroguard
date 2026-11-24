// Web builds: the browser's own <img> plays the camera's MJPEG stream,
// smoothly and without buffering the endless response in Dart.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

final Set<String> _registered = {};

Widget webMjpegImage(String url, BoxFit fit) {
  final objectFit = fit == BoxFit.cover ? 'cover' : 'contain';
  final viewType = 'pg-mjpeg-$objectFit-${url.hashCode}';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final img = html.ImageElement()
        ..src = url
        ..alt = 'Camera 1 live video';
      img.style
        ..width = '100%'
        ..height = '100%'
        ..objectFit = objectFit
        ..backgroundColor = '#000'
        ..pointerEvents = 'none';
      return img;
    });
  }
  return HtmlElementView(key: ValueKey(viewType), viewType: viewType);
}
