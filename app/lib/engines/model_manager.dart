import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/stt_engine.dart';
import '../data/paths.dart';
import '../data/settings.dart';
import 'model_catalog.dart';

class DownloadProgress {
  DownloadProgress(this.received, this.total, this.currentFile);
  final int received;
  final int? total;
  final String currentFile;
  double? get fraction => total == null || total == 0 ? null : received / total!;
}

/// What is on disk for an installed model (written after a verified download).
class InstalledModel {
  InstalledModel({required this.files, required this.quantization, required this.sizeBytes, this.source});
  final Map<String, String> files; // role -> absolute path
  final String quantization;
  final int sizeBytes;
  final String? source;
}

/// Downloads models on demand, reports size on disk, deletes them.
/// Models are never bundled with the app.
class ModelManager extends ChangeNotifier {
  ModelManager(this.catalog, this._paths, this._settings);

  final ModelCatalog catalog;
  final AppPaths _paths;
  final Settings _settings;

  final Map<String, DownloadProgress> _progress = {};
  final Map<String, String> _errors = {};
  final Set<String> _cancel = {};
  final Map<String, InstalledModel> _installed = {};

  static const _marker = 'installed.json';

  Directory _dir(String id) => Directory('${_paths.models.path}/$id');

  DownloadProgress? progressOf(String id) => _progress[id];
  String? errorOf(String id) => _errors[id];
  bool isDownloading(String id) => _progress.containsKey(id);
  bool isInstalled(String id) => _installed.containsKey(id);
  InstalledModel? installed(String id) => _installed[id];

  String get vadPath => '${_dir('silero-vad').path}/${catalog.vad.file}';
  bool get vadInstalled => File(vadPath).existsSync();

