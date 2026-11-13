import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/history_store.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../engines/engine_registry.dart';
import '../pipeline/record_controller.dart';
import '../pipeline/upgrade_service.dart';
import 'widgets.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  final _draftController = TextEditingController();
  String? _boundRecordingId;
  bool _conflictDialogOpen = false;

  @override
  void dispose() {
    _draftController.dispose();
    super.dispose();
  }

  void _bindDraft(Recording? rec) {
    if (rec == null || rec.draftText == null || rec.id == _boundRecordingId) return;
    _boundRecordingId = rec.id;
    _draftController.text = rec.editedText ?? rec.draftText ?? '';
  }

  Future<void> _askConflict(Recording rec) async {
    if (_conflictDialogOpen) return;
    _conflictDialogOpen = true;
    final upgrades = context.read<UpgradeService>();
    final useOnline = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Online transcript is ready'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('You edited the draft. Which text do you want to keep?'),
              const SizedBox(height: 12),
              Text('Your edited draft', style: Theme.of(context).textTheme.labelMedium),
              Text(rec.editedText ?? ''),
              const SizedBox(height: 12),
              Text('Online transcript', style: Theme.of(context).textTheme.labelMedium),
              Text(rec.pendingOnlineText ?? ''),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep my edit')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use online')),
        ],
      ),
    );
    _conflictDialogOpen = false;
    if (useOnline != null) await upgrades.resolveConflict(rec, useOnline: useOnline);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final registry = context.watch<EngineRegistry>();
    final rc = context.watch<RecordController>();
    final upgrades = context.watch<UpgradeService>();
    context.watch<HistoryStore>();

    final rec = rc.current;
    _bindDraft(rec);
    if (rec != null && rec.upgradeState == UpgradeState.conflict) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _askConflict(rec);
      });
    }

    final busy = rc.state != RecordState.idle;
    final recording = rc.state == RecordState.recording;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Mode', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final m in SttMode.values)
              ChoiceChip(
                label: Text(m.label),
                selected: settings.mode == m,
                onSelected: busy ? null : (_) => settings.mode = m,
              ),
          ],
        ),
        const SizedBox(height: 12),
        LabeledDropdown(
          label: 'Offline model',
          value: settings.offlineEngineId,
          items: {
            for (final e in registry.offline) e.id: e.isInstalled ? e.displayName : '${e.displayName} (not downloaded)',
          },
          onChanged: busy ? null : (v) => settings.offlineEngineId = v,
        ),
        const SizedBox(height: 12),
        LabeledDropdown(
          label: 'Online model',
          value: settings.onlineEngineId,
          items: {
            for (final e in registry.online) e.id: e.info.configured ? e.displayName : '${e.displayName} (no key on proxy)',
          },
          onChanged: busy ? null : (v) => settings.onlineEngineId = v,
        ),
        if (registry.online.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'No online engines yet. Set the proxy URL in Settings and tap "Test connection".',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Simulate offline'),
          subtitle: const Text('Forces the on-device path; upgrades wait'),
          value: settings.simulateOffline,
          onChanged: busy ? null : (v) => settings.simulateOffline = v,
        ),
        const SizedBox(height: 8),
        Center(
          child: SizedBox(
            width: 200,
            height: 64,
            child: FilledButton.icon(
              style: recording ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
              onPressed: rc.state == RecordState.processing || rc.state == RecordState.starting
                  ? null
                  : (recording ? rc.stop : rc.start),
              icon: Icon(recording ? Icons.stop : Icons.mic),
              label: Text(recording ? 'Stop' : 'Record'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (rc.state == RecordState.processing || rc.state == RecordState.starting)
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            Text(rc.status),
            if (recording) ...[
              const SizedBox(width: 12),
              Text(fmtDuration(rc.elapsed.inMilliseconds)),
              const SizedBox(width: 12),
              Icon(Icons.graphic_eq, size: 18, color: rc.speechActive ? Colors.green : Theme.of(context).disabledColor),
              Text(rc.speechActive ? ' speech' : ' silence', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(width: 12),
              Text('${rc.chunkCount} chunks', style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
        if (rc.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(rc.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        if (busy && rc.liveText.isNotEmpty)
          _TranscriptCard(
            tags: const [Tag('DRAFT · live', color: Colors.orange)],
            child: SelectableText(rc.liveText),
          )
        else if (rec != null && !busy)
          _buildResult(context, rec, rc, upgrades),
      ],
    );
  }

  Widget _buildResult(BuildContext context, Recording rec, RecordController rc, UpgradeService upgrades) {
    final offline = rec.latest(online: false);
    final online = rec.latest(online: true);
    final isDraft = rec.isDraft;
    final shown = isDraft ? offline : (rec.transcriptions.isEmpty ? null : rec.transcriptions.last);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TranscriptCard(
          tags: [
            isDraft ? const Tag('DRAFT', color: Colors.orange) : const Tag('FINAL', color: Colors.green),
            if (shown != null) Tag(shown.isOnline ? 'online · ${shown.engineName}' : 'offline · ${shown.engineName}'),
            if (rec.draftWasEdited && isDraft) const Tag('edited'),
            if (!isDraft && rec.draftText != null && rec.finalText == rec.editedText && rec.draftWasEdited)
              const Tag('kept your edit'),
          ],
          child: isDraft
              ? TextField(
                  controller: _draftController,
                  maxLines: null,
                  decoration: const InputDecoration(border: InputBorder.none, hintText: '(no speech detected)'),
                  onChanged: (v) => rc.editDraft(rec, v),
                )
              : SelectableText(rec.displayText.isEmpty ? '(no speech detected)' : rec.displayText),
        ),
        if (rec.upgradeState == UpgradeState.pending)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                if (upgrades.isRunning(rec.id))
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Expanded(
                  child: Text(
                    upgrades.isRunning(rec.id)
                        ? 'Fetching the online transcript…'
                        : (rec.upgradeError ?? 'Waiting for a connection to upgrade this draft.'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: upgrades.isRunning(rec.id) ? null : () => upgrades.tryUpgrade(rec),
                  child: const Text('Retry now'),
                ),
              ],
            ),
          ),
        if (shown != null) ...[
          const SizedBox(height: 12),
          MetricsTable(shown),
        ],
        if (offline != null && online != null) ...[
          const Divider(height: 32),
          DiffView(
            reference: online.text,
            hypothesis: offline.text,
            referenceLabel: 'Online · ${online.engineName}',
            hypothesisLabel: 'Offline · ${offline.engineName}',
          ),
        ],
      ],
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  const _TranscriptCard({required this.tags, required this.child});
  final List<Widget> tags;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 6, runSpacing: 6, children: tags),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
