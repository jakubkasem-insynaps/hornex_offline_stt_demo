import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/paths.dart';
import '../data/settings.dart';
import '../engines/model_catalog.dart';
import '../engines/model_manager.dart';

/// Model Manager: download on demand, size on disk, delete.
class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final models = context.watch<ModelManager>();
    final settings = context.watch<Settings>();
    final total = models.catalog.models.fold<int>(0, (n, m) => n + (models.installed(m.id)?.sizeBytes ?? 0));

    return Scaffold(
      appBar: AppBar(title: const Text('Model Manager')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'Models are not bundled with the app. On disk: ${formatBytes(total)}.\n'
            'Self-converted models are fetched from ${settings.effectiveModelHost}/models/.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: const Text('Silero VAD'),
              subtitle: Text(models.vadInstalled ? 'Installed · needed by every mode' : 'Downloaded automatically on first recording (0.6 MB)'),
              trailing: models.vadInstalled
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          await models.ensureVad();
                        } catch (e) {
                          messenger.showSnackBar(SnackBar(content: Text('$e')));
                        }
                      },
                    ),
            ),
          ),
          for (final spec in models.catalog.models) _ModelCard(spec),
        ],
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard(this.spec);
  final ModelSpec spec;

  @override
  Widget build(BuildContext context) {
    final models = context.watch<ModelManager>();
    final installed = models.installed(spec.id);
    final progress = models.progressOf(spec.id);
    final error = models.errorOf(spec.id);
    final small = Theme.of(context).textTheme.bodySmall;

    final String sizeText;
    if (installed != null) {
      sizeText = '${formatBytes(installed.sizeBytes)} on disk';
    } else if (spec.knownSize != null) {
      sizeText = '${formatBytes(spec.knownSize!)} download';
    } else {
      sizeText = 'size known after conversion';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(spec.displayName, style: Theme.of(context).textTheme.titleSmall)),
                if (installed != null) const Icon(Icons.check_circle, color: Colors.green, size: 20),
              ],
            ),
            const SizedBox(height: 4),
            Text('${spec.sourceRepo} · ${spec.license}', style: small),
            Text('$sizeText · ${installed?.quantization ?? spec.quantization}', style: small),
            if (spec.note.isNotEmpty) Text(spec.note, style: small),
            if (spec.selfHosted && installed == null)
              Text('Needs ${spec.conversion} to be run on a computer first.', style: small),
            if (progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(
                '${progress.currentFile} · ${formatBytes(progress.received)}'
                '${progress.total == null ? '' : ' of ${formatBytes(progress.total!)}'}',
                style: small,
              ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(error, style: small?.copyWith(color: Theme.of(context).colorScheme.error)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: progress != null
                  ? TextButton(onPressed: () => models.cancel(spec.id), child: const Text('Cancel'))
                  : installed != null
                      ? TextButton.icon(
                          onPressed: () => models.delete(spec.id),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                        )
                      : FilledButton.tonalIcon(
                          onPressed: () => models.download(spec.id),
                          icon: const Icon(Icons.download),
                          label: const Text('Download'),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
