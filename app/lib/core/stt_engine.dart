/// The common interface every speech-to-text model sits behind.
library;

import 'dart:typed_data';

/// Language is always forced to Slovak. Never rely on auto-detection.
const String kLanguage = 'sk';

/// Mono float audio in [-1, 1].
class AudioClip {
  const AudioClip(this.samples, this.sampleRate);

  final Float32List samples;
  final int sampleRate;

  int get durationMs => (samples.length * 1000 / sampleRate).round();
  bool get isEmpty => samples.isEmpty;

  /// Joins clips that share a sample rate into one.
  static AudioClip concat(List<AudioClip> clips, int sampleRate) {
    final total = clips.fold<int>(0, (n, c) => n + c.samples.length);
    final out = Float32List(total);
    var offset = 0;
    for (final c in clips) {
      out.setRange(offset, offset + c.samples.length, c.samples);
      offset += c.samples.length;
    }
    return AudioClip(out, sampleRate);
  }
}

class SttResult {
  const SttResult({
    required this.text,
    required this.processingMs,
    this.modelLoadMs,
    this.networkLatencyMs,
    this.metadata = const {},
  });

  final String text;

  /// Wall-clock time spent producing the text. For online engines this is the
  /// full round trip as seen by the app.
  final int processingMs;

  /// Cold-start time if the model had to be loaded for this call.
  final int? modelLoadMs;

  /// Online engines only: round trip minus the time the provider itself took
  /// (as reported by the proxy), i.e. app <-> proxy transport and overhead.
  final int? networkLatencyMs;

  /// Provider- or runtime-specific extras (provider time, region, model id...).
  final Map<String, dynamic> metadata;
}

class SttPartial {
  const SttPartial(this.text, {this.isFinal = false});
  final String text;
  final bool isFinal;
}

abstract class SttEngine {
  String get id;
  String get displayName;
  bool get isOnline;

  /// Exact quantization of the files in use, e.g. "int8 dynamic (MatMul)".
  /// "n/a" for cloud engines.
  String get quantization;

  /// Initialises the model (offline) or checks the API is reachable (online).
  /// The time a cold load took is reported in the next [SttResult.modelLoadMs].
  Future<void> load();

  /// Batch transcription of one clip.
  Future<SttResult> transcribe(AudioClip clip);

  /// Optional streaming transcription. Engines that do not support it return null.
  Stream<SttPartial>? transcribeStream(Stream<Float32List> audio) => null;

  Future<void> dispose();
}

class SttException implements Exception {
  SttException(this.message, {this.retryable = false});
  final String message;

  /// True for failures where falling back to another engine makes sense
  /// (network down, timeout, provider 5xx).
  final bool retryable;

  @override
  String toString() => message;
}
