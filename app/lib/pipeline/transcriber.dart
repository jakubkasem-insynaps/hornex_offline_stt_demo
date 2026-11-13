import 'dart:typed_data';

import '../core/device.dart';
import '../core/stt_engine.dart';
import '../core/wav.dart';
import '../data/models.dart';

/// Result of running one engine over the speech of one recording.
class RunOutcome {
  RunOutcome({
    required this.text,
    required this.processingMs,
    required this.speechMs,
    this.modelLoadMs,
    this.networkLatencyMs,
    this.peakRssBytes,
    this.metadata = const {},
  });

  final String text;
  final int processingMs;
  final int speechMs;
  final int? modelLoadMs;
  final int? networkLatencyMs;
  final int? peakRssBytes;
  final Map<String, dynamic> metadata;
}

/// Runs [engine] over [clips] (the speech chunks of one recording).
///
/// Offline engines get one chunk at a time; online engines get one upload with
/// the chunks joined. No chunks means VAD found no speech: the engine is not
/// called and the text is empty.
Future<RunOutcome> runEngine(SttEngine engine, List<AudioClip> clips) async {
  if (clips.isEmpty) {
    return RunOutcome(text: '', processingMs: 0, speechMs: 0, metadata: const {'vadNoSpeech': true});
  }
  final sampler = MemorySampler()..start();
  try {
    if (engine.isOnline) {
      final clip = clips.length == 1 ? clips.first : AudioClip.concat(clips, kSampleRate);
      final r = await engine.transcribe(clip);
      return RunOutcome(
        text: r.text,
        processingMs: r.processingMs,
        speechMs: clip.durationMs,
        networkLatencyMs: r.networkLatencyMs,
        peakRssBytes: sampler.stop(),
        metadata: r.metadata,
      );
    }
    final parts = <String>[];
    var ms = 0;
    var speech = 0;
    int? loadMs;
    Map<String, dynamic> meta = const {};
    for (final clip in clips) {
      final r = await engine.transcribe(clip);
      if (r.text.isNotEmpty) parts.add(r.text);
      ms += r.processingMs;
      speech += clip.durationMs;
      loadMs ??= r.modelLoadMs;
      meta = r.metadata;
    }
    return RunOutcome(
      text: parts.join(' '),
      processingMs: ms,
      speechMs: speech,
      modelLoadMs: loadMs,
      peakRssBytes: sampler.stop(),
      metadata: {...meta, 'chunks': clips.length},
    );
  } finally {
    sampler.stop();
  }
}

/// Cuts the saved [ranges] out of a recording.
List<AudioClip> clipsFromRanges(Float32List samples, List<List<int>> ranges) => [
      for (final r in ranges)
        if (r[1] > r[0] && r[1] <= samples.length)
          AudioClip(Float32List.sublistView(samples, r[0], r[1]), kSampleRate),
    ];

Future<TranscriptionRecord> buildRecord({
  required SttEngine engine,
  required RunOutcome outcome,
  required int audioDurationMs,
  required String role,
  int? endOfSpeechToFinalMs,
  String? note,
}) async {
  final device = await DeviceInfo.get();
  return TranscriptionRecord(
    id: newId(),
    createdAt: DateTime.now(),
    engineId: engine.id,
    engineName: engine.displayName,
    isOnline: engine.isOnline,
    quantization: engine.quantization,
    deviceModel: device.model,
    osVersion: device.os,
    audioDurationMs: audioDurationMs,
    speechDurationMs: outcome.speechMs,
    processingMs: outcome.processingMs,
    text: outcome.text,
    role: role,
    endOfSpeechToFinalMs: endOfSpeechToFinalMs,
    modelLoadMs: outcome.modelLoadMs,
    peakRssBytes: outcome.peakRssBytes,
    networkLatencyMs: outcome.networkLatencyMs,
    note: note,
    metadata: outcome.metadata,
  );
}
