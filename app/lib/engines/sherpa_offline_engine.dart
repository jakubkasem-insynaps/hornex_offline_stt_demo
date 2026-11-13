import '../core/stt_engine.dart';
import '../data/settings.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'offline_worker.dart';

/// Any offline model that runs on sherpa-onnx (Whisper or NeMo transducer).
class SherpaOfflineEngine extends SttEngine {
  SherpaOfflineEngine(this.spec, this._models, this._worker, this._settings);

  final ModelSpec spec;
  final ModelManager _models;
  final OfflineWorker _worker;
  final Settings _settings;

  int? _pendingLoadMs;

  @override
  String get id => spec.id;

  @override
  String get displayName => spec.displayName;

  @override
  bool get isOnline => false;

  @override
  String get quantization => _models.installed(id)?.quantization ?? spec.quantization;

  bool get isInstalled => _models.isInstalled(id);

  @override
  Future<void> load() => _worker.exclusive(_load);

  Future<void> _load() async {
    final installed = _models.installed(id);
    if (installed == null) {
      throw SttException('${spec.displayName} is not downloaded. Get it in the Models tab.');
    }
    final threads = _settings.numThreads;
    final ms = await _worker.load(
      key: '$id#$threads',
      family: spec.family,
      files: installed.files,
      numThreads: threads,
    );
    if (ms != null) _pendingLoadMs = ms;
  }

  @override
  Future<SttResult> transcribe(AudioClip clip) => _worker.exclusive(() => _transcribe(clip));

  Future<SttResult> _transcribe(AudioClip clip) async {
    await _load();
    final loadMs = _pendingLoadMs;
    _pendingLoadMs = null;
    if (clip.isEmpty) {
      return SttResult(text: '', processingMs: 0, modelLoadMs: loadMs);
    }
    final r = await _worker.transcribe(clip.samples, clip.sampleRate);
    return SttResult(
      text: r.text,
      processingMs: r.ms,
      modelLoadMs: loadMs,
      metadata: {
        'runtime': 'sherpa-onnx',
        'family': spec.family,
        'threads': _settings.numThreads,
        'source': _models.installed(id)?.source ?? spec.sourceRepo,
      },
    );
  }

  @override
  Future<void> dispose() async {
    await _worker.exclusive(() async {
      if (_worker.loadedKey?.startsWith('$id#') ?? false) await _worker.unload();
    });
  }
}
