import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../engines/model_manager.dart';

/// Attributions and licenses. CC-BY-4.0 models (Parakeet) require attribution.
class AttributionsScreen extends StatelessWidget {
  const AttributionsScreen({super.key});

  static const _software = <(String, String, String)>[
    ('sherpa-onnx', 'Apache-2.0', 'On-device speech recognition and VAD runtime by the k2-fsa project (Xiaomi Corporation).'),
    ('ONNX Runtime', 'MIT', 'Inference engine by Microsoft, used by sherpa-onnx.'),
    ('OpenAI Whisper', 'MIT', 'Model architecture and base weights by OpenAI.'),
    ('NVIDIA NeMo / Parakeet TDT', 'Apache-2.0 (toolkit), CC-BY-4.0 (models)', 'Model architecture and base weights by NVIDIA.'),
  ];

  static const _data = <(String, String, String)>[
    ('Mozilla Common Voice (Slovak)', 'CC0-1.0', 'Test clips, if you import them. Distributed by Mozilla Data Collective; its terms forbid re-hosting and speaker re-identification.'),
    ('Google FLEURS (sk_sk)', 'CC-BY-4.0', 'Test clips, if you import them. Conneau et al., "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech".'),
  ];

  @override
  Widget build(BuildContext context) {
    final catalog = context.read<ModelManager>().catalog;
    final theme = Theme.of(context);

    Widget entry(String title, String license, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleSmall),
            Text('License: $license', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            Text(text, style: theme.textTheme.bodySmall),
          ]),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Attributions & licenses'),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(context: context, applicationName: 'Slovak STT demo'),
            child: const Text('Packages'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Speech models', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final m in catalog.models) entry('${m.displayName}  ·  ${m.sourceRepo}', m.license, m.attribution),
          entry(catalog.vad.file, catalog.vad.license, catalog.vad.attribution),
          const Divider(height: 24),
          Text('Software', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (t, l, d) in _software) entry(t, l, d),
          const Divider(height: 24),
          Text('Test data', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (t, l, d) in _data) entry(t, l, d),
          Text(
            'Cloud providers (Soniox, ElevenLabs, Speechmatics, OpenAI, Google, Deepgram) are reached through the '
            'backend proxy under your own accounts and their terms.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
