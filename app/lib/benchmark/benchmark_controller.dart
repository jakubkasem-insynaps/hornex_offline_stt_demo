import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/device.dart';
import '../core/normalization.dart';
import '../core/stt_engine.dart';
import '../core/wav.dart';
import '../core/wer.dart';
import '../data/exporter.dart';
import '../data/settings.dart';
import '../engines/engine_registry.dart';
import '../engines/model_manager.dart';
import '../pipeline/transcriber.dart';
import '../pipeline/vad.dart';
import 'test_set.dart';

class ClipResult {
  ClipResult({
    required this.engineId,
    required this.clip,
    required this.reference,
    required this.hypothesis,
    required this.words,
    required this.chars,
    required this.noSpeech,
    required this.audioMs,
    required this.speechMs,
    required this.processingMs,
    required this.keyFound,
    required this.keyExpected,
    this.modelLoadMs,
    this.networkLatencyMs,
    this.peakRssBytes,
    this.error,
  });

  final String engineId;
  final String clip;
  final String reference;
  final String hypothesis;
  final EditCounts words;
  final EditCounts chars;
  final bool noSpeech;
  final int audioMs;
  final int speechMs;
  final int processingMs;
  final int keyFound;
  final int keyExpected;
  final int? modelLoadMs;
  final int? networkLatencyMs;
  final int? peakRssBytes;
  final String? error;

  bool get hallucinated => noSpeech && normalizeTranscript(hypothesis).isNotEmpty;
  double? get rtf => speechMs > 0 ? processingMs / speechMs : null;

  Map<String, dynamic> toJson() => {
        'engineId': engineId,
        'clip': clip,
        'reference': reference,
        'hypothesis': hypothesis,
        'referenceNormalized': normalizeTranscript(reference),
        'hypothesisNormalized': normalizeTranscript(hypothesis),
        'wer': words.rate,
        'cer': chars.rate,
        'wordEdits': words.toJson(),
        'noSpeech': noSpeech,
        'hallucinated': hallucinated,
        'audioMs': audioMs,
        'speechMs': speechMs,
        'processingMs': processingMs,
        'rtf': rtf,
        'modelLoadMs': modelLoadMs,
        'networkLatencyMs': networkLatencyMs,
        'peakRssBytes': peakRssBytes,
        'keyTermsFound': keyFound,
        'keyTermsExpected': keyExpected,
        'error': error,
      };
}

class EngineSummary {
  EngineSummary(this.engineId, this.engineName, this.quantization, List<ClipResult> results) {
    var words = const EditCounts();
    var chars = const EditCounts();
    var procSum = 0, speechSum = 0, latencySum = 0, latencyN = 0, netSum = 0, netN = 0;
    for (final r in results) {
      if (r.error != null) {
        errors++;
        continue;
      }
      clips++;
      if (r.noSpeech) {
        noSpeechClips++;
        if (r.hallucinated) hallucinations++;
      } else {
        words = words + r.words;
        chars = chars + r.chars;
      }
      procSum += r.processingMs;
      speechSum += r.speechMs;
      latencySum += r.processingMs;
      latencyN++;
      if (r.networkLatencyMs != null) {
        netSum += r.networkLatencyMs!;
        netN++;
      }
      keyFound += r.keyFound;
      keyExpected += r.keyExpected;
      modelLoadMs ??= r.modelLoadMs;
      if (r.peakRssBytes != null && r.peakRssBytes! > (peakRssBytes ?? 0)) peakRssBytes = r.peakRssBytes;
    }
    wer = words.rate;
    cer = chars.rate;
    rtf = speechSum > 0 ? procSum / speechSum : null;
    avgLatencyMs = latencyN > 0 ? latencySum / latencyN : null;
    avgNetworkLatencyMs = netN > 0 ? netSum / netN : null;
  }

  final String engineId;
  final String engineName;
  final String quantization;
  int clips = 0;
  int errors = 0;
  int noSpeechClips = 0;
  int hallucinations = 0;
  int keyFound = 0;
  int keyExpected = 0;

  /// Corpus-level: total word errors / total reference words (speech clips).
  double? wer;
  double? cer;

  /// Total processing time / total audio processed.
  double? rtf;
  double? avgLatencyMs;
  double? avgNetworkLatencyMs;
  int? modelLoadMs;
  int? peakRssBytes;

