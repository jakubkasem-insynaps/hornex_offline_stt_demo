import 'dart:convert';
import 'dart:io';

import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'paths.dart';

String csvCell(Object? v) {
  if (v == null) return '';
  final s = v is double ? v.toStringAsFixed(4) : v.toString();
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String toCsv(List<String> header, Iterable<List<Object?>> rows) {
  final b = StringBuffer()..writeln(header.map(csvCell).join(','));
  for (final r in rows) {
    b.writeln(r.map(csvCell).join(','));
  }
  return b.toString();
}

const _historyHeader = [
  'recording_id', 'recorded_at', 'mode', 'transcription_id', 'role', 'engine_id', 'engine_name', 'online',
  'quantization', 'device_model', 'os_version', 'audio_duration_ms', 'speech_duration_ms', 'processing_ms',
  'rtf', 'end_of_speech_to_final_ms', 'model_load_ms', 'peak_rss_bytes', 'network_latency_ms', 'note', 'text',
  'metadata_json',
];

/// One row per transcription.
String historyCsv(List<Recording> recordings) => toCsv(_historyHeader, [
      for (final r in recordings)
        for (final t in r.transcriptions)
          [
            r.id, r.createdAt.toIso8601String(), r.mode, t.id, t.role, t.engineId, t.engineName, t.isOnline,
            t.quantization, t.deviceModel, t.osVersion, t.audioDurationMs, t.speechDurationMs, t.processingMs,
            t.rtf, t.endOfSpeechToFinalMs, t.modelLoadMs, t.peakRssBytes, t.networkLatencyMs, t.note, t.text,
            jsonEncode(t.metadata),
          ],
    ]);

String historyJson(List<Recording> recordings) =>
    const JsonEncoder.withIndent('  ').convert([for (final r in recordings) r.toJson()]);

String _stamp() => DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-').substring(0, 19);

/// Writes [contents] under the exports folder and opens the share sheet.
Future<File> exportAndShare(AppPaths paths, String baseName, String extension, String contents) async {
  final file = File('${paths.exports.path}/$baseName-${_stamp()}.$extension');
  // BOM so spreadsheet apps read Slovak diacritics in CSV correctly.
  await file.writeAsString(extension == 'csv' ? '﻿$contents' : contents, flush: true);
  await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: file.uri.pathSegments.last));
  return file;
}
