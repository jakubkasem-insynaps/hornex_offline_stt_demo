import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../core/device.dart';
import '../core/stt_engine.dart';
import '../core/wav.dart';
import '../data/history_store.dart';
import '../data/models.dart';
import '../data/paths.dart';
import '../data/settings.dart';
import '../engines/engine_registry.dart';
import '../engines/model_manager.dart';
import '../engines/proxy_client.dart';
import 'transcriber.dart';
import 'upgrade_service.dart';
import 'vad.dart';

enum RecordState { idle, starting, recording, processing }

/// Microphone -> VAD -> router -> [online | offline] -> transcript.
///
/// While recording, speech chunks are cut at VAD pauses. When the offline
/// engine is going to be used, each chunk is transcribed in the background as
/// soon as it ends, so the draft is ready right after stopping.
class RecordController extends ChangeNotifier {
  RecordController(this._settings, this._registry, this._models, this._history, this._proxy, this._upgrades, this._paths);

  final Settings _settings;
  final EngineRegistry _registry;
  final ModelManager _models;
  final HistoryStore _history;
  final ProxyClient _proxy;
  final UpgradeService _upgrades;
  final AppPaths _paths;

  final AudioRecorder _recorder = AudioRecorder();

  RecordState state = RecordState.idle;
  String status = 'Ready';
  String? error;

  /// The recording most recently finished in this session.
  Recording? current;

  bool speechActive = false;
  DateTime? _startedAt;
  Timer? _ticker;

  VadSegmenter? _vad;
  StreamSubscription<Uint8List>? _sub;
  int? _carryByte;

  final List<SpeechChunk> _chunks = [];

  // Background offline drafting.
  SttEngine? _draftEngine;
  final List<String?> _draftParts = [];
  Future<void> _draftQueue = Future.value();
  int _draftChunksQueued = 0;
  int _draftMs = 0;
  int _draftSpeechMs = 0;
  int? _draftLoadMs;
  Object? _draftError;
  MemorySampler? _draftSampler;
  Map<String, dynamic> _draftMeta = const {};

