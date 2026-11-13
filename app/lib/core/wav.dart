/// Minimal WAV reader/writer. Everything inside the app is 16 kHz mono float.
library;

import 'dart:io';
import 'dart:typed_data';

import 'stt_engine.dart';

const int kSampleRate = 16000;

/// Encodes mono float samples as a 16-bit PCM WAV file.
Uint8List encodeWav(Float32List samples, {int sampleRate = kSampleRate}) {
  final dataBytes = samples.length * 2;
  final out = ByteData(44 + dataBytes);
  void tag(int offset, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, dataBytes, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    var v = (samples[i] * 32767.0).round();
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Decodes PCM 8/16/24/32-bit or 32-bit float WAV, downmixes to mono and
/// resamples to 16 kHz (linear interpolation; test sets should already be 16 kHz).
AudioClip decodeWav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE file');
  }
  var format = 1, channels = 1, rate = kSampleRate, bits = 16;
  var dataOffset = -1, dataLength = 0;
  var pos = 12;
  while (pos + 8 <= bytes.length) {
    final id = tag(pos);
    final size = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) {
        // WAVE_FORMAT_EXTENSIBLE: real format is the first 2 bytes of the sub-format GUID.
        format = bd.getUint16(body + 24, Endian.little);
      }
    } else if (id == 'data') {
      dataOffset = body;
      dataLength = size;
      if (dataOffset + dataLength > bytes.length) {
        dataLength = bytes.length - dataOffset;
      }
      break;
    }
    pos = body + size + (size.isOdd ? 1 : 0);
  }
  if (dataOffset < 0) throw const FormatException('WAV has no data chunk');
  if (format != 1 && format != 3) {
    throw FormatException('Unsupported WAV format tag $format');
  }
  final bytesPerSample = bits ~/ 8;
  final frames = dataLength ~/ (bytesPerSample * channels);
  final mono = Float32List(frames);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final o = dataOffset + (f * channels + c) * bytesPerSample;
      double v;
      if (format == 3) {
        v = bits == 64
            ? bd.getFloat64(o, Endian.little)
            : bd.getFloat32(o, Endian.little);
      } else {
        switch (bits) {
          case 8:
            v = (bd.getUint8(o) - 128) / 128.0;
          case 16:
            v = bd.getInt16(o, Endian.little) / 32768.0;
          case 24:
            final raw = bd.getUint8(o) |
                (bd.getUint8(o + 1) << 8) |
                (bd.getInt8(o + 2) << 16);
            v = raw / 8388608.0;
          case 32:
            v = bd.getInt32(o, Endian.little) / 2147483648.0;
          default:
            throw FormatException('Unsupported bit depth $bits');
        }
      }
      sum += v;
    }
    mono[f] = sum / channels;
  }
  return AudioClip(_resample(mono, rate, kSampleRate), kSampleRate);
}

Float32List _resample(Float32List input, int from, int to) {
  if (from == to || input.isEmpty) return input;
  final outLength = (input.length * to / from).floor();
  final out = Float32List(outLength);
  final step = from / to;
  for (var i = 0; i < outLength; i++) {
    final p = i * step;
    final i0 = p.floor();
    final i1 = i0 + 1 < input.length ? i0 + 1 : i0;
    final frac = p - i0;
    out[i] = input[i0] * (1 - frac) + input[i1] * frac;
  }
  return out;
}

Future<AudioClip> readWavFile(String path) async =>
    decodeWav(await File(path).readAsBytes());

Future<void> writeWavFile(String path, Float32List samples) =>
    File(path).writeAsBytes(encodeWav(samples), flush: true);

/// Converts little-endian PCM16 bytes to float samples.
Float32List pcm16ToFloat(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
