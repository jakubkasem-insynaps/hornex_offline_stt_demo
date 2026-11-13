import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../benchmark/benchmark_controller.dart';
import '../data/exporter.dart';
import '../data/paths.dart';
import '../engines/engine_registry.dart';
import 'widgets.dart';

class BenchmarkScreen extends StatefulWidget {
  const BenchmarkScreen({super.key});

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  List<String> _sets = [];
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final bench = context.read<BenchmarkController>();
    final sets = await bench.store.list();
    if (!mounted) return;
    setState(() => _sets = sets);
    if (bench.testSetName == null && sets.isNotEmpty) bench.update(() => bench.testSetName = sets.first);
  }

  Future<void> _importZip() async {
    final bench = context.read<BenchmarkController>();
    try {
      final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['zip']);
      if (picked == null) return;
      setState(() => _message = 'Importing ${picked.name}…');
      // Copy to a temp file first: the picker may hand back a stream, not a path.
      final tmp = File('${Directory.systemTemp.path}/import-${DateTime.now().millisecondsSinceEpoch}.zip');
      final sink = tmp.openWrite();
      await sink.addStream(picked.readAsByteStream());
      await sink.close();
      final name = await bench.store.importZip(tmp.path, picked.name);
      await tmp.delete();
      await _reload();
      bench.update(() => bench.testSetName = name);
      if (mounted) setState(() => _message = 'Imported "$name".');
    } catch (e) {
      if (mounted) setState(() => _message = 'Import failed: $e');
    }
  }

  Future<void> _export(String what) async {
    final bench = context.read<BenchmarkController>();
    final paths = context.read<AppPaths>();
    try {
      switch (what) {
        case 'summary':
          await exportAndShare(paths, 'benchmark-summary', 'csv', bench.summaryCsv());
        case 'clips':
          await exportAndShare(paths, 'benchmark-clips', 'csv', bench.clipsCsv());
        default:
          await exportAndShare(paths, 'benchmark', 'json', bench.resultsJson());
      }
    } catch (e) {
      if (mounted) setState(() => _message = 'Export failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bench = context.watch<BenchmarkController>();
    final registry = context.watch<EngineRegistry>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Benchmark'),
        actions: [
          if (bench.summaries.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.ios_share),
              onSelected: _export,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'summary', child: Text('Export summary CSV')),
                PopupMenuItem(value: 'clips', child: Text('Export per-clip CSV')),
                PopupMenuItem(value: 'json', child: Text('Export everything as JSON')),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(
              child: LabeledDropdown(
                label: 'Test set',
                value: bench.testSetName,
                items: {for (final s in _sets) s: s},
                onChanged: bench.running ? null : (v) => bench.update(() => bench.testSetName = v),
              ),
            ),
            IconButton(tooltip: 'Import zip', onPressed: bench.running ? null : _importZip, icon: const Icon(Icons.folder_zip_outlined)),
            IconButton(tooltip: 'Rescan', onPressed: _reload, icon: const Icon(Icons.refresh)),
          ]),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'A test set is a folder of clip.wav + clip.txt pairs (empty .txt = no-speech clip; optional terms.txt). '
              'Import a zip, or copy folders into ${bench.store.rootPath}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_message != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_message!, style: theme.textTheme.bodySmall)),
          const SizedBox(height: 12),
          Text('Engines', style: theme.textTheme.labelLarge),
          Wrap(
            spacing: 6,
            children: [
              for (final e in registry.offline)
                FilterChip(
                  label: Text(e.displayName),
                  selected: bench.selectedEngineIds.contains(e.id),
                  onSelected: bench.running || !e.isInstalled ? null : (_) => bench.toggleEngine(e.id),
                ),
              for (final e in registry.online)
                FilterChip(
                  avatar: const Icon(Icons.cloud_outlined, size: 16),
                  label: Text(e.displayName),
                  selected: bench.selectedEngineIds.contains(e.id),
                  onSelected: bench.running || !e.info.configured ? null : (_) => bench.toggleEngine(e.id),
                ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Run clips through VAD'),
            subtitle: const Text('On: same as the recording pipeline. Off: raw clip to the model (shows the model\'s own hallucinations).'),
            value: bench.useVad,
            onChanged: bench.running ? null : (v) => bench.update(() => bench.useVad = v),
          ),
          Row(children: [
            const Text('Clip limit'),
            const SizedBox(width: 12),
            DropdownButton<int>(
              value: bench.maxClips,
              items: const [
                DropdownMenuItem(value: 0, child: Text('All')),
                DropdownMenuItem(value: 10, child: Text('10')),
                DropdownMenuItem(value: 50, child: Text('50')),
                DropdownMenuItem(value: 100, child: Text('100')),
                DropdownMenuItem(value: 300, child: Text('300')),
              ],
              onChanged: bench.running ? null : (v) => bench.update(() => bench.maxClips = v ?? 0),
            ),
            const Spacer(),
            if (bench.running)
              OutlinedButton(onPressed: bench.cancel, child: const Text('Cancel'))
            else
              FilledButton.icon(onPressed: bench.run, icon: const Icon(Icons.play_arrow), label: const Text('Run')),
          ]),
          if (bench.running || bench.progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                if (bench.running)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Text(bench.progress),
              ]),
            ),
          if (bench.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(bench.error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (bench.summaries.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Results', style: theme.textTheme.titleMedium),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 18,
                columns: const [
                  DataColumn(label: Text('Engine')),
                  DataColumn(label: Text('WER'), numeric: true),
                  DataColumn(label: Text('CER'), numeric: true),
                  DataColumn(label: Text('Halluc.'), numeric: true),
                  DataColumn(label: Text('Key terms'), numeric: true),
                  DataColumn(label: Text('RTF'), numeric: true),
                  DataColumn(label: Text('Latency'), numeric: true),
                  DataColumn(label: Text('Peak mem'), numeric: true),
                  DataColumn(label: Text('Load'), numeric: true),
                  DataColumn(label: Text('Clips'), numeric: true),
                  DataColumn(label: Text('Errors'), numeric: true),
                ],
                rows: [
                  for (final s in bench.summaries)
                    DataRow(cells: [
                      DataCell(Text(s.engineName)),
                      DataCell(Text(fmtPct(s.wer))),
                      DataCell(Text(fmtPct(s.cer))),
                      DataCell(Text(s.noSpeechClips == 0 ? 'n/a' : fmtPct(s.hallucinationRate))),
                      DataCell(Text(s.keyExpected == 0 ? 'n/a' : fmtPct(s.keyTermAccuracy))),
                      DataCell(Text(fmtNum(s.rtf, 3))),
                      DataCell(Text(fmtMs(s.avgLatencyMs))),
                      DataCell(Text(s.peakRssBytes == null ? '–' : formatBytes(s.peakRssBytes!))),
                      DataCell(Text(fmtMs(s.modelLoadMs))),
                      DataCell(Text('${s.clips}')),
                      DataCell(Text('${s.errors}')),
                    ]),
                ],
              ),
            ),
            Text(
              'WER/CER over speech clips after shared normalization. Halluc. = share of no-speech clips that produced text. '
              'Peak mem is the whole app process.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (bench.cross.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Offline vs online (online transcript as reference)', style: theme.textTheme.titleSmall),
            for (final c in bench.cross)
              Text('${registry.byId(c.offlineId)?.displayName ?? c.offlineId}  vs  '
                  '${registry.byId(c.onlineId)?.displayName ?? c.onlineId}:  WER ${fmtPct(c.wer)}  (${c.clips} clips)'),
          ],
          if (bench.results.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Per clip', style: theme.textTheme.titleMedium),
            for (final r in bench.results.take(200))
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('${r.clip} · ${registry.byId(r.engineId)?.displayName ?? r.engineId}', style: theme.textTheme.bodyMedium),
                subtitle: Text(
                  r.error != null
                      ? 'error'
                      : r.noSpeech
                          ? (r.hallucinated ? 'no-speech clip: HALLUCINATED' : 'no-speech clip: silent, good')
                          : 'WER ${fmtPct(r.words.rate)} · CER ${fmtPct(r.chars.rate)} · RTF ${fmtNum(r.rtf, 3)}',
                  style: theme.textTheme.bodySmall,
                ),
                childrenPadding: const EdgeInsets.only(bottom: 12),
                children: [
                  if (r.error != null)
                    Text(r.error!, style: TextStyle(color: theme.colorScheme.error))
                  else
                    DiffView(
                      reference: r.reference,
                      hypothesis: r.hypothesis,
                      referenceLabel: 'Reference',
                      hypothesisLabel: 'Model output',
                    ),
                ],
              ),
            if (bench.results.length > 200)
              Text('Showing the first 200 rows; export for the rest.', style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
