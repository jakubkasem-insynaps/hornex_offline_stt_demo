import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../core/stt_engine.dart';

/// Whisper in sherpa-onnx silently drops everything past 30 s of a single
/// call, so longer audio is cut into windows of this many seconds. The normal
/// pipeline never gets here because VAD segments are shorter.
const int kMaxWindowSeconds = 28;

/// Silence appended to every piece of audio given to Whisper, as a fraction
/// of the piece's length. sherpa-onnx lets Whisper emit at most 6 tokens per
/// second of audio it is given; a VAD chunk is dense speech and Slovak needs
/// more than that, so without the extra silence the text is cut off mid-word.
/// 0.5 was measured on FLEURS sk (see README, "Whisper and VAD chunks").
const double kWhisperSilencePad = 0.5;

/// Returns [audio] followed by silence, without exceeding the 28 s window.
Float32List padWithSilence(Float32List audio, int sampleRate) {
  final room = kMaxWindowSeconds * sampleRate - audio.length;
  final wanted = (audio.length * kWhisperSilencePad).floor();
  final extra = wanted < room ? wanted : room;
  if (extra <= 0) return audio;
  return Float32List(audio.length + extra)..setRange(0, audio.length, audio);
}

/// Runs sherpa-onnx offline recognition on a background isolate so the UI
/// stays responsive. Holds one loaded model at a time (they are large).
class OfflineWorker {
  Isolate? _isolate;
  SendPort? _tx;
  Future<void>? _starting;
  final Map<int, Completer<Map<dynamic, dynamic>>> _pending = {};
  int _seq = 0;

  /// Identifies the loaded model + thread count, or null.
  String? loadedKey;

  Future<void> _lock = Future.value();

  /// Runs [action] with the worker to itself, so "load model A, transcribe"
  /// cannot be interleaved with another engine loading model B.
  Future<T> exclusive<T>(Future<T> Function() action) {
    final result = _lock.then((_) => action());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    final rx = ReceivePort();
    final ready = Completer<SendPort>();
    rx.listen((dynamic m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is Map) {
        final c = _pending.remove(m['seq']);
        if (c == null) return;
        if (m['error'] != null) {
          c.completeError(SttException(m['error'] as String));
        } else {
          c.complete(m);
        }
      }
    });
    _isolate = await Isolate.spawn(_workerMain, rx.sendPort, debugName: 'stt-offline');
    _tx = await ready.future;
  }

  Future<Map<dynamic, dynamic>> _call(Map<String, dynamic> msg) async {
    await _ensureStarted();
    final seq = ++_seq;
    final c = Completer<Map<dynamic, dynamic>>();
    _pending[seq] = c;
    _tx!.send({...msg, 'seq': seq});
    return c.future;
  }

  /// Loads a model unless [key] is already loaded. Returns the load time in ms,
  /// or null if nothing had to be loaded.
  Future<int?> load({
    required String key,
    required String family,
    required Map<String, String> files,
    required int numThreads,
  }) async {
    if (loadedKey == key) return null;
    loadedKey = null;
    final r = await _call({'op': 'load', 'family': family, 'files': files, 'threads': numThreads});
    loadedKey = key;
    return r['ms'] as int;
  }

  /// Returns `{text: String, ms: int}`.
  Future<({String text, int ms})> transcribe(Float32List samples, int sampleRate) async {
    final r = await _call({'op': 'transcribe', 'samples': samples, 'sr': sampleRate});
    return (text: r['text'] as String, ms: r['ms'] as int);
  }

  Future<void> unload() async {
    if (_tx == null) return;
    loadedKey = null;
    await _call({'op': 'unload'});
  }

  void kill() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _tx = null;
    _starting = null;
    loadedKey = null;
    for (final c in _pending.values) {
      c.completeError(SttException('Offline worker stopped'));
    }
    _pending.clear();
  }
}

void _workerMain(SendPort toMain) {
  final rx = ReceivePort();
  toMain.send(rx.sendPort);

  var bindingsReady = false;
  sherpa.OfflineRecognizer? recognizer;
  var isWhisper = false;

  rx.listen((dynamic raw) {
    final msg = raw as Map;
    final seq = msg['seq'];
    try {
      switch (msg['op'] as String) {
        case 'load':
          if (!bindingsReady) {
            // Every isolate needs its own binding initialisation.
            sherpa.initBindings();
            bindingsReady = true;
          }
          recognizer?.free();
          recognizer = null;
          final sw = Stopwatch()..start();
          recognizer = sherpa.OfflineRecognizer(_config(
            msg['family'] as String,
            (msg['files'] as Map).cast<String, String>(),
            msg['threads'] as int,
          ));
          isWhisper = msg['family'] == 'whisper';
          toMain.send({'seq': seq, 'ms': sw.elapsedMilliseconds});
        case 'transcribe':
          final rec = recognizer;
          if (rec == null) throw StateError('No model loaded');
          final samples = msg['samples'] as Float32List;
          final sr = msg['sr'] as int;
          final sw = Stopwatch()..start();
          final window = kMaxWindowSeconds * sr;
          final parts = <String>[];
          for (var start = 0; start < samples.length; start += window) {
            final end = start + window < samples.length ? start + window : samples.length;
            final stream = rec.createStream();
            try {
              final piece = start == 0 && end == samples.length
                  ? samples
                  : Float32List.sublistView(samples, start, end);
              stream.acceptWaveform(
                samples: isWhisper ? padWithSilence(piece, sr) : piece,
                sampleRate: sr,
              );
              rec.decode(stream);
              final text = rec.getResult(stream).text.trim();
              if (text.isNotEmpty) parts.add(text);
            } finally {
              stream.free();
            }
          }
          toMain.send({'seq': seq, 'text': parts.join(' '), 'ms': sw.elapsedMilliseconds});
        case 'unload':
          recognizer?.free();
          recognizer = null;
          toMain.send({'seq': seq});
      }
    } catch (e) {
      toMain.send({'seq': seq, 'error': e.toString()});
    }
  });
}

sherpa.OfflineRecognizerConfig _config(String family, Map<String, String> files, int threads) {
  final sherpa.OfflineModelConfig model;
  switch (family) {
    case 'whisper':
      model = sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: files['encoder']!,
          decoder: files['decoder']!,
          language: kLanguage, // forced; never auto-detect
          task: 'transcribe',
        ),
        tokens: files['tokens']!,
        modelType: 'whisper',
        numThreads: threads,
        debug: false,
      );
    case 'nemo_transducer':
      // NeMo Parakeet TDT has no language input: the multilingual model
      // decides the language itself. Only the Slovak fine-tune is Slovak-only.
      model = sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: files['encoder']!,
          decoder: files['decoder']!,
          joiner: files['joiner']!,
        ),
        tokens: files['tokens']!,
        modelType: 'nemo_transducer',
        numThreads: threads,
        debug: false,
      );
    default:
      throw ArgumentError('Unknown model family "$family"');
  }
  return sherpa.OfflineRecognizerConfig(model: model);
}
