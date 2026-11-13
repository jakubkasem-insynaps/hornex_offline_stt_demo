import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class ModelFile {
  ModelFile({required this.role, required this.name, this.url, this.size, this.sha256});

  factory ModelFile.fromJson(Map<String, dynamic> j) => ModelFile(
        role: j['role'] as String? ?? 'other',
        name: j['name'] as String,
        url: j['url'] as String?,
        size: (j['size'] as num?)?.toInt(),
        sha256: j['sha256'] as String?,
      );

  /// encoder | decoder | joiner | tokens
  final String role;
  final String name;
  final String? url;
  final int? size;
  final String? sha256;

  Map<String, dynamic> toJson() => {
        'role': role,
        'name': name,
        if (url != null) 'url': url,
        if (size != null) 'size': size,
        if (sha256 != null) 'sha256': sha256,
      };
}

class ModelSpec {
  ModelSpec({
    required this.id,
    required this.displayName,
    required this.family,
    required this.sourceRepo,
    required this.license,
    required this.attribution,
    required this.quantization,
    required this.note,
    required this.hosting,
    required this.files,
    this.conversion,
  });

  factory ModelSpec.fromJson(Map<String, dynamic> j) => ModelSpec(
        id: j['id'] as String,
        displayName: j['displayName'] as String,
        family: j['family'] as String,
        sourceRepo: j['sourceRepo'] as String? ?? '',
        license: j['license'] as String? ?? '',
        attribution: j['attribution'] as String? ?? '',
        quantization: j['quantization'] as String? ?? 'unknown',
        note: j['note'] as String? ?? '',
        hosting: j['hosting'] as String? ?? 'url',
        conversion: j['conversion'] as String?,
        files: [
          for (final f in (j['files'] as List? ?? const []))
            ModelFile.fromJson(f as Map<String, dynamic>)
        ],
      );

  final String id;
  final String displayName;

  /// whisper | nemo_transducer
  final String family;
  final String sourceRepo;
  final String license;
  final String attribution;
  final String quantization;
  final String note;

  /// url: download from the listed URLs. self: download from the model host
  /// (`<host>/models/<id>/`), which serves the output of the conversion script.
  final String hosting;
  final String? conversion;
  final List<ModelFile> files;

  bool get selfHosted => hosting == 'self';

  /// Download size if the catalog knows it (self-hosted sizes come from the manifest).
  int? get knownSize {
    var total = 0;
    for (final f in files) {
      if (f.size == null) return null;
      total += f.size!;
    }
    return total;
  }
}

class VadSpec {
  VadSpec({required this.file, required this.url, required this.license, required this.attribution, this.size});
  final String file;
  final String url;
  final String license;
  final String attribution;
  final int? size;
}

class ModelCatalog {
  ModelCatalog(this.models, this.vad);

  final List<ModelSpec> models;
  final VadSpec vad;

  static Future<ModelCatalog> load() async =>
      parse(await rootBundle.loadString('assets/models.json'));

  static ModelCatalog parse(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    final v = j['vad'] as Map<String, dynamic>;
    return ModelCatalog(
      [for (final m in j['models'] as List) ModelSpec.fromJson(m as Map<String, dynamic>)],
      VadSpec(
        file: v['file'] as String,
        url: v['url'] as String,
        license: v['license'] as String? ?? '',
        attribution: v['attribution'] as String? ?? '',
        size: (v['size'] as num?)?.toInt(),
      ),
    );
  }

  ModelSpec? byId(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }
}