  /// Share of no-speech clips that produced any text.
  double? get hallucinationRate => noSpeechClips > 0 ? hallucinations / noSpeechClips : null;
  double? get keyTermAccuracy => keyExpected > 0 ? keyFound / keyExpected : null;

  Map<String, dynamic> toJson() => {
        'engineId': engineId,
        'engineName': engineName,
        'quantization': quantization,
        'clips': clips,
        'errors': errors,
        'wer': wer,
        'cer': cer,
        'noSpeechClips': noSpeechClips,
        'hallucinationRate': hallucinationRate,
        'keyTermAccuracy': keyTermAccuracy,
        'keyTermsExpected': keyExpected,
        'rtf': rtf,
        'avgLatencyMs': avgLatencyMs,
        'avgNetworkLatencyMs': avgNetworkLatencyMs,
        'modelLoadMs': modelLoadMs,
        'peakRssBytes': peakRssBytes,
      };
}

/// WER of an offline engine measured against an online engine's transcripts.
class CrossWer {
  CrossWer(this.offlineId, this.onlineId, this.wer, this.clips);
  final String offlineId;
  final String onlineId;
  final double? wer;
  final int clips;

  Map<String, dynamic> toJson() => {'offline': offlineId, 'onlineAsReference': onlineId, 'wer': wer, 'clips': clips};
}

class BenchmarkController extends ChangeNotifier {
  BenchmarkController(this._settings, this._registry, this._models, this.store);

  final Settings _settings;
  final EngineRegistry _registry;
  final ModelManager _models;
  final TestSetStore store;

  final Set<String> selectedEngineIds = {};
  String? testSetName;

  /// true: clips go through VAD like in production. false: raw clip to the engine.
  bool useVad = true;

  /// 0 = all clips.
  int maxClips = 0;

  bool running = false;
  bool _cancel = false;
  String progress = '';
  String? error;

  List<ClipResult> results = [];
  List<EngineSummary> summaries = [];
  List<CrossWer> cross = [];
  Map<String, dynamic> _runInfo = {};

  void toggleEngine(String id) {
    if (!selectedEngineIds.remove(id)) selectedEngineIds.add(id);
    notifyListeners();
  }

  void update(VoidCallback change) {
    change();
    notifyListeners();
  }

  void cancel() => _cancel = true;

