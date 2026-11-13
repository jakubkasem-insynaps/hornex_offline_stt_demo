import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'benchmark/benchmark_controller.dart';
import 'benchmark/test_set.dart';
import 'data/history_store.dart';
import 'data/paths.dart';
import 'data/settings.dart';
import 'engines/engine_registry.dart';
import 'engines/model_catalog.dart';
import 'engines/model_manager.dart';
import 'engines/offline_worker.dart';
import 'engines/proxy_client.dart';
import 'pipeline/record_controller.dart';
import 'pipeline/upgrade_service.dart';
import 'ui/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = await Settings.load();
  final paths = await AppPaths.init();
  final catalog = await ModelCatalog.load();
  final models = ModelManager(catalog, paths, settings);
  await models.refresh();
  final proxy = ProxyClient(settings);
  final registry = EngineRegistry(settings, models, proxy, OfflineWorker());
  final history = HistoryStore(paths);
  await history.load();
  final upgrades = UpgradeService(history, registry, settings, proxy)..start();
  final recorder = RecordController(settings, registry, models, history, proxy, upgrades, paths);
  final benchmark = BenchmarkController(settings, registry, models, TestSetStore(paths));

  // Model IDs of cloud engines live on the proxy; fetch the list if reachable.
  unawaited(registry.refreshOnline());

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: models),
      ChangeNotifierProvider.value(value: registry),
      ChangeNotifierProvider.value(value: history),
      ChangeNotifierProvider.value(value: upgrades),
      ChangeNotifierProvider.value(value: recorder),
      ChangeNotifierProvider.value(value: benchmark),
      Provider.value(value: paths),
      Provider.value(value: proxy),
    ],
    child: const SttDemoApp(),
  ));
}

class SttDemoApp extends StatelessWidget {
  const SttDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slovak STT demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2F5D8A), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2F5D8A), brightness: Brightness.dark, useMaterial3: true),
      home: const HomeShell(),
    );
  }
}
