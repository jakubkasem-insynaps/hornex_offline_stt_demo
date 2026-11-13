import 'package:flutter/material.dart';

import '../core/wer.dart';
import '../data/models.dart';
import '../data/paths.dart';

String fmtMs(num? ms) {
  if (ms == null) return '–';
  if (ms < 1000) return '${ms.round()} ms';
  return '${(ms / 1000).toStringAsFixed(2)} s';
}

String fmtPct(double? v) => v == null ? '–' : '${(v * 100).toStringAsFixed(1)} %';
String fmtNum(double? v, [int digits = 2]) => v == null ? '–' : v.toStringAsFixed(digits);
String fmtDuration(int ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String fmtDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// Small coloured label such as DRAFT / FINAL.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.6)),
      ),
      child: Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

/// Label + dropdown in an outlined box.
class LabeledDropdown extends StatelessWidget {
  const LabeledDropdown({super.key, required this.label, required this.value, required this.items, required this.onChanged});

  final String label;
  final String? value;
  final Map<String, String> items; // value -> text
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final current = items.containsKey(value) ? value : null;
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isExpanded: true,
          isDense: true,
          hint: Text(items.isEmpty ? 'None available' : 'Choose…'),
          items: [
            for (final e in items.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: onChanged == null
              ? null
              : (v) {
                  if (v != null) onChanged!(v);
                },
        ),
      ),
    );
  }
}

/// Key/value rows for the metrics of one transcription.
class MetricsTable extends StatelessWidget {
  const MetricsTable(this.t, {super.key});
  final TranscriptionRecord t;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Engine', '${t.engineName} (${t.engineId})'),
      ('Quantization', t.quantization),
      ('Device', '${t.deviceModel}, ${t.osVersion}'),
      ('Audio / speech', '${fmtMs(t.audioDurationMs)} / ${fmtMs(t.speechDurationMs)}'),
      ('Processing', fmtMs(t.processingMs)),
      ('RTF', fmtNum(t.rtf, 3)),
      ('Stop → text', fmtMs(t.endOfSpeechToFinalMs)),
      ('Model load', fmtMs(t.modelLoadMs)),
      ('Peak memory (app)', t.peakRssBytes == null ? '–' : formatBytes(t.peakRssBytes!)),
      if (t.isOnline) ('Network overhead', fmtMs(t.networkLatencyMs)),
      if (t.isOnline && t.metadata['providerMs'] != null) ('Provider time', fmtMs(t.metadata['providerMs'] as num)),
      if (t.note != null) ('Route', t.note!),
    ];
    final style = Theme.of(context).textTheme.bodySmall;
    return Column(
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 130, child: Text(k, style: style?.copyWith(color: Theme.of(context).hintColor))),
                Expanded(child: Text(v, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Two transcripts side by side with word-level differences marked.
/// [reference] is the online text, [hypothesis] the offline one.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.reference, required this.hypothesis, required this.referenceLabel, required this.hypothesisLabel});

  final String reference;
  final String hypothesis;
  final String referenceLabel;
  final String hypothesisLabel;

  @override
  Widget build(BuildContext context) {
    final diff = wordDiff(reference, hypothesis);
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.bodyMedium!;
    final changed = base.copyWith(color: scheme.error, fontWeight: FontWeight.w600);
    final added = base.copyWith(color: Colors.green.shade700, fontWeight: FontWeight.w600);
    final missing = base.copyWith(color: scheme.error, decoration: TextDecoration.lineThrough);

    final refSpans = <TextSpan>[];
    final hypSpans = <TextSpan>[];
    for (final d in diff) {
      switch (d.op) {
        case DiffOp.ok:
          refSpans.add(TextSpan(text: '${d.ref} ', style: base));
          hypSpans.add(TextSpan(text: '${d.hyp} ', style: base));
        case DiffOp.sub:
          refSpans.add(TextSpan(text: '${d.ref} ', style: changed));
          hypSpans.add(TextSpan(text: '${d.hyp} ', style: changed));
        case DiffOp.del:
          // In the reference, absent from the hypothesis.
          refSpans.add(TextSpan(text: '${d.ref} ', style: changed));
          hypSpans.add(TextSpan(text: '${d.ref} ', style: missing));
        case DiffOp.ins:
          hypSpans.add(TextSpan(text: '${d.hyp} ', style: added));
      }
    }
    final counts = EditCounts(
      substitutions: diff.where((d) => d.op == DiffOp.sub).length,
      deletions: diff.where((d) => d.op == DiffOp.del).length,
      insertions: diff.where((d) => d.op == DiffOp.ins).length,
      hits: diff.where((d) => d.op == DiffOp.ok).length,
    );

    Widget column(String label, List<TextSpan> spans) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              spans.isEmpty
                  ? Text('(empty)', style: base.copyWith(color: Theme.of(context).hintColor))
                  : SelectableText.rich(TextSpan(children: spans)),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [column(hypothesisLabel, hypSpans), const SizedBox(width: 12), column(referenceLabel, refSpans)],
        ),
        const SizedBox(height: 8),
        Text(
          'WER of "$hypothesisLabel" against "$referenceLabel": ${fmtPct(counts.rate)}  '
          '(${counts.substitutions} substituted, ${counts.deletions} missing, ${counts.insertions} extra; normalized text)',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
