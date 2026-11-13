// Run from app/:  flutter test
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stt_demo/core/normalization.dart';
import 'package:stt_demo/core/wav.dart';
import 'package:stt_demo/core/wer.dart';
import 'package:stt_demo/engines/model_catalog.dart';
import 'package:stt_demo/engines/offline_worker.dart';

void main() {
  group('normalization', () {
    // The same vectors are run against the Python implementation
    // (tools/tests/test_normalization.py). Both must agree.
    final vectors = jsonDecode(File('../shared/normalization/test_vectors.json').readAsStringSync()) as Map<String, dynamic>;
    for (final c in vectors['cases'] as List) {
      final source = (c as List)[0] as String;
      final expected = c[1] as String;
      test('"$source"', () {
        expect(normalizeTranscript(source), expected);
        expect(normalizeTranscript(expected), expected, reason: 'idempotent');
      });
    }
  });

  group('scoring', () {
    test('counts substitutions, deletions, insertions', () {
      final c = wordCounts('Dnes je pekný deň.', 'dnes bol pekný deň dnes');
      expect([c.substitutions, c.deletions, c.insertions, c.hits], [1, 0, 1, 3]);
      expect(c.rate, closeTo(0.5, 1e-9));
    });

    test('digits and spelled-out numbers match', () {
      expect(wordCounts('Mám 21 rokov', 'mám dvadsaťjeden rokov').errors, 0);
    });

    test('empty reference has no rate and marks no-speech', () {
      final c = wordCounts('', 'nejaký text');
      expect(c.rate, isNull);
      expect(c.insertions, 2);
      expect(isNoSpeech(' ... '), isTrue);
    });

    test('key terms', () {
      final (found, expected) = keyTermHits(
          'Pacient užíva Paralen a Ibalgin.', 'pacient užíva paralen a ibalgín', ['Paralen', 'Ibalgin', 'Aspirin']);
      expect([found, expected], [1, 2]);
    });

    test('word diff lines up', () {
      final d = wordDiff('a b c', 'a x c d');
      expect(d.map((e) => e.op).toList(), [DiffOp.ok, DiffOp.sub, DiffOp.ok, DiffOp.ins]);
    });
  });

  group('whisper silence padding', () {
    test('appends half the length as silence and keeps the audio', () {
      final audio = Float32List.fromList(List.filled(16000, 0.5));
      final padded = padWithSilence(audio, 16000);
      expect(padded.length, 24000);
      expect(padded.sublist(0, 16000).every((v) => v == 0.5), isTrue);
      expect(padded.sublist(16000).every((v) => v == 0), isTrue);
    });
    test('never exceeds the 28 s window', () {
      expect(padWithSilence(Float32List(25 * 16000), 16000).length, kMaxWindowSeconds * 16000);
      final full = Float32List(kMaxWindowSeconds * 16000);
      expect(identical(padWithSilence(full, 16000), full), isTrue);
    });
  });

  group('wav', () {
    test('round trip keeps samples', () {
      final samples = Float32List.fromList([0, 0.5, -0.5, 0.25, -1, 1]);
      final clip = decodeWav(encodeWav(samples));
      expect(clip.sampleRate, 16000);
      expect(clip.samples.length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        expect(clip.samples[i], closeTo(samples[i], 1e-3));
      }
    });

    test('pcm16 bytes to float', () {
      final bytes = Uint8List.fromList([0x00, 0x40, 0x00, 0xC0]); // 16384, -16384
      final f = pcm16ToFloat(bytes);
      expect(f[0], closeTo(0.5, 1e-6));
      expect(f[1], closeTo(-0.5, 1e-6));
    });
  });

  test('model catalog parses and is consistent', () {
    final catalog = ModelCatalog.parse(File('assets/models.json').readAsStringSync());
    expect(catalog.models.map((m) => m.id).toSet().length, catalog.models.length);
    for (final m in catalog.models) {
      final roles = m.files.map((f) => f.role).toSet();
      expect(roles.containsAll(m.family == 'whisper' ? {'encoder', 'decoder', 'tokens'} : {'encoder', 'decoder', 'joiner', 'tokens'}), isTrue,
          reason: m.id);
      if (!m.selfHosted) {
        expect(m.files.every((f) => f.url != null && f.url!.startsWith('https://')), isTrue, reason: m.id);
      }
      expect(m.license, isNotEmpty);
      expect(m.attribution, isNotEmpty);
    }
  });
}
