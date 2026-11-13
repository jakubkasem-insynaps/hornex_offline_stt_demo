import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the app keeps things on disk.
class AppPaths {
  AppPaths._(this.models, this.recordings, this.testSets, this.exports, this.data);

  /// Downloaded offline models: `<models>/<model id>/<file>`.
  final Directory models;

  /// Saved original recordings (WAV, 16 kHz mono).
  final Directory recordings;

  /// Benchmark test sets: `<testSets>/<name>/{clip.wav, clip.txt}`.
  /// On Android this is under the app's external files directory so sets can
  /// also be copied in with `adb push`.
  final Directory testSets;

  final Directory exports;

  /// History and other small JSON files.
  final Directory data;

  static Future<AppPaths> init() async {
    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    Directory shared = docs;
    if (Platform.isAndroid) {
      shared = await getExternalStorageDirectory() ?? docs;
    }
    final p = AppPaths._(
      Directory('${support.path}/models'),
      Directory('${docs.path}/recordings'),
      Directory('${shared.path}/testsets'),
      Directory('${shared.path}/exports'),
      Directory('${support.path}/data'),
    );
    for (final d in [p.models, p.recordings, p.testSets, p.exports, p.data]) {
      await d.create(recursive: true);
    }
    return p;
  }
}

Future<int> directorySize(Directory dir) async {
  if (!await dir.exists()) return 0;
  var total = 0;
  await for (final e in dir.list(recursive: true, followLinks: false)) {
    if (e is File) total += await e.length();
  }
  return total;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
