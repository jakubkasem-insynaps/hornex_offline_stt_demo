import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/stt_engine.dart';
import '../data/settings.dart';
import 'model_manager.dart';
import 'offline_worker.dart';
import 'online_engine.dart';
import 'proxy_client.dart';
import 'sherpa_offline_engine.dart';

/// All engines the app can use.
///
/// To add an offline model: add an entry to assets/models.json.
/// To add a cloud model: add an entry to proxy/engines.js.
/// To add a different runtime: implement [SttEngine] and add it to [offline]
/// or [online] here.
class EngineRegistry extends ChangeNotifier {
  EngineRegistry(this._settings, this._models, this._proxy, this._worker) {
    offline = [
      for (final spec in _models.catalog.models)
        SherpaOfflineEngine(spec, _models, _worker, _settings),
    ];
    _restoreOnline();
    _models.addListener(notifyListeners);
  }

  final Settings _settings;
  final ModelManager _models;
  final ProxyClient _proxy;
  final OfflineWorker _worker;

  late final List<SherpaOfflineEngine> offline;
  List<OnlineEngine> online = [];
  String? onlineError;

  List<SttEngine> get all => [...offline, ...online];

  SttEngine? byId(String id) {
    for (final e in all) {
      if (e.id == id) return e;
    }
    return null;
  }

  SherpaOfflineEngine? get selectedOffline {
    final e = byId(_settings.offlineEngineId);
    return e is SherpaOfflineEngine ? e : null;
  }

  OnlineEngine? get selectedOnline {
    final e = byId(_settings.onlineEngineId);
    return e is OnlineEngine ? e : null;
  }

  void _restoreOnline() {
    final cached = _settings.cachedOnlineEngines;
    if (cached.isEmpty) return;
    try {
      online = [
        for (final e in jsonDecode(cached) as List)
          OnlineEngine(OnlineEngineInfo.fromJson(e as Map<String, dynamic>), _proxy),
      ];
    } catch (_) {
      online = [];
    }
  }

  /// Fetches the engine list from the proxy (model IDs live there, not in the app).
  Future<void> refreshOnline() async {
    try {
      final infos = await _proxy.engines();
      online = [for (final i in infos) OnlineEngine(i, _proxy)];
      _settings.cachedOnlineEngines = jsonEncode([for (final i in infos) i.toJson()]);
      onlineError = null;
    } catch (e) {
      onlineError = e.toString();
    }
    notifyListeners();
  }
}
