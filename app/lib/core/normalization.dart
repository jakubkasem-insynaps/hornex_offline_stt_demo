/// Slovak transcript normalization for scoring.
///
/// Dart twin of tools/common/normalization.py. Both use the rule data from
/// shared/normalization/sk_rules.json (here via normalization_rules.g.dart) and
/// must pass shared/normalization/test_vectors.json. See the Python module for
/// the step-by-step description; keep the two in step.
library;

import 'normalization_rules.g.dart';

final RegExp _thousandsGroup =
    RegExp(r'(?<![0-9])[0-9]{1,3}(?:[  .][0-9]{3})+(?![0-9])');
final RegExp _groupSeparator = RegExp(r'[  .]');
final RegExp _notLetterOrNumber = RegExp(r'[^\p{L}\p{N}]', unicode: true);
final RegExp _asciiDigits = RegExp(r'^[0-9]+$');

/// Words a compound numeral may be built from, longest first.
final List<String> _atoms = () {
  final set = <String>{
    ...kNormUnits.skip(1),
    ...kNormTeens,
    ...kNormTens.where((t) => t.isNotEmpty),
    kNormHundred,
    kNormThousand,
    ...kNormVariants.keys.where((v) => kNormVariants[v] != kNormMillion),
  };
  final list = set.toList()
    ..sort((a, b) {
      final byLength = b.length.compareTo(a.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
  return list;
}();

String _compose(String text) {
  var out = text;
  kNormCompose.forEach((pair, single) {
    if (out.contains(pair)) out = out.replaceAll(pair, single);
  });
  return out;
}

List<String> _below1000(int n) {
  final out = <String>[];
  final h = n ~/ 100;
  final r = n % 100;
  if (h == 1) {
    out.add(kNormHundred);
  } else if (h > 1) {
    out
      ..add(kNormUnits[h])
      ..add(kNormHundred);
  }
  if (r == 0) return out;
  if (r < 10) {
    out.add(kNormUnits[r]);
  } else if (r < 20) {
    out.add(kNormTeens[r - 10]);
  } else {
    out.add(kNormTens[r ~/ 10]);
    if (r % 10 != 0) out.add(kNormUnits[r % 10]);
  }
  return out;
}

/// Spells a string of ASCII digits as canonical Slovak numeral atoms.
List<String> spellNumber(String digits) {
  if (digits.length > kNormMaxSpelledDigits ||
      (digits.length > 1 && digits.startsWith('0'))) {
    return [for (final d in digits.split('')) kNormUnits[int.parse(d)]];
  }
  final n = int.parse(digits);
  if (n == 0) return [kNormUnits[0]];
  final out = <String>[];
  final millions = n ~/ 1000000;
  final thousands = (n % 1000000) ~/ 1000;
  final rest = n % 1000;
  if (millions == 1) {
    out.add(kNormMillion);
  } else if (millions > 1) {
    out
      ..addAll(_below1000(millions))
      ..add(kNormMillion);
  }
  if (thousands == 1) {
    out.add(kNormThousand);
  } else if (thousands > 1) {
    out
      ..addAll(_below1000(thousands))
      ..add(kNormThousand);
  }
  out.addAll(_below1000(rest));
  return out;
}

/// Splits [word] into numeral atoms if it consists of two or more of them.
List<String>? _splitCompound(String word) {
  final n = word.length;
  // best[i] = fewest atoms covering word.substring(i), or null if impossible.
  final best = List<List<String>?>.filled(n + 1, null);
  best[n] = const <String>[];
  for (var i = n - 1; i >= 0; i--) {
    for (final atom in _atoms) {
      if (word.startsWith(atom, i)) {
        final tail = best[i + atom.length];
        if (tail != null &&
            (best[i] == null || tail.length + 1 < best[i]!.length)) {
          best[i] = [atom, ...tail];
        }
      }
    }
  }
  final result = best[0];
  if (result == null || result.length < 2) return null;
  return result;
}

/// Normalizes [text] for scoring. Keeps Slovak diacritics.
String normalizeTranscript(String text) {
  var t = text.toLowerCase();
  t = _compose(t);
  t = t.replaceAllMapped(
      _thousandsGroup, (m) => m.group(0)!.replaceAll(_groupSeparator, ''));
  t = t.replaceAll(_notLetterOrNumber, ' ');
  final out = <String>[];
  for (final token in t.split(' ')) {
    if (token.isEmpty) continue;
    if (_asciiDigits.hasMatch(token)) {
      out.addAll(spellNumber(token));
      continue;
    }
    final parts = _splitCompound(token) ?? [token];
    for (final p in parts) {
      out.add(kNormVariants[p] ?? p);
    }
  }
  return out.join(' ');
}

List<String> normalizeWords(String text) {
  final n = normalizeTranscript(text);
  return n.isEmpty ? const <String>[] : n.split(' ');
}
