import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SttMode {
  onlineOnly('Online only'),
  offlineOnly('Offline only'),
  auto('Auto'),
  draftUpgrade('Draft + upgrade');

  const SttMode(this.label);
  final String label;
}

/// User-adjustable settings, persisted in SharedPreferences.
class Settings extends ChangeNotifier {
  Settings(this._prefs);

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  // --- Proxy / network
  String get proxyUrl => _prefs.getString('proxyUrl') ?? 'http://10.0.2.2:8787';
  set proxyUrl(String v) => _setString('proxyUrl', v.trim().replaceAll(RegExp(r'/+$'), ''));

  String get proxyToken => _prefs.getString('proxyToken') ?? '';
  set proxyToken(String v) => _setString('proxyToken', v.trim());

  /// Where self-converted models are downloaded from. Empty = the proxy.
  String get modelHostUrl => _prefs.getString('modelHostUrl') ?? '';
  set modelHostUrl(String v) => _setString('modelHostUrl', v.trim().replaceAll(RegExp(r'/+$'), ''));
  String get effectiveModelHost => modelHostUrl.isEmpty ? proxyUrl : modelHostUrl;

  /// Auto mode: how long the proxy may take to answer before we go offline.
  int get networkTimeoutMs => _prefs.getInt('networkTimeoutMs') ?? 3000;
  set networkTimeoutMs(int v) => _setInt('networkTimeoutMs', v);

  bool get simulateOffline => _prefs.getBool('simulateOffline') ?? false;
  set simulateOffline(bool v) => _setBool('simulateOffline', v);

  // --- Mode and engines
  SttMode get mode => SttMode.values[(_prefs.getInt('mode') ?? SttMode.auto.index)
      .clamp(0, SttMode.values.length - 1)];
  set mode(SttMode v) => _setInt('mode', v.index);

  String get offlineEngineId => _prefs.getString('offlineEngineId') ?? 'kinit-whisper-small-sk';
  set offlineEngineId(String v) => _setString('offlineEngineId', v);

  String get onlineEngineId => _prefs.getString('onlineEngineId') ?? 'soniox-async';
  set onlineEngineId(String v) => _setString('onlineEngineId', v);

  // --- VAD
  double get vadThreshold => _prefs.getDouble('vadThreshold') ?? 0.5;
  set vadThreshold(double v) => _setDouble('vadThreshold', v);

  /// Silence that ends a speech segment, seconds.
  double get vadMinSilence => _prefs.getDouble('vadMinSilence') ?? 0.7;
  set vadMinSilence(double v) => _setDouble('vadMinSilence', v);

  double get vadMinSpeech => _prefs.getDouble('vadMinSpeech') ?? 0.25;
  set vadMinSpeech(double v) => _setDouble('vadMinSpeech', v);

  /// Audio kept before and after each speech segment, seconds.
  double get vadPadding => _prefs.getDouble('vadPadding') ?? 0.2;
  set vadPadding(double v) => _setDouble('vadPadding', v);

  /// Longest single segment, seconds. Whisper in sherpa-onnx drops anything
  /// past 30 s, so this must stay well under that including padding.
  double get vadMaxSpeech => _prefs.getDouble('vadMaxSpeech') ?? 25.0;
  set vadMaxSpeech(double v) => _setDouble('vadMaxSpeech', v);

  // --- Inference / audio
  int get numThreads => _prefs.getInt('numThreads') ?? 4;
  set numThreads(int v) => _setInt('numThreads', v);

  /// Upload only the speech found by VAD (true) or the whole recording (false).
  bool get uploadTrimmedAudio => _prefs.getBool('uploadTrimmedAudio') ?? true;
  set uploadTrimmedAudio(bool v) => _setBool('uploadTrimmedAudio', v);

  /// Production deletes the audio once the online transcript arrives. Keeping
  /// it lets a tester re-run other engines on the same recording.
  bool get keepAudioAfterUpgrade => _prefs.getBool('keepAudioAfterUpgrade') ?? false;
  set keepAudioAfterUpgrade(bool v) => _setBool('keepAudioAfterUpgrade', v);

  /// Last engine list received from the proxy (JSON), so pickers work offline.
  String get cachedOnlineEngines => _prefs.getString('cachedOnlineEngines') ?? '';
  set cachedOnlineEngines(String v) => _setString('cachedOnlineEngines', v);

  void _setString(String k, String v) {
    _prefs.setString(k, v);
    notifyListeners();
  }

  void _setInt(String k, int v) {
    _prefs.setInt(k, v);
    notifyListeners();
  }

  void _setBool(String k, bool v) {
    _prefs.setBool(k, v);
    notifyListeners();
  }

  void _setDouble(String k, double v) {
    _prefs.setDouble(k, v);
    notifyListeners();
  }
}