  Duration get elapsed => _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);
  int get chunkCount => _chunks.length;

  /// Draft text assembled so far from finished chunks (shown live).
  String get liveText => _draftParts.whereType<String>().where((t) => t.isNotEmpty).join(' ');

  bool get _offlineFromTheStart =>
      _settings.simulateOffline || _settings.mode == SttMode.offlineOnly || _settings.mode == SttMode.draftUpgrade;

  Future<void> start() async {
    if (state != RecordState.idle) return;
    state = RecordState.starting;
    error = null;
    notifyListeners();
    try {
      if (!await _recorder.hasPermission()) {
        throw SttException('Microphone permission was denied.');
      }
      final mode = _settings.mode;
      final needsOnline = !_settings.simulateOffline && mode != SttMode.offlineOnly;
      if (needsOnline && _registry.selectedOnline == null) {
        throw SttException('No online engine selected. Open Settings, set the proxy URL and tap "Test connection".');
      }
      final offline = _registry.selectedOffline;
      if (_offlineFromTheStart && !(offline?.isInstalled ?? false)) {
        throw SttException('The selected offline model is not downloaded. Get it in the Models tab.');
      }
      _setStatus('Preparing voice detection…');
      final vadPath = await _models.ensureVad();
      _vad = VadSegmenter(vadPath, VadParams.from(_settings));

      _chunks.clear();
      _resetDraft();
      _carryByte = null;
      current = null;
      if (_offlineFromTheStart) {
        _draftEngine = offline;
        _draftSampler = MemorySampler()..start();
        // Warm the model while the user starts talking.
        _draftQueue = offline!.load().catchError((Object e) {
          _draftError = e;
        });
      }

      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: 1,
      ));
      _sub = stream.listen(_onAudio, onError: (Object e) {
        error = 'Recorder error: $e';
        notifyListeners();
      });
      _startedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => notifyListeners());
      state = RecordState.recording;
      _setStatus('Recording');
    } catch (e) {
      _vad?.dispose();
      _vad = null;
      _draftSampler?.stop();
      error = e.toString();
      state = RecordState.idle;
      _setStatus('Ready');
    }
  }

  void _onAudio(Uint8List bytes) {
    final vad = _vad;
    if (vad == null || bytes.isEmpty) return;
    // PCM16 frames can be split across stream events: carry an odd byte over.
    Uint8List data = bytes;
    if (_carryByte != null) {
      data = Uint8List(bytes.length + 1)
        ..[0] = _carryByte!
        ..setRange(1, bytes.length + 1, bytes);
      _carryByte = null;
    }
    if (data.length.isOdd) {
      _carryByte = data[data.length - 1];
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    // Copy so the samples are aligned regardless of the view's byte offset.
    final floats = pcm16ToFloat(Uint8List.fromList(data));
    final ended = vad.accept(floats);
    final active = vad.speechActive;
    if (ended.isNotEmpty || active != speechActive) {
      speechActive = active;
      for (final c in ended) {
        _onChunk(c);
      }
      notifyListeners();
    }
  }

  void _onChunk(SpeechChunk c) {
    _chunks.add(c);
    if (_draftEngine != null) _enqueueDraft(c);
  }

  void _enqueueDraft(SpeechChunk c) {
    final engine = _draftEngine!;
    final index = _draftParts.length;
    _draftParts.add(null);
    _draftChunksQueued++;
    _draftQueue = _draftQueue.then((_) async {
      if (_draftError != null) return;
      try {
        final r = await engine.transcribe(c.clip);
        _draftParts[index] = r.text;
        _draftMs += r.processingMs;
        _draftSpeechMs += c.clip.durationMs;
        _draftLoadMs ??= r.modelLoadMs;
        _draftMeta = r.metadata;
      } catch (e) {
        _draftError = e;
      }
      notifyListeners();
    });
  }

  void _resetDraft() {
    _draftEngine = null;
    _draftParts.clear();
    _draftQueue = Future.value();
    _draftChunksQueued = 0;
    _draftMs = 0;
    _draftSpeechMs = 0;
    _draftLoadMs = null;
    _draftError = null;
    _draftSampler = null;
    _draftMeta = const {};
  }

  Future<void> stop() async {
    if (state != RecordState.recording) return;
    final stoppedAt = DateTime.now();
    final sinceStop = Stopwatch()..start();
    state = RecordState.processing;
    _ticker?.cancel();
    _setStatus('Finishing…');
    try {
      await _recorder.stop();
      await _sub?.cancel();
      _sub = null;
      final vad = _vad!;
      for (final c in vad.flush()) {
        _onChunk(c);
      }
      final samples = Float32List.fromList(vad.samples);
      final durationMs = vad.durationMs;
      vad.dispose();
      _vad = null;
      speechActive = false;

      // Save the original recording before anything else can fail.
      final id = newId();
      final audioPath = '${_paths.recordings.path}/$id.wav';
      await writeWavFile(audioPath, samples);

      final mode = _settings.mode;
      final rec = Recording(
        id: id,
        createdAt: _startedAt ?? stoppedAt,
        mode: _settings.simulateOffline ? '${mode.label} (simulated offline)' : mode.label,
        durationMs: durationMs,
        audioPath: audioPath,
        stoppedAt: stoppedAt,
        speechRanges: [for (final c in _chunks) [c.from, c.to]],
      );
      current = rec;
      await _history.add(rec);

      final full = AudioClip(samples, kSampleRate);
      await _route(rec, mode, full, sinceStop);
      await _history.save();
      _setStatus(rec.isDraft ? 'Draft ready' : 'Done');
    } catch (e) {
      error = e.toString();
      _setStatus('Failed');
      await _history.save();
    } finally {
      _draftSampler?.stop();
      // Only still set if something above failed part-way.
      await _sub?.cancel();
      _sub = null;
      _vad?.dispose();
      _vad = null;
      speechActive = false;
      state = RecordState.idle;
      _startedAt = null;
      notifyListeners();
    }
  }

  Future<void> _route(Recording rec, SttMode mode, AudioClip full, Stopwatch sinceStop) async {
    if (_settings.simulateOffline) {
      await _runOffline(rec, sinceStop, role: 'final', note: 'simulate offline is on');
      rec.finalText = rec.transcriptions.last.text;
      return;
    }
    switch (mode) {
      case SttMode.offlineOnly:
        await _runOffline(rec, sinceStop, role: 'final', note: 'offline only');
        rec.finalText = rec.transcriptions.last.text;
      case SttMode.onlineOnly:
        await _runOnline(rec, full, sinceStop, note: 'online only');
        rec.finalText = rec.transcriptions.last.text;
      case SttMode.auto:
        _setStatus('Checking connection…');
        final timeout = _settings.networkTimeoutMs;
        final probe = await _proxy.probe(Duration(milliseconds: timeout));
        if (probe != null) {
          try {
            await _runOnline(rec, full, sinceStop, note: 'auto: proxy answered in $probe ms');
          } on SttException catch (e) {
            if (!e.retryable) rethrow;
            await _runOffline(rec, sinceStop, role: 'final', note: 'auto: online failed ($e), fell back to offline');
          }
        } else {
          await _runOffline(rec, sinceStop, role: 'final', note: 'auto: no answer from proxy within $timeout ms');
        }
        rec.finalText = rec.transcriptions.last.text;
      case SttMode.draftUpgrade:
        await _runOffline(rec, sinceStop, role: 'draft', note: 'offline draft');
        rec
          ..draftText = rec.transcriptions.last.text
          ..upgradeState = UpgradeState.pending
          ..upgradeEngineId = _settings.onlineEngineId;
        await _history.save();
        // Do not wait: the draft is usable now, the upgrade lands when it can.
        unawaited(_upgrades.tryUpgrade(rec));
    }
  }

  Future<void> _runOffline(Recording rec, Stopwatch sinceStop, {required String role, required String note}) async {
    final engine = _registry.selectedOffline;
    if (engine == null || !engine.isInstalled) {
      throw SttException('The selected offline model is not downloaded. Get it in the Models tab.');
    }
    _setStatus('Transcribing on device…');
    if (_draftEngine == null) {
      // Offline was not planned (auto fallback): nothing was drafted yet.
      _draftEngine = engine;
      _draftSampler = MemorySampler()..start();
      for (final c in _chunks) {
        _enqueueDraft(c);
      }
    }
    await _draftQueue;
    if (_draftError != null) throw _draftError!;
    final outcome = RunOutcome(
      text: liveText,
      processingMs: _draftMs,
      speechMs: _draftSpeechMs,
      modelLoadMs: _draftLoadMs,
      peakRssBytes: _draftSampler?.stop(),
      metadata: {
        ..._draftMeta,
        'chunks': _draftChunksQueued,
        if (_chunks.isEmpty) 'vadNoSpeech': true,
        'vad': VadParams.from(_settings).toJson(),
      },
    );
    rec.transcriptions.add(await buildRecord(
      engine: engine,
      outcome: outcome,
      audioDurationMs: rec.durationMs,
      role: role,
      endOfSpeechToFinalMs: sinceStop.elapsedMilliseconds,
      note: note,
    ));
  }

  Future<void> _runOnline(Recording rec, AudioClip full, Stopwatch sinceStop, {required String note}) async {
    final engine = _registry.selectedOnline;
    if (engine == null) throw SttException('No online engine selected.');
    _setStatus('Sending to ${engine.displayName}…');
    final clips = _settings.uploadTrimmedAudio ? [for (final c in _chunks) c.clip] : [full];
    final outcome = await runEngine(engine, clips);
    rec.transcriptions.add(await buildRecord(
      engine: engine,
      outcome: outcome,
      audioDurationMs: rec.durationMs,
      role: 'final',
      endOfSpeechToFinalMs: sinceStop.elapsedMilliseconds,
      note: note,
    ));
  }

  /// The user changed the draft text.
  void editDraft(Recording rec, String text) {
    if (rec.finalText != null) return;
    rec.editedText = text == rec.draftText ? null : text;
    _history.saveSoon();
  }

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
