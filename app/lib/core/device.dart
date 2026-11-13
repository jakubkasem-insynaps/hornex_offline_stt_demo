import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';

class DeviceInfo {
  DeviceInfo(this.model, this.os);
  final String model;
  final String os;

  static DeviceInfo? _cached;

  static Future<DeviceInfo> get() async {
    if (_cached != null) return _cached!;
    final plugin = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        _cached = DeviceInfo('${a.manufacturer} ${a.model}', 'Android ${a.version.release} (API ${a.version.sdkInt})');
      } else if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        _cached = DeviceInfo(i.utsname.machine, '${i.systemName} ${i.systemVersion}');
      }
    } catch (_) {
      // Fall through to the generic answer.
    }
    return _cached ??= DeviceInfo(Platform.localHostname, '${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  }
}

/// Best-effort peak memory: samples the process resident set size while some
/// work runs. Covers the whole app process (Dart heap + native model memory),
/// not the model alone, and can miss short spikes between samples.
class MemorySampler {
  Timer? _timer;
  int _peak = 0;

  void start() {
    _peak = _read();
    _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      final v = _read();
      if (v > _peak) _peak = v;
    });
  }

  /// Stops sampling and returns the peak in bytes, or null if unavailable.
  int? stop() {
    _timer?.cancel();
    _timer = null;
    final v = _read();
    if (v > _peak) _peak = v;
    return _peak > 0 ? _peak : null;
  }

  static int _read() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return 0;
    }
  }
}
