import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/stt_engine.dart';
import '../data/settings.dart';

class OnlineEngineInfo {
  OnlineEngineInfo({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.model,
    required this.configured,
    this.baseUrl,
    this.notes,
    this.unverified,
  });

  factory OnlineEngineInfo.fromJson(Map<String, dynamic> j) => OnlineEngineInfo(
        id: j['id'] as String,
        provider: j['provider'] as String? ?? '',
        displayName: j['displayName'] as String? ?? j['id'] as String,
        model: j['model'] as String? ?? '',
        configured: j['configured'] as bool? ?? false,
        baseUrl: j['baseUrl'] as String?,
        notes: j['notes'] as String?,
        unverified: j['unverified'] as String?,
      );

  final String id;
  final String provider;
  final String displayName;
  final String model;

  /// Whether the proxy has an API key for this engine.
  final bool configured;
  final String? baseUrl;
  final String? notes;
  final String? unverified;

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        'displayName': displayName,
        'model': model,
        'configured': configured,
        'baseUrl': baseUrl,
        'notes': notes,
        'unverified': unverified,
      };
}

/// Talks to the backend proxy. The app never holds a provider API key.
class ProxyClient {
  ProxyClient(this._settings);

  final Settings _settings;

  Map<String, String> get _auth =>
      _settings.proxyToken.isEmpty ? {} : {'x-proxy-token': _settings.proxyToken};

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('${_settings.proxyUrl}$path').replace(queryParameters: query);

  /// Returns the round-trip time in ms if the proxy answered in time, else null.
  Future<int?> probe(Duration timeout) async {
    final sw = Stopwatch()..start();
    try {
      final r = await http.get(_uri('/health')).timeout(timeout);
      return r.statusCode == 200 ? sw.elapsedMilliseconds : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<OnlineEngineInfo>> engines() async {
    final r = await _guard(() => http.get(_uri('/v1/engines'), headers: _auth).timeout(const Duration(seconds: 10)));
    final j = _decode(r);
    return [for (final e in j['engines'] as List) OnlineEngineInfo.fromJson(e as Map<String, dynamic>)];
  }

  /// Sends WAV bytes, returns the proxy's JSON answer.
  Future<Map<String, dynamic>> transcribe(String engineId, Uint8List wav) async {
    final r = await _guard(() => http
        .post(
          _uri('/v1/transcribe', {'engine': engineId, 'language': kLanguage}),
          headers: {..._auth, 'Content-Type': 'audio/wav'},
          body: wav,
        )
        .timeout(const Duration(seconds: 240)));
    return _decode(r);
  }

  Future<Map<String, dynamic>> summarize(String text) async {
    final r = await _guard(() => http
        .post(
          _uri('/v1/summarize'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'text': text}),
        )
        .timeout(const Duration(seconds: 120)));
    return _decode(r);
  }

  Future<http.Response> _guard(Future<http.Response> Function() send) async {
    try {
      return await send();
    } on TimeoutException {
      throw SttException('Proxy did not answer in time', retryable: true);
    } on SocketException catch (e) {
      throw SttException('Cannot reach the proxy at ${_settings.proxyUrl}: ${e.message}', retryable: true);
    } on http.ClientException catch (e) {
      throw SttException('Cannot reach the proxy at ${_settings.proxyUrl}: ${e.message}', retryable: true);
    }
  }

  Map<String, dynamic> _decode(http.Response r) {
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      j = null;
    }
    if (r.statusCode == 200 && j != null) return j;
    final message = j?['error'] as String? ?? 'HTTP ${r.statusCode}';
    final detail = j?['detail'] as String?;
    throw SttException(
      detail == null ? 'Proxy: $message' : 'Proxy: $message ($detail)',
      retryable: j?['retryable'] as bool? ?? r.statusCode >= 500,
    );
  }
}
