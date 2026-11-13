import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
import '../engines/engine_registry.dart';
import '../engines/proxy_client.dart';
import 'attributions_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _modelHost;
  String? _connection;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<Settings>();
    _url = TextEditingController(text: s.proxyUrl);
    _token = TextEditingController(text: s.proxyToken);
    _modelHost = TextEditingController(text: s.modelHostUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _modelHost.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    final settings = context.read<Settings>();
    final proxy = context.read<ProxyClient>();
    final registry = context.read<EngineRegistry>();
    settings
      ..proxyUrl = _url.text
      ..proxyToken = _token.text
      ..modelHostUrl = _modelHost.text;
    setState(() {
      _testing = true;
      _connection = null;
    });
    final ms = await proxy.probe(Duration(milliseconds: settings.networkTimeoutMs));
    String result;
    if (ms == null) {
      result = 'No answer from ${settings.proxyUrl} within ${settings.networkTimeoutMs} ms.';
    } else {
      await registry.refreshOnline();
      result = registry.onlineError != null
          ? 'Proxy answered in $ms ms, but the engine list failed: ${registry.onlineError}'
          : 'Proxy answered in $ms ms. ${registry.online.where((e) => e.info.configured).length} of '
              '${registry.online.length} online engines have a key.';
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _connection = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final registry = context.watch<EngineRegistry>();
    final theme = Theme.of(context);

    Widget slider(String label, String valueText, double value, double min, double max, int divisions, ValueChanged<double> onChanged) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(label)), Text(valueText, style: theme.textTheme.bodySmall)]),
        Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, divisions: divisions, onChanged: onChanged),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AttributionsScreen())),
            child: const Text('Licenses'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Backend proxy', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Proxy URL',
              helperText: 'Android emulator: http://10.0.2.2:8787 · phone: http://<computer LAN IP>:8787',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => s.proxyUrl = v,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Proxy token (PROXY_TOKEN, if set)',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => s.proxyToken = v,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelHost,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Model host URL (empty = proxy)',
              helperText: 'Where converted models are downloaded from',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => s.modelHostUrl = v,
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.tonal(onPressed: _testing ? null : _test, child: Text(_testing ? 'Testing…' : 'Save & test connection')),
          ]),
          if (_connection != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_connection!)),
          if (registry.online.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('Online engines on the proxy (${registry.online.length})'),
              children: [
                for (final e in registry.online)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(e.info.configured ? Icons.check_circle : Icons.key_off, color: e.info.configured ? Colors.green : theme.disabledColor),
                    title: Text('${e.displayName} · ${e.info.model}'),
                    subtitle: Text([
                      if (e.info.baseUrl != null) 'Endpoint: ${e.info.baseUrl}',
                      if (e.info.notes != null) e.info.notes!,
                      if (e.info.unverified != null) 'Unverified: ${e.info.unverified}',
                    ].join('\n')),
                  ),
              ],
            ),
          const Divider(height: 32),
          Text('Network', style: theme.textTheme.titleMedium),
          slider('Auto mode timeout', '${s.networkTimeoutMs} ms', s.networkTimeoutMs.toDouble(), 500, 10000, 19,
              (v) => s.networkTimeoutMs = v.round()),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Simulate offline'),
            subtitle: const Text('Forces the on-device path in every mode'),
            value: s.simulateOffline,
            onChanged: (v) => s.simulateOffline = v,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Upload only detected speech'),
            subtitle: const Text('Off: send the whole recording to the online model'),
            value: s.uploadTrimmedAudio,
            onChanged: (v) => s.uploadTrimmedAudio = v,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Keep audio after upgrade'),
            subtitle: const Text('Off (production behaviour): the recording is deleted once the online transcript succeeds'),
            value: s.keepAudioAfterUpgrade,
            onChanged: (v) => s.keepAudioAfterUpgrade = v,
          ),
          const Divider(height: 32),
          Text('Voice activity detection (Silero)', style: theme.textTheme.titleMedium),
          slider('Speech threshold', s.vadThreshold.toStringAsFixed(2), s.vadThreshold, 0.1, 0.9, 16, (v) => s.vadThreshold = v),
          slider('End-of-speech silence', '${s.vadMinSilence.toStringAsFixed(2)} s', s.vadMinSilence, 0.1, 2.0, 19,
              (v) => s.vadMinSilence = v),
          slider('Padding before/after speech', '${s.vadPadding.toStringAsFixed(2)} s', s.vadPadding, 0.0, 1.0, 20,
              (v) => s.vadPadding = v),
          slider('Minimum speech length', '${s.vadMinSpeech.toStringAsFixed(2)} s', s.vadMinSpeech, 0.05, 1.0, 19,
              (v) => s.vadMinSpeech = v),
          slider('Longest chunk', '${s.vadMaxSpeech.toStringAsFixed(0)} s', s.vadMaxSpeech, 5, 27, 22, (v) => s.vadMaxSpeech = v),
          Text(
            'Chunks are capped below 30 s because Whisper in sherpa-onnx discards audio past 30 s per call. '
            'Changes apply to the next recording.',
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: 32),
          Text('On-device inference', style: theme.textTheme.titleMedium),
          slider('CPU threads', '${s.numThreads}', s.numThreads.toDouble(), 1, 8, 7, (v) => s.numThreads = v.round()),
          Text('Language is fixed to Slovak (sk) for every engine that lets us set it.', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
