import 'dart:io';

import 'package:archive/archive_io.dart';

import '../data/paths.dart';

class TestClip {
  TestClip(this.name, this.audioPath, this.reference);
  final String name;
  final String audioPath;

  /// Reference transcript; empty for a no-speech clip.
  final String reference;
}

class TestSet {
  TestSet(this.name, this.clips, this.keyTerms);
  final String name;
  final List<TestClip> clips;

  /// From an optional `terms.txt` in the set folder, one term per line.
  final List<String> keyTerms;
}

/// Test sets are folders of `<clip>.wav` + `<clip>.txt` (16 kHz mono WAV; an
/// empty .txt marks a no-speech clip). tools/datasets/download_testsets.py
/// produces this layout from Common Voice and FLEURS.
class TestSetStore {
  TestSetStore(this._paths);
  final AppPaths _paths;

  String get rootPath => _paths.testSets.path;

  Future<List<String>> list() async {
    final names = <String>[];
    await for (final e in _paths.testSets.list()) {
      if (e is Directory) names.add(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
    }
    names.sort();
    return names;
  }

  Future<TestSet> load(String name) async {
    final dir = Directory('${_paths.testSets.path}/$name');
    final clips = <TestClip>[];
    var terms = <String>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final path = e.path;
      final lower = path.toLowerCase();
      if (lower.endsWith('terms.txt')) {
        terms = (await e.readAsString()).split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      } else if (lower.endsWith('.wav')) {
        final txt = File('${path.substring(0, path.length - 4)}.txt');
        if (!await txt.exists()) continue; // audio without a reference is skipped
        final file = e.uri.pathSegments.last;
        clips.add(TestClip(file.substring(0, file.length - 4), path, (await txt.readAsString()).trim()));
      }
    }
    clips.sort((a, b) => a.name.compareTo(b.name));
    return TestSet(name, clips, terms);
  }

  /// Unpacks a zip of a test-set folder into the test-set directory.
  Future<String> importZip(String zipPath, String suggestedName) async {
    var name = suggestedName.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    if (name.toLowerCase().endsWith('.zip')) name = name.substring(0, name.length - 4);
    if (name.isEmpty) name = 'testset';
    final target = Directory('${_paths.testSets.path}/$name');
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    await extractFileToDisk(zipPath, target.path);
    return name;
  }

  Future<void> delete(String name) async {
    final dir = Directory('${_paths.testSets.path}/$name');
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