  Future<void> run() async {
    if (running) return;
    final name = testSetName;
    if (name == null || selectedEngineIds.isEmpty) {
      error = 'Pick a test set and at least one engine.';
      notifyListeners();
      return;
    }
    running = true;
    _cancel = false;
    error = null;
    results = [];
    summaries = [];
    cross = [];
    notifyListeners();
    try {
      final set = await store.load(name);
      if (set.clips.isEmpty) throw SttException('Test set "$name" has no .wav + .txt pairs.');
      final clips = maxClips > 0 && maxClips < set.clips.length ? set.clips.sublist(0, maxClips) : set.clips;
      final vadPath = useVad ? await _models.ensureVad() : null;
      final vadParams = VadParams.from(_settings);
      final engines = [
        for (final id in selectedEngineIds)
          if (_registry.byId(id) != null) _registry.byId(id)!
      ];
      final device = await DeviceInfo.get();
      _runInfo = {
        'testSet': name,
        'clips': clips.length,
        'useVad': useVad,
        'vad': useVad ? vadParams.toJson() : null,
        'threads': _settings.numThreads,
        'deviceModel': device.model,
        'osVersion': device.os,
        'startedAt': DateTime.now().toIso8601String(),
        'normalization': 'shared/normalization/sk_rules.json',
      };

      for (final engine in engines) {
        if (_cancel) break;
        final engineResults = <ClipResult>[];
        var consecutiveErrors = 0;
        for (var i = 0; i < clips.length; i++) {
          if (_cancel) break;
          final clip = clips[i];
          progress = '${engine.displayName}: ${i + 1}/${clips.length}';
          notifyListeners();
          try {
            final audio = await readWavFile(clip.audioPath);
            final pieces = vadPath != null
                ? [for (final c in segmentClip(audio, vadPath, vadParams)) c.clip]
                : [audio];
            final out = await runEngine(engine, pieces);
            final (found, expected) = keyTermHits(clip.reference, out.text, set.keyTerms);
            engineResults.add(ClipResult(
              engineId: engine.id,
              clip: clip.name,
              reference: clip.reference,
              hypothesis: out.text,
              words: wordCounts(clip.reference, out.text),
              chars: charCounts(clip.reference, out.text),
              noSpeech: isNoSpeech(clip.reference),
              audioMs: audio.durationMs,
              speechMs: out.speechMs,
              processingMs: out.processingMs,
              keyFound: found,
              keyExpected: expected,
              modelLoadMs: out.modelLoadMs,
              networkLatencyMs: out.networkLatencyMs,
              peakRssBytes: out.peakRssBytes,
            ));
            consecutiveErrors = 0;
          } catch (e) {
            engineResults.add(ClipResult(
              engineId: engine.id,
              clip: clip.name,
              reference: clip.reference,
              hypothesis: '',
              words: const EditCounts(),
              chars: const EditCounts(),
              noSpeech: isNoSpeech(clip.reference),
              audioMs: 0,
              speechMs: 0,
              processingMs: 0,
              keyFound: 0,
              keyExpected: 0,
              error: e.toString(),
            ));
            if (++consecutiveErrors >= 3) {
              error = '${engine.displayName} failed 3 clips in a row and was stopped: $e';
              break;
            }
          }
        }
        results.addAll(engineResults);
        summaries.add(EngineSummary(engine.id, engine.displayName, engine.quantization, engineResults));
        await engine.dispose();
        notifyListeners();
      }
      _computeCross(engines);
      progress = _cancel ? 'Cancelled' : 'Finished';
    } catch (e) {
      error = e.toString();
      progress = 'Failed';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  void _computeCross(List<SttEngine> engines) {
    final byEngine = <String, Map<String, ClipResult>>{};
    for (final r in results) {
      if (r.error == null) (byEngine[r.engineId] ??= {})[r.clip] = r;
    }
    for (final off in engines.where((e) => !e.isOnline)) {
      for (final on in engines.where((e) => e.isOnline)) {
        var counts = const EditCounts();
        var n = 0;
        final offR = byEngine[off.id] ?? const {};
        final onR = byEngine[on.id] ?? const {};
        for (final entry in offR.entries) {
          final ref = onR[entry.key];
          if (ref == null || ref.noSpeech) continue;
          counts = counts + wordCounts(ref.hypothesis, entry.value.hypothesis);
          n++;
        }
        cross.add(CrossWer(off.id, on.id, counts.rate, n));
      }
    }
  }

  String clipsCsv() => toCsv(
        const [
          'engine_id', 'clip', 'no_speech', 'hallucinated', 'wer', 'cer', 'substitutions', 'deletions', 'insertions',
          'reference_words', 'audio_ms', 'speech_ms', 'processing_ms', 'rtf', 'model_load_ms', 'network_latency_ms',
          'peak_rss_bytes', 'key_terms_found', 'key_terms_expected', 'reference', 'hypothesis', 'error',
        ],
        [
          for (final r in results)
            [
              r.engineId, r.clip, r.noSpeech, r.hallucinated, r.words.rate, r.chars.rate, r.words.substitutions,
              r.words.deletions, r.words.insertions, r.words.refLength, r.audioMs, r.speechMs, r.processingMs, r.rtf,
              r.modelLoadMs, r.networkLatencyMs, r.peakRssBytes, r.keyFound, r.keyExpected, r.reference, r.hypothesis,
              r.error,
            ],
        ],
      );

  String summaryCsv() => toCsv(
        const [
          'engine_id', 'engine_name', 'quantization', 'clips', 'errors', 'wer', 'cer', 'no_speech_clips',
          'hallucination_rate', 'key_term_accuracy', 'rtf', 'avg_latency_ms', 'avg_network_latency_ms',
          'model_load_ms', 'peak_rss_bytes',
        ],
        [
          for (final s in summaries)
            [
              s.engineId, s.engineName, s.quantization, s.clips, s.errors, s.wer, s.cer, s.noSpeechClips,
              s.hallucinationRate, s.keyTermAccuracy, s.rtf, s.avgLatencyMs, s.avgNetworkLatencyMs, s.modelLoadMs,
              s.peakRssBytes,
            ],
        ],
      );

  String resultsJson() => const JsonEncoder.withIndent('  ').convert({
        'run': _runInfo,
        'summary': [for (final s in summaries) s.toJson()],
        'offlineVsOnline': [for (final c in cross) c.toJson()],
        'clips': [for (final r in results) r.toJson()],
      });
}
