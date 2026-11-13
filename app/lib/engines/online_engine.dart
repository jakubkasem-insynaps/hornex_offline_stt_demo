import '../core/stt_engine.dart';
import '../core/wav.dart';
import 'proxy_client.dart';

/// A cloud model reached through the backend proxy (batch transcription).
///
/// Realtime streaming is not implemented: [transcribeStream] returns null.
class OnlineEngine extends SttEngine {
  OnlineEngine(this.info, this._proxy);

  final OnlineEngineInfo info;
  final ProxyClient _proxy;

  @override
  String get id => info.id;

  @override
  String get displayName => info.displayName;

  @override
  bool get isOnline => true;

  @override
  String get quantization => 'n/a (cloud)';

  @override
  Future<void> load() async {
    final ms = await _proxy.probe(const Duration(seconds: 5));
    if (ms == null) throw SttException('Proxy is not reachable', retryable: true);
    if (!info.configured) {
      throw SttException('The proxy has no API key for ${info.displayName}');
    }
  }

  @override
  Future<SttResult> transcribe(AudioClip clip) async {
    final wav = encodeWav(clip.samples, sampleRate: clip.sampleRate);
    final sw = Stopwatch()..start();
    final j = await _proxy.transcribe(id, wav);
    final roundTripMs = sw.elapsedMilliseconds;
    final providerMs = (j['providerMs'] as num?)?.toInt();
    return SttResult(
      text: (j['text'] as String? ?? '').trim(),
      processingMs: roundTripMs,
      networkLatencyMs: providerMs == null ? null : (roundTripMs - providerMs).clamp(0, roundTripMs).toInt(),
      metadata: {
        'provider': j['provider'],
        'model': j['model'],
        'providerMs': providerMs,
        'baseUrl': j['baseUrl'],
        'uploadBytes': wav.length,
        if (j['meta'] is Map) ...{'providerMeta': j['meta']},
      },
    );
  }

  @override
  Future<void> dispose() async {}
}
