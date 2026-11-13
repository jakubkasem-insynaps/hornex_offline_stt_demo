import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../core/stt_engine.dart';
import '../core/wav.dart';
import '../data/settings.dart';

bool _bindingsReady = false;

/// Loads the sherpa-onnx native library for the calling isolate (once).
void ensureSherpaBindings() {
  if (_bindingsReady) return;
  sherpa.initBindings();
  _bindingsReady = true;
}

class VadParams {
  const VadParams({
    required this.threshold,
    required this.minSilence,
    required this.minSpeech,
    required this.maxSpeech,
    required this.padding,
  });

  factory VadParams.from(Settings s) => VadParams(
        threshold: s.vadThreshold,
        minSilence: s.vadMinSilence,
        minSpeech: s.vadMinSpeech,
        maxSpeech: s.vadMaxSpeech,
        padding: s.vadPadding,
      );

  final double threshold;
  final double minSilence;
  final double minSpeech;
  final double maxSpeech;
  final double padding;

  Map<String, dynamic> toJson() => {
        'threshold': threshold,
        'minSilenceS': minSilence,
        'minSpeechS': minSpeech,
        'maxSpeechS': maxSpeech,
        'paddingS': padding,
      };
}

/// One stretch of speech found by VAD, with padding applied.
class SpeechChunk {
  SpeechChunk(this.startSample, this.endSample, this.from, this.to, this.clip);

  /// Unpadded bounds in the recording, in samples.
  final int startSample;
  final int endSample;

  /// Padded bounds in the recording, in samples: `clip` is `recording[from:to]`.
  final int from;
  final int to;

  /// Padded audio that is handed to the STT engine.
  final AudioClip clip;
}

/// Silero VAD (via sherpa-onnx) over a 16 kHz mono stream.
///
/// Keeps the whole recording so that each segment can be cut out again with
/// padding before and after. Runs in front of both the online and offline path.
class VadSegmenter {
  VadSegmenter(String modelPath, this.params) {
    ensureSherpaBindings();
    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: modelPath,
          threshold: params.threshold,
          minSilenceDuration: params.minSilence,
          minSpeechDuration: params.minSpeech,
          maxSpeechDuration: params.maxSpeech,
          windowSize: _window,
        ),
        sampleRate: kSampleRate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: params.maxSpeech + 30,
    );
  }

  static const int _window = 512;

  final VadParams params;
  late final sherpa.VoiceActivityDetector _vad;

  Float32List _buffer = Float32List(kSampleRate * 30);
  int _length = 0;
  int _fed = 0;
  int _lastEnd = 0;

  int get lengthSamples => _length;
  int get durationMs => (_length * 1000 / kSampleRate).round();

  /// True while VAD currently hears speech.
  bool get speechActive => _vad.isDetected();

  /// The whole recording so far.
  Float32List get samples => Float32List.sublistView(_buffer, 0, _length);

  /// Feeds audio; returns any speech segments that just ended.
  List<SpeechChunk> accept(Float32List input) {
    _append(input);
    while (_length - _fed >= _window) {
      _vad.acceptWaveform(Float32List.sublistView(_buffer, _fed, _fed + _window));
      _fed += _window;
    }
    return _drain();
  }

  /// Call once at the end: closes a segment that is still open.
  List<SpeechChunk> flush() {
    if (_length > _fed) {
      _vad.acceptWaveform(Float32List.sublistView(_buffer, _fed, _length));
      _fed = _length;
    }
    _vad.flush();
    return _drain();
  }

  void dispose() => _vad.free();

  void _append(Float32List input) {
    if (_length + input.length > _buffer.length) {
      var capacity = _buffer.length * 2;
      while (capacity < _length + input.length) {
        capacity *= 2;
      }
      final grown = Float32List(capacity)..setRange(0, _length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_length, _length + input.length, input);
    _length += input.length;
  }

  List<SpeechChunk> _drain() {
    final out = <SpeechChunk>[];
    final pad = (params.padding * kSampleRate).round();
    while (!_vad.isEmpty()) {
      final seg = _vad.front();
      _vad.pop();
      final start = seg.start;
      final end = start + seg.samples.length;
      // Pad, but never reach back into audio the previous chunk already has.
      var from = start - pad;
      if (from < _lastEnd) from = _lastEnd < start ? _lastEnd : start;
      if (from < 0) from = 0;
      var to = end + pad;
      if (to > _length) to = _length;
      if (to <= from) continue;
      _lastEnd = to;
      out.add(SpeechChunk(
        start,
        end,
        from,
        to,
        AudioClip(Float32List.fromList(Float32List.sublistView(_buffer, from, to)), kSampleRate),
      ));
    }
    return out;
  }
}

/// Runs VAD over a finished clip (saved recordings, benchmark files).
List<SpeechChunk> segmentClip(AudioClip clip, String vadModelPath, VadParams params) {
  final vad = VadSegmenter(vadModelPath, params);
  try {
    final out = <SpeechChunk>[];
    const step = kSampleRate; // 1 s at a time
    for (var i = 0; i < clip.samples.length; i += step) {
      final end = i + step < clip.samples.length ? i + step : clip.samples.length;
      out.addAll(vad.accept(Float32List.sublistView(clip.samples, i, end)));
    }
    out.addAll(vad.flush());
    return out;
  } finally {
    vad.dispose();
  }
}

int speechMs(List<SpeechChunk> chunks) =>
    chunks.fold<int>(0, (n, c) => n + c.clip.durationMs);