  /// Reads the install markers from disk.
  Future<void> refresh() async {
    // Build aside and swap at the end: readers must never see a half-filled map.
    final next = <String, InstalledModel>{};
    for (final spec in catalog.models) {
      final marker = File('${_dir(spec.id).path}/$_marker');
      if (!await marker.exists()) continue;
      try {
        final j = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        final files = <String, String>{};
        var ok = true;
        for (final f in (j['files'] as List)) {
          final path = '${_dir(spec.id).path}/${f['name']}';
          if (!File(path).existsSync()) ok = false;
          files[f['role'] as String] = path;
        }
        if (!ok) continue;
        next[spec.id] = InstalledModel(
          files: files,
          quantization: j['quantization'] as String? ?? spec.quantization,
          sizeBytes: await directorySize(_dir(spec.id)),
          source: j['source'] as String?,
        );
      } catch (_) {
        // Corrupt marker: treat as not installed.
      }
    }
    _installed
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  Map<String, String> get _hostHeaders =>
      _settings.proxyToken.isEmpty ? const {} : {'x-proxy-token': _settings.proxyToken};

  /// Makes sure the Silero VAD model is on disk (about 0.6 MB).
  Future<String> ensureVad() async {
    if (vadInstalled) return vadPath;
    await _dir('silero-vad').create(recursive: true);
    try {
      await _downloadFile(Uri.parse(catalog.vad.url), File(vadPath), const {}, (_) {}, () => false);
    } on SttException {
      rethrow;
    } catch (e) {
      throw SttException('Could not download the Silero VAD model (needed once, 0.6 MB): $e');
    }
    notifyListeners();
    return vadPath;
  }

  Future<void> download(String id) async {
    final spec = catalog.byId(id);
    if (spec == null || isDownloading(id)) return;
    _errors.remove(id);
    _cancel.remove(id);
    _progress[id] = DownloadProgress(0, spec.knownSize, 'preparing');
    notifyListeners();
    try {
      final dir = _dir(id);
      await dir.create(recursive: true);
      var files = spec.files;
      var quantization = spec.quantization;
      String source = spec.sourceRepo;
      var headers = const <String, String>{};
      String base = '';

      if (spec.selfHosted) {
        // The conversion script writes manifest.json next to the model files.
        base = '${_settings.effectiveModelHost}/models/$id';
        headers = _hostHeaders;
        final http.Response r;
        try {
          r = await http.get(Uri.parse('$base/manifest.json'), headers: headers).timeout(const Duration(seconds: 15));
        } catch (e) {
          throw SttException('Model host ${_settings.effectiveModelHost} is not reachable: $e');
        }
        if (r.statusCode == 404) {
          throw SttException(
              'This model has not been converted yet. Run ${spec.conversion} on a computer, then start the proxy so it serves models_out/.');
        }
        if (r.statusCode != 200) {
          throw SttException('Model host answered HTTP ${r.statusCode} for manifest.json');
        }
        final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        files = [for (final f in m['files'] as List) ModelFile.fromJson(f as Map<String, dynamic>)];
        quantization = m['quantization'] as String? ?? quantization;
        source = '${m['sourceRepo'] ?? spec.sourceRepo}@${m['sourceRevision'] ?? '?'}';
      }

      final total = files.every((f) => f.size != null) ? files.fold<int>(0, (n, f) => n + f.size!) : null;
      var done = 0;
      for (final f in files) {
        final target = File('${dir.path}/${f.name}');
        final uri = Uri.parse(f.url ?? '$base/${f.name}');
        if (!(await target.exists() && f.size != null && await target.length() == f.size)) {
          await _downloadFile(uri, target, headers, (received) {
            _progress[id] = DownloadProgress(done + received, total, f.name);
            notifyListeners();
          }, () => _cancel.contains(id));
        }
        if (f.sha256 != null) {
          _progress[id] = DownloadProgress(done + (f.size ?? 0), total, 'verifying ${f.name}');
          notifyListeners();
          final digest = (await sha256.bind(target.openRead()).first).toString();
          if (digest != f.sha256) {
            await target.delete();
            throw SttException('Checksum mismatch for ${f.name}; the download was discarded.');
          }
        }
        done += await target.length();
      }
      await File('${dir.path}/$_marker').writeAsString(jsonEncode({
        'id': id,
        'quantization': quantization,
        'source': source,
        'installedAt': DateTime.now().toIso8601String(),
        'files': [for (final f in files) f.toJson()],
      }));
    } on _Cancelled {
      _errors[id] = 'Download cancelled';
    } catch (e) {
      _errors[id] = e.toString();
    } finally {
      _progress.remove(id);
      _cancel.remove(id);
      await refresh();
    }
  }

  void cancel(String id) => _cancel.add(id);

  Future<void> delete(String id) async {
    final dir = _dir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    _errors.remove(id);
    await refresh();
  }

  /// Streams [uri] into [target] via a `.part` file, resuming a partial download.
  Future<void> _downloadFile(
    Uri uri,
    File target,
    Map<String, String> headers,
    void Function(int received) onProgress,
    bool Function() cancelled,
  ) async {
    final part = File('${target.path}.part');
    var offset = await part.exists() ? await part.length() : 0;
    final client = http.Client();
    try {
      final req = http.Request('GET', uri)..headers.addAll(headers);
      if (offset > 0) req.headers['Range'] = 'bytes=$offset-';
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        offset = 0; // server ignored the range: start over
      } else if (resp.statusCode != 206) {
        throw SttException('HTTP ${resp.statusCode} for ${uri.path.split('/').last}');
      }
      final sink = part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
      var received = offset;
      var lastReport = 0;
      try {
        await for (final chunk in resp.stream) {
          if (cancelled()) throw _Cancelled();
          sink.add(chunk);
          received += chunk.length;
          if (received - lastReport > 512 * 1024) {
            lastReport = received;
            onProgress(received);
          }
        }
      } finally {
        await sink.close();
      }
      await part.rename(target.path);
    } finally {
      client.close();
    }
  }
}

class _Cancelled implements Exception {}
