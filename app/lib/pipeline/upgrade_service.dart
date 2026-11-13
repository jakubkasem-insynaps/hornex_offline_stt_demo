import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/stt_engine.dart';
import '../core/wav.dart';
import '../data/history_store.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../engines/engine_registry.dart';
import '../engines/proxy_client.dart';
import 'transcriber.dart';

/// The "upgrade" half of draft + upgrade: once the network is there, send the
/// saved audio to the online model and replace the draft with its transcript,
/// unless the user edited the draft, in which case they are asked.
class UpgradeService extends ChangeNotifier {
  UpgradeService(this._history, this._registry, this._settings, this._proxy);

  final HistoryStore _history;
  final EngineRegistry _registry;
  final Settings _settings;
  final ProxyClient _proxy;

  final Set<String> _running = {};

  /// Recordings whose upgrade failed for a reason that retrying will not fix
  /// (provider rejected the request, no API key). Skipped by the timer so the
  /// audio is not uploaded, and paid for, every 30 s; manual retry still works.
  final Set<String> _noAutoRetry = {};
  Timer? _timer;

  bool isRunning(String recordingId) => _running.contains(recordingId);

  /// Retries pending upgrades every 30 s (and once now).
  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => retryPending());
    retryPending();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> retryPending({bool manual = false}) async {
    final pending = _history.recordings
        .where((r) => r.upgradeState == UpgradeState.pending && (manual || !_noAutoRetry.contains(r.id)))
        .toList();
    for (final r in pending) {
      await tryUpgrade(r);
    }
  }

  Future<void> tryUpgrade(Recording r) async {
    if (r.upgradeState != UpgradeState.pending || _running.contains(r.id)) return;
    if (_settings.simulateOffline) {
      r.upgradeError = 'Simulate offline is on; the upgrade waits.';
      notifyListeners();
      return;
    }
    final engine = _registry.byId(r.upgradeEngineId ?? '');
    final path = r.audioPath;
    if (engine == null || !engine.isOnline) {
      r.upgradeError = 'Online engine "${r.upgradeEngineId}" is not available. Refresh the engine list in Settings.';
      notifyListeners();
      return;
    }
    if (path == null || !File(path).existsSync()) {
      // Nothing to send any more: settle on what we have.
      r
        ..upgradeError = 'Saved audio is missing; kept the draft.'
        ..finalText = r.editedText ?? r.draftText
        ..upgradeState = UpgradeState.done;
      await _history.save();
      return;
    }
    _running.add(r.id);
    r.upgradeError = null;
    notifyListeners();
    try {
      final probe = await _proxy.probe(Duration(milliseconds: _settings.networkTimeoutMs));
      if (probe == null) {
        r.upgradeError = 'No connection to the proxy; will retry.';
        return;
      }
      final audio = await readWavFile(path);
      final clips = _settings.uploadTrimmedAudio ? clipsFromRanges(audio.samples, r.speechRanges) : [audio];
      final outcome = await runEngine(engine, clips);
      final record = await buildRecord(
        engine: engine,
        outcome: outcome,
        audioDurationMs: r.durationMs,
        role: 'final',
        endOfSpeechToFinalMs: r.stoppedAt == null ? null : DateTime.now().difference(r.stoppedAt!).inMilliseconds,
        note: 'upgrade of offline draft (proxy probe $probe ms)',
      );
      r.transcriptions.add(record);
      if (r.draftWasEdited) {
        // Do not overwrite the user's edits: ask.
        r
          ..pendingOnlineText = outcome.text
          ..upgradeState = UpgradeState.conflict;
      } else {
        r
          ..finalText = outcome.text
          ..upgradeState = UpgradeState.done;
        await _releaseAudio(r);
      }
    } on SttException catch (e) {
      r.upgradeError = e.retryable ? '$e; will retry.' : '$e (tap retry to try again)';
      if (!e.retryable) _noAutoRetry.add(r.id);
    } catch (e) {
      r.upgradeError = '$e (tap retry to try again)';
      _noAutoRetry.add(r.id);
    } finally {
      _running.remove(r.id);
      await _history.save();
      notifyListeners();
    }
  }

  /// Settles an edit conflict.
  Future<void> resolveConflict(Recording r, {required bool useOnline}) async {
    if (r.upgradeState != UpgradeState.conflict) return;
    r
      ..finalText = useOnline ? r.pendingOnlineText : r.editedText
      ..pendingOnlineText = useOnline ? null : r.pendingOnlineText
      ..upgradeState = UpgradeState.done;
    await _releaseAudio(r);
    await _history.save();
    notifyListeners();
  }

  /// The audio is only needed until the online transcript has succeeded.
  Future<void> _releaseAudio(Recording r) async {
    if (!_settings.keepAudioAfterUpgrade) await _history.deleteAudio(r);
  }
}
