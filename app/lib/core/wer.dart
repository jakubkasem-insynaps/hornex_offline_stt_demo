/// WER / CER / word diff. Dart twin of tools/common/scoring.py.
library;

import 'normalization.dart';

enum DiffOp { ok, sub, del, ins }

class DiffItem {
  const DiffItem(this.op, this.ref, this.hyp);
  final DiffOp op;
  final String? ref;
  final String? hyp;
}

class EditCounts {
  const EditCounts({
    this.substitutions = 0,
    this.deletions = 0,
    this.insertions = 0,
    this.hits = 0,
  });

  final int substitutions;
  final int deletions;
  final int insertions;
  final int hits;

  int get errors => substitutions + deletions + insertions;
  int get refLength => substitutions + deletions + hits;

  /// Error rate, or null when the reference is empty.
  double? get rate => refLength == 0 ? null : errors / refLength;

  EditCounts operator +(EditCounts o) => EditCounts(
        substitutions: substitutions + o.substitutions,
        deletions: deletions + o.deletions,
        insertions: insertions + o.insertions,
        hits: hits + o.hits,
      );

  Map<String, dynamic> toJson() => {
        'substitutions': substitutions,
        'deletions': deletions,
        'insertions': insertions,
        'hits': hits,
      };
}

/// Levenshtein alignment of [ref] against [hyp].
List<DiffItem> align(List<String> ref, List<String> hyp) {
  final n = ref.length;
  final m = hyp.length;
  final d = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = 1; i <= n; i++) {
    d[i][0] = i;
  }
  for (var j = 1; j <= m; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= n; i++) {
    final ri = ref[i - 1];
    for (var j = 1; j <= m; j++) {
      final cost = ri == hyp[j - 1] ? 0 : 1;
      var best = d[i - 1][j - 1] + cost;
      if (d[i - 1][j] + 1 < best) best = d[i - 1][j] + 1;
      if (d[i][j - 1] + 1 < best) best = d[i][j - 1] + 1;
      d[i][j] = best;
    }
  }
  final ops = <DiffItem>[];
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    if (i > 0 && j > 0 && ref[i - 1] == hyp[j - 1] && d[i][j] == d[i - 1][j - 1]) {
      ops.add(DiffItem(DiffOp.ok, ref[i - 1], hyp[j - 1]));
      i--;
      j--;
    } else if (i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + 1) {
      ops.add(DiffItem(DiffOp.sub, ref[i - 1], hyp[j - 1]));
      i--;
      j--;
    } else if (i > 0 && d[i][j] == d[i - 1][j] + 1) {
      ops.add(DiffItem(DiffOp.del, ref[i - 1], null));
      i--;
    } else {
      ops.add(DiffItem(DiffOp.ins, null, hyp[j - 1]));
      j--;
    }
  }
  return ops.reversed.toList();
}

EditCounts countEdits(List<String> ref, List<String> hyp) {
  var s = 0, del = 0, ins = 0, hits = 0;
  for (final item in align(ref, hyp)) {
    switch (item.op) {
      case DiffOp.ok:
        hits++;
      case DiffOp.sub:
        s++;
      case DiffOp.del:
        del++;
      case DiffOp.ins:
        ins++;
    }
  }
  return EditCounts(substitutions: s, deletions: del, insertions: ins, hits: hits);
}

EditCounts wordCounts(String reference, String hypothesis) =>
    countEdits(normalizeWords(reference), normalizeWords(hypothesis));

EditCounts charCounts(String reference, String hypothesis) => countEdits(
    normalizeTranscript(reference).split(''),
    normalizeTranscript(hypothesis).split(''));

/// Word-level diff of two transcripts after normalization.
List<DiffItem> wordDiff(String reference, String hypothesis) =>
    align(normalizeWords(reference), normalizeWords(hypothesis));

bool isNoSpeech(String reference) => normalizeTranscript(reference).isEmpty;

/// (found, expected): for each term occurring in the reference, is it in the hypothesis?
(int, int) keyTermHits(String reference, String hypothesis, List<String> terms) {
  final ref = ' ${normalizeTranscript(reference)} ';
  final hyp = ' ${normalizeTranscript(hypothesis)} ';
  var found = 0, expected = 0;
  for (final term in terms) {
    final t = normalizeTranscript(term);
    if (t.isEmpty) continue;
    final needle = ' $t ';
    if (ref.contains(needle)) {
      expected++;
      if (hyp.contains(needle)) found++;
    }
  }
  return (found, expected);
}
