import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/wav.dart';
import '../data/exporter.dart';
import '../data/history_store.dart';
import '../data/models.dart';
import '../data/paths.dart';
import '../engines/engine_registry.dart';
import '../engines/proxy_client.dart';
import '../pipeline/transcriber.dart';
import '../pipeline/upgrade_service.dart';
import 'widgets.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  Future<void> _export(BuildContext context, String ext) async {
    final history = context.read<HistoryStore>();
    final paths = context.read<AppPaths>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final contents = ext == 'csv' ? historyCsv(history.recordings) : historyJson(history.recordings);
      final file = await exportAndShare(paths, 'stt-history', ext, contents);
      messenger.showSnackBar(SnackBar(content: Text('Saved ${file.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = context.watch<HistoryStore>();
    final upgrades = context.watch<UpgradeService>();
    final items = history.recordings;
    final pending = items.where((r) => r.upgradeState == UpgradeState.pending).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results history'),
        actions: [
          if (pending > 0)
            TextButton.icon(
              onPressed: () => upgrades.retryPending(manual: true),
              icon: const Icon(Icons.cloud_sync_outlined),
              label: Text('Upgrade $pending'),
            ),
          PopupMenuButton<String>(
            onSelected: (v) => _export(context, v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('Export CSV')),
              PopupMenuItem(value: 'json', child: Text('Export JSON')),
            ],
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: items.isEmpty
          ? const Center(child: Text('No recordings yet.'))
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final r = items[i];
                final engines = r.transcriptions.map((t) => t.engineName).toSet().join(', ');
                return ListTile(
                  title: Text(
                    r.displayText.isEmpty ? '(no text)' : r.displayText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${fmtDate(r.createdAt)} · ${fmtDuration(r.durationMs)} · ${r.mode}\n$engines'),
                  isThreeLine: true,
                  trailing: switch (r.upgradeState) {
                    UpgradeState.pending => const Tag('DRAFT', color: Colors.orange),
                    UpgradeState.conflict => Tag('DECIDE', color: Theme.of(context).colorScheme.error),
                    _ => null,
                  },
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(builder: (_) => RecordingDetailScreen(recordingId: r.id)),
                  ),
                );
              },
            ),
    );
  }
}

class RecordingDetailScreen extends StatefulWidget {
  const RecordingDetailScreen({super.key, required this.recordingId});
  final String recordingId;

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  String? _busy;
  String? _error;
  ({String offline, String online})? _summaries;

