import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'paths.dart';

/// Recordings and their transcription metrics, kept in one JSON file.
class HistoryStore extends ChangeNotifier {
  HistoryStore(this._paths);

  final AppPaths _paths;
  final List<Recording> _items = [];
  Timer? _saveTimer;
  Future<void> _saving = Future.value();

  File get _file => File('${_paths.data.path}/history.json');

  /// Newest first.
  List<Recording> get recordings => List.unmodifiable(_items);

  Recording? byId(String id) {
    for (final r in _items) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    _items.clear();
    if (await _file.exists()) {
      try {
        final j = jsonDecode(await _file.readAsString()) as List;
        _items.addAll(j.map((e) => Recording.fromJson(e as Map<String, dynamic>)));
      } catch (e) {
        // Keep the unreadable file for inspection instead of overwriting it.
        await _file.rename('${_file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    notifyListeners();
  }

  Future<void> add(Recording r) async {
    _items.insert(0, r);
    await save();
  }

  /// Persist after a recording was changed in place.
  /// Saves are queued one after another so two never share the temp file.
  Future<void> save() {
    _saveTimer?.cancel();
    notifyListeners();
    return _saving = _saving.catchError((Object _) {}).then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode([for (final r in _items) r.toJson()]), flush: true);
      await tmp.rename(_file.path);
    });
  }

  /// Persist soon; for changes that arrive on every keystroke.
  void saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), save);
  }

  Future<void> deleteAudio(Recording r) async {
    final p = r.audioPath;
    if (p != null) {
      final f = File(p);
      if (await f.exists()) await f.delete();
      r.audioPath = null;
    }
  }

  Future<void> delete(Recording r) async {
    await deleteAudio(r);
    _items.remove(r);
    await save();
  }

  Future<void> clear() async {
    for (final r in List.of(_items)) {
      await deleteAudio(r);
    }
    _items.clear();
    await save();
  }
}
