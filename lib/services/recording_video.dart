import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/pyroguard_config.dart';

/// Turns a camera recording (JPEG frames) into one video file that plays in
/// VLC, Windows Media Player / Movies & TV and most phone players:
/// Motion-JPEG in an AVI container. Pure Dart, no extra packages.
class RecordingVideo {
  RecordingVideo._();

  /// Builds an MJPEG .avi from [frames] at [fps] frames per second.
  static Uint8List buildAvi(List<Uint8List> frames, {int fps = 1}) {
    if (frames.isEmpty) throw ArgumentError('No frames');
    if (fps < 1) fps = 1;
    if (fps > 30) fps = 30;
    final (w, h) = _jpegSize(frames.first) ?? (640, 480);
    final maxFrame = frames.fold<int>(0, (m, f) => f.length > m ? f.length : m);

    final b = BytesBuilder();
    void fourcc(String s) => b.add(s.codeUnits);
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v & 0xFFFFFFFF, Endian.little)).buffer.asUint8List());
    void u16(int v) => b.add((ByteData(2)..setUint16(0, v & 0xFFFF, Endian.little)).buffer.asUint8List());

    // Sizes (chunk payload sizes, without the 8-byte chunk header).
    const avihSize = 56, strhSize = 56, strfSize = 40;
    const strlSize = 4 + (8 + strhSize) + (8 + strfSize);
    const hdrlSize = 4 + (8 + avihSize) + (8 + strlSize);
    var moviData = 4;
    for (final f in frames) {
      moviData += 8 + f.length + (f.length.isOdd ? 1 : 0);
    }
    final idxSize = 16 * frames.length;
    final riffSize = 4 + (8 + hdrlSize) + (8 + moviData) + (8 + idxSize);

    fourcc('RIFF');
    u32(riffSize);
    fourcc('AVI ');

    fourcc('LIST');
    u32(hdrlSize);
    fourcc('hdrl');
    fourcc('avih');
    u32(avihSize);
    u32(1000000 ~/ fps); // microseconds per frame
    u32(maxFrame * fps); // max bytes per second
    u32(0); // padding granularity
    u32(0x10); // AVIF_HASINDEX
    u32(frames.length);
    u32(0); // initial frames
    u32(1); // streams
    u32(maxFrame);
    u32(w);
    u32(h);
    u32(0);
    u32(0);
    u32(0);
    u32(0);

    fourcc('LIST');
    u32(strlSize);
    fourcc('strl');
    fourcc('strh');
    u32(strhSize);
    fourcc('vids');
    fourcc('MJPG');
    u32(0); // flags
    u16(0); // priority
    u16(0); // language
    u32(0); // initial frames
    u32(1); // scale
    u32(fps); // rate
    u32(0); // start
    u32(frames.length); // length
    u32(maxFrame); // suggested buffer
    u32(0xFFFFFFFF); // quality
    u32(0); // sample size
    u16(0);
    u16(0);
    u16(w);
    u16(h);
    fourcc('strf');
    u32(strfSize);
    u32(40);
    u32(w);
    u32(h);
    u16(1); // planes
    u16(24); // bit count
    fourcc('MJPG');
    u32(w * h * 3);
    u32(0);
    u32(0);
    u32(0);
    u32(0);

    fourcc('LIST');
    u32(moviData);
    fourcc('movi');
    final offsets = <int>[];
    var offset = 4; // relative to the 'movi' fourcc
    for (final f in frames) {
      offsets.add(offset);
      fourcc('00dc');
      u32(f.length);
      b.add(f);
      if (f.length.isOdd) b.addByte(0);
      offset += 8 + f.length + (f.length.isOdd ? 1 : 0);
    }

    fourcc('idx1');
    u32(idxSize);
    for (var i = 0; i < frames.length; i++) {
      fourcc('00dc');
      u32(0x10); // keyframe
      u32(offsets[i]);
      u32(frames[i].length);
    }
    return b.toBytes();
  }

  /// Width and height from a JPEG's SOF marker.
  static (int, int)? _jpegSize(Uint8List j) {
    var i = 2;
    while (i + 9 < j.length) {
      if (j[i] != 0xFF) {
        i++;
        continue;
      }
      final m = j[i + 1];
      if (m >= 0xC0 && m <= 0xC3) {
        final h = (j[i + 5] << 8) | j[i + 6];
        final w = (j[i + 7] << 8) | j[i + 8];
        return (w, h);
      }
      final len = (j[i + 2] << 8) | j[i + 3];
      i += 2 + len;
    }
    return null;
  }

  /// Downloads the recording's frames, builds the video, stores it next to
  /// the frames in Supabase Storage and returns its public URL.
  static Future<String> buildAndStore(List<String> frameUrls, String folder, {int fps = 1}) async {
    final frames = <Uint8List>[];
    for (final u in frameUrls) {
      final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200 && r.bodyBytes.length > 4) frames.add(r.bodyBytes);
    }
    return store(frames, folder, fps: fps);
  }

  static Future<String> store(List<Uint8List> frames, String folder, {int fps = 1}) async {
    final avi = buildAvi(frames, fps: fps);
    final storage = Supabase.instance.client.storage.from(PyroGuardConfig.incidentMediaBucket);
    final path = '$folder/recording.avi';
    try {
      await storage.uploadBinary(path, avi,
          fileOptions: const FileOptions(contentType: 'video/x-msvideo'));
    } on StorageException catch (e) {
      // Already built earlier (files cannot be overwritten): reuse it.
      if (!'${e.statusCode} ${e.message}'.contains('409') &&
          !e.message.toLowerCase().contains('exists')) {
        rethrow;
      }
    }
    return storage.getPublicUrl(path);
  }

  /// Opens the file with "download" so the browser saves it.
  static Future<bool> download(String url, String fileName) {
    final u = Uri.parse(url);
    final withName = u.replace(queryParameters: {...u.queryParameters, 'download': fileName});
    return launchUrl(withName, mode: LaunchMode.externalApplication);
  }

  /// Storage folder of a recording from its first frame URL
  /// (.../incident-media/<folder>/000.jpg).
  static String? folderOf(String frameUrl) {
    final marker = '/${PyroGuardConfig.incidentMediaBucket}/';
    final i = frameUrl.indexOf(marker);
    if (i < 0) return null;
    final rest = frameUrl.substring(i + marker.length);
    final slash = rest.lastIndexOf('/');
    return slash < 0 ? null : rest.substring(0, slash);
  }
}