  Future<void> _rerun(Recording r, String engineId) async {
    final registry = context.read<EngineRegistry>();
    final history = context.read<HistoryStore>();
    final engine = registry.byId(engineId);
    if (engine == null || r.audioPath == null) return;
    setState(() {
      _busy = 'Running ${engine.displayName}…';
      _error = null;
    });
    try {
      final audio = await readWavFile(r.audioPath!);
      final sw = Stopwatch()..start();
      final outcome = await runEngine(engine, clipsFromRanges(audio.samples, r.speechRanges));
      r.transcriptions.add(await buildRecord(
        engine: engine,
        outcome: outcome,
        audioDurationMs: r.durationMs,
        role: 'rerun',
        endOfSpeechToFinalMs: sw.elapsedMilliseconds,
        note: 're-run on saved audio',
      ));
      await history.save();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _summarize(String offline, String online) async {
    final proxy = context.read<ProxyClient>();
    setState(() {
      _busy = 'Summarising both transcripts…';
      _error = null;
    });
    try {
      final results = await Future.wait([proxy.summarize(offline), proxy.summarize(online)]);
      _summaries = (offline: results[0]['summary'] as String? ?? '', online: results[1]['summary'] as String? ?? '');
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = context.watch<HistoryStore>();
    final upgrades = context.watch<UpgradeService>();
    final registry = context.watch<EngineRegistry>();
    final r = history.byId(widget.recordingId);
    if (r == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Recording was deleted.')));
    }
    final offline = r.latest(online: false);
    final online = r.latest(online: true);
    final hasAudio = r.audioPath != null && File(r.audioPath!).existsSync();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(fmtDate(r.createdAt)),
        actions: [
          IconButton(
            tooltip: 'Delete recording',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final navigator = Navigator.of(context);
              await history.delete(r);
              navigator.pop();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            Tag(r.mode),
            Tag(fmtDuration(r.durationMs)),
            Tag(hasAudio ? 'audio kept · ${formatBytes(File(r.audioPath!).lengthSync())}' : 'audio deleted'),
            if (r.isDraft) const Tag('DRAFT', color: Colors.orange) else const Tag('FINAL', color: Colors.green),
          ]),
          const SizedBox(height: 12),
          SelectableText(r.displayText.isEmpty ? '(no text)' : r.displayText, style: theme.textTheme.bodyLarge),
          if (r.upgradeState == UpgradeState.conflict) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('The online transcript arrived after you edited the draft.'),
                  const SizedBox(height: 8),
                  Text('Online transcript', style: theme.textTheme.labelMedium),
                  SelectableText(r.pendingOnlineText ?? ''),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton(
                      onPressed: () => upgrades.resolveConflict(r, useOnline: false),
                      child: const Text('Keep my edit'),
                    ),
                    FilledButton(
                      onPressed: () => upgrades.resolveConflict(r, useOnline: true),
                      child: const Text('Use online'),
                    ),
                  ]),
                ]),
              ),
            ),
          ],
          if (r.upgradeState == UpgradeState.pending) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(r.upgradeError ?? 'Waiting to be upgraded online.', style: theme.textTheme.bodySmall)),
              TextButton(
                onPressed: upgrades.isRunning(r.id) ? null : () => upgrades.tryUpgrade(r),
                child: Text(upgrades.isRunning(r.id) ? 'Upgrading…' : 'Upgrade now'),
              ),
            ]),
          ],
          if (offline != null && online != null) ...[
            const Divider(height: 32),
            Text('Offline vs online', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            DiffView(
              reference: online.text,
              hypothesis: offline.text,
              referenceLabel: 'Online · ${online.engineName}',
              hypothesisLabel: 'Offline · ${offline.engineName}',
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _busy != null ? null : () => _summarize(offline.text, online.text),
                icon: const Icon(Icons.summarize_outlined),
                label: const Text('Compare LLM summaries'),
              ),
            ),
            if (_summaries != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _SummaryBox('Summary of offline', _summaries!.offline)),
                  const SizedBox(width: 12),
                  Expanded(child: _SummaryBox('Summary of online', _summaries!.online)),
                ]),
              ),
          ],
          const Divider(height: 32),
          Row(children: [
            Expanded(child: Text('Transcriptions (${r.transcriptions.length})', style: theme.textTheme.titleMedium)),
            if (hasAudio)
              PopupMenuButton<String>(
                enabled: _busy == null,
                onSelected: (id) => _rerun(r, id),
                itemBuilder: (_) => [
                  for (final e in registry.all) PopupMenuItem(value: e.id, child: Text(e.displayName)),
                ],
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.replay, size: 18), Text(' Run another engine')]),
                ),
              ),
          ]),
          if (_busy != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(_busy!),
              ]),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          for (final t in r.transcriptions.reversed)
            Card(
              margin: const EdgeInsets.only(top: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, children: [
                    Tag(t.role.toUpperCase()),
                    Tag(t.isOnline ? 'online' : 'offline'),
                  ]),
                  const SizedBox(height: 8),
                  SelectableText(t.text.isEmpty ? '(empty)' : t.text),
                  const SizedBox(height: 8),
                  MetricsTable(t),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryBox extends StatelessWidget {
  const _SummaryBox(this.title, this.text);
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      SelectableText(text.isEmpty ? '(empty)' : text),
    ]);
  }
}
