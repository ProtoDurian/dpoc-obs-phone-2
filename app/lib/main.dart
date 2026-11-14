// Group M spike app (phones): 2 screens, 3 API calls (one slow), one slow render,
// plus error / crash / hang scenarios. Reports through Faro (obs.dart) to Alloy.
// Scenario comes from the launch (Android intent extra / iOS SIMCTL_CHILD_SPIKE_SCENARIO).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:faro/faro.dart' show Faro, OfflineTransport;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import 'native.dart' as native;
import 'obs.dart' as obs;

const apiBaseDefine = String.fromEnvironment('API', defaultValue: 'http://10.0.2.2:31380');
const collectorDefine = String.fromEnvironment('COLLECTOR', defaultValue: 'http://10.0.2.2:31347/collect');
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
const buildMode = bool.fromEnvironment('dart.vm.product') ? 'release' : (bool.fromEnvironment('dart.vm.profile') ? 'profile' : 'debug');

late Map<String, String> args;
String get scenario => args['scenario'] ?? 'normal';
String get apiBase => args['api'] ?? apiBaseDefine;
bool faroOk = false;
final Stopwatch sinceMain = Stopwatch();
final int mainEpochUs = DateTime.now().microsecondsSinceEpoch;

void mark(String s) => stdout.writeln('MMARK $s'); // logcat (I/flutter) / simulator console

// ---------- instrumented "poor man's profiler": exact time per call path ----------
class Prof {
  static final List<String> _stack = [];
  static final Map<String, int> us = {}; // folded path -> self microseconds
  static T run<T>(String name, T Function() fn) {
    _stack.add(name);
    final sw = Stopwatch()..start();
    try {
      return fn();
    } finally {
      final path = _stack.join(';');
      _stack.removeLast();
      us[path] = (us[path] ?? 0) + sw.elapsedMicroseconds;
      if (_stack.isNotEmpty) {
        final parent = _stack.join(';');
        us[parent] = (us[parent] ?? 0) - sw.elapsedMicroseconds; // self time only
      }
    }
  }

  static String takeFolded() {
    final s = us.entries.where((e) => e.value > 0).map((e) => '${e.key} ${e.value}').join('\n');
    us.clear();
    return s;
  }
}

// ---------- frames / jank ----------
class FrameStats {
  int frames = 0, slow = 0, frozen = 0;
  int maxBuildUs = 0, maxRasterUs = 0, maxTotalUs = 0;
  String screen = 'start';
  void add(List<FrameTiming> ts) {
    for (final t in ts) {
      frames++;
      final total = t.totalSpan.inMicroseconds;
      if (total > 16667) {
        slow++;
        // one event per slow frame: where the time went (build = Dart UI thread, raster = GPU thread)
        if (faroOk) {
          obs.event('slow_frame', {
            'screen': screen,
            'total_ms': (total / 1000).toStringAsFixed(1),
            'build_ms': (t.buildDuration.inMicroseconds / 1000).toStringAsFixed(1),
            'raster_ms': (t.rasterDuration.inMicroseconds / 1000).toStringAsFixed(1),
            'vsync_overhead_ms': (t.vsyncOverhead.inMicroseconds / 1000).toStringAsFixed(1),
            'frozen': total > 700000 ? '1' : '0',
          });
        }
      }
      if (total > 700000) frozen++;
      if (t.buildDuration.inMicroseconds > maxBuildUs) maxBuildUs = t.buildDuration.inMicroseconds;
      if (t.rasterDuration.inMicroseconds > maxRasterUs) maxRasterUs = t.rasterDuration.inMicroseconds;
      if (total > maxTotalUs) maxTotalUs = total;
    }
  }

  Map<String, num> snapshot() => {
        'frames_total': frames,
        'frames_slow': slow,
        'frames_frozen': frozen,
        'frame_build_max_ms': maxBuildUs / 1000,
        'frame_raster_max_ms': maxRasterUs / 1000,
        'frame_total_max_ms': maxTotalUs / 1000,
      };
}

final frameStats = FrameStats();

// ---------- the screen timer the library would offer ----------
class ScreenTimer {
  ScreenTimer(this.screen) {
    frameStats.screen = screen;
    _sw.start();
    span = faroOk ? obs.startSpan('screen.load', attributes: {'screen': screen}) : null;
  }
  final String screen;
  final _sw = Stopwatch();
  obs.ObsSpan? span;
  double networkMs = 0;
  int _slowAtRender = 0, _framesAtRender = 0;

  Future<T> network<T>(Future<T> Function(obs.ObsSpan? parent) load) async {
    final t0 = _sw.elapsedMicroseconds;
    final r = faroOk
        ? await obs.runInSpan<T>('screen.network', (s) => load(s), parent: span, attributes: {'screen': screen})
        : await load(null);
    networkMs = (_sw.elapsedMicroseconds - t0) / 1000;
    return r;
  }

  Future<double> render(VoidCallback applyData) async {
    final t0 = _sw.elapsedMicroseconds;
    _slowAtRender = frameStats.slow;
    _framesAtRender = frameStats.frames;
    final renderSpan = faroOk ? obs.startSpan('screen.render', parent: span, attributes: {'screen': screen}) : null;
    applyData();
    await SchedulerBinding.instance.endOfFrame;
    final uiMs = (_sw.elapsedMicroseconds - t0) / 1000;
    final totalMs = _sw.elapsedMicroseconds / 1000;
    renderSpan?.end();
    final folded = Prof.takeFolded();
    span?.setAttributes({'screen.network_ms': networkMs, 'screen.render_ms': uiMs, 'screen.total_ms': totalMs});
    final traceId = span?.traceId;
    span?.end();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (frameStats.frames <= _framesAtRender && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final values = <String, num>{
      'network_ms': networkMs,
      'render_ms': uiMs,
      'total_ms': totalMs,
      'frames_slow_during': frameStats.slow - _slowAtRender,
    };
    if (faroOk) {
      obs.measurement('screen_load', values);
      obs.event('screen_ready', {'screen': screen, 'total_ms': totalMs.toStringAsFixed(1), 'network_ms': networkMs.toStringAsFixed(1), 'render_ms': uiMs.toStringAsFixed(1)});
      if (folded.isNotEmpty) obs.event('prof_folded', {'screen': screen, 'folded': folded});
    }
    mark('screen=$screen ${jsonEncode(values)} trace=$traceId');
    return totalMs;
  }
}

// ---------- API client ----------
final client = http.Client();

Future<dynamic> getJson(String path, obs.ObsSpan? parent, {bool isolate = false}) async {
  final res = await client.get(Uri.parse('$apiBase$path'));
  if (!isolate) return jsonDecode(res.body);
  // isolate work, timed as its own span
  final body = res.body;
  if (!faroOk) return Isolate.run(() => jsonDecode(body));
  return obs.runInSpan('isolate.json_decode', (_) => Isolate.run(() => jsonDecode(body)), parent: parent, attributes: {'bytes': body.length});
}

// ---------- result type with creation stack (stand-in for our result library) ----------
class Failure {
  Failure(this.code, this.chain, this.step, this.stepName) : created = StackTrace.current;
  final String code, chain, stepName;
  final int step;
  final StackTrace created;
}

sealed class Result<T> {}

class Ok<T> extends Result<T> {
  Ok(this.value);
  final T value;
}

class Err<T> extends Result<T> {
  Err(this.failure);
  final Failure failure;
}

Result<int> chargeCard(int cents) => cents > 1000 ? Err(Failure('card_declined', 'checkout.place', 3, 'chargeCard')) : Ok(cents);

Result<int> placeOrder(int cents) {
  final r = chargeCard(cents);
  return r;
}

// ---------- start-up ----------
Map<String, num> startVals = {};

Future<void> main() async {
  sinceMain.start();
  WidgetsFlutterBinding.ensureInitialized();
  SchedulerBinding.instance.addTimingsCallback(frameStats.add);
  args = await native.launchArgs();
  final ps = await native.processStart();
  final collector = args['collector'] ?? collectorDefine;
  final rate = double.tryParse(args['rate'] ?? '1.0') ?? 1.0;
  mark('launch scenario=$scenario mode=$buildMode args=${jsonEncode(args)} process=${jsonEncode(ps)}');

  if (args['offline_transport'] != '0') {
    Faro().transports.add(OfflineTransport(maxCacheDuration: const Duration(days: 3)));
  }
  final cfg = obs.config(
    collector: collector,
    version: args['version'] ?? appVersion,
    user: args['user'] ?? 'u-1',
    rate: rate,
    attrs: {
      'client_kind': 'flutter_${Platform.operatingSystem}',
      'build_mode': buildMode,
      'scenario': scenario,
      'run_id': args['run'] ?? '-',
    },
  );
  final initSw = Stopwatch()..start();
  await obs.runWithFaro(cfg, () async {
    faroOk = true;
    final initMs = initSw.elapsedMicroseconds / 1000;
    mark('faro_init=ok sampled=${obs.sampled()} init_ms=$initMs');
    runApp(const ShopApp());
    await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final procStartMs = ps['process_start_epoch_ms'];
    startVals = {
      'obs_init_ms': initMs,
      'main_to_first_frame_ms': sinceMain.elapsedMicroseconds / 1000,
      if (procStartMs != null) 'process_to_main_ms': mainEpochUs / 1000 - procStartMs,
      if (procStartMs != null) 'process_to_first_frame_ms': nowUs / 1000 - procStartMs,
      if (ps['launch_requested_epoch_ms'] != null) 'launch_to_first_frame_ms': nowUs / 1000 - ps['launch_requested_epoch_ms']!,
    };
    mark('first_frame ${jsonEncode(startVals)}');
  });
}

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Spike Shop',
        navigatorObservers: [if (faroOk) ...obs.navObservers()],
        routes: {
          '/': (_) => const HomeScreen(),
          '/catalog': (_) => const CatalogScreen(),
        },
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> {
  Map<String, dynamic>? user;
  List<dynamic>? orders;
  bool boom = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = ScreenTimer('home');
    final r = await t.network((p) => Future.wait([getJson('/api/user', p), getJson('/api/orders', p)]));
    final totalMs = await t.render(() => setState(() {
          user = r[0] as Map<String, dynamic>;
          orders = r[1] as List<dynamic>;
        }));
    // time to first usable screen = process start -> home screen showing its data
    final usable = <String, num>{
      ...startVals,
      'home_ready_ms': totalMs,
      if (startVals['process_to_main_ms'] != null) 'process_to_usable_ms': (DateTime.now().microsecondsSinceEpoch - mainEpochUs) / 1000 + startVals['process_to_main_ms']!,
    };
    if (faroOk) obs.measurement('app_start_spike', usable);
    mark('app_start ${jsonEncode(usable)}');
    await _scenario();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (mounted) Navigator.of(context).pushNamed('/catalog');
  }

  Future<void> _scenario() async {
    switch (scenario) {
      case 'dart_uncaught':
        // 1) uncaught async error -> PlatformDispatcher.onError
        Future<void>(() => throw StateError('spike uncaught async: orders total is negative'));
        // 2) error thrown inside build -> FlutterError.onError
        setState(() => boom = true);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        setState(() => boom = false);
        mark('scenario dart_uncaught fired');
      case 'result_error':
        final r = placeOrder(4999);
        if (r is Err<int>) {
          final f = r.failure;
          if (faroOk) {
            obs.error('ResultError', f.code, f.created, {
              'error.chain': f.chain,
              'error.step': '${f.step}',
              'error.step_name': f.stepName,
              'error.stack_raw': f.created.toString(),
            });
          }
          mark('scenario result_error code=${f.code} stack=${f.created.toString().split('\n').take(4).join(' | ')}');
        }
      case 'native_crash':
        mark('scenario native_crash: crashing in 2 s');
        await Future<void>.delayed(const Duration(seconds: 2)); // let Faro flush first
        await native.crashNative();
      case 'hang_dart':
        mark('scenario hang_dart: blocking the UI isolate 7 s');
        final sw = Stopwatch()..start();
        var x = 0;
        while (sw.elapsedMilliseconds < 7000) {
          x = (x * 31 + 7) & 0xffffff;
        }
        mark('scenario hang_dart done x=$x');
        await _reportHangs();
      case 'hang_native':
        mark('scenario hang_native: blocking the platform main thread 7 s');
        await native.hangNative(7000);
        await _reportHangs();
    }
  }

  Future<void> _reportHangs() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final hangs = await native.takeHangs();
    for (final h in hangs) {
      if (faroOk) {
        obs.error('AppHang', 'main thread blocked ${h['duration_ms']} ms', null, {
          'hang.duration_ms': '${h['duration_ms']}',
          'hang.main_stack': '${h['stack'] ?? ''}',
          'hang.detector': 'spike_watchdog',
        });
      }
      mark('hang reported ${jsonEncode(h).substring(0, 200.clamp(0, jsonEncode(h).length))}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (boom) throw FlutterError('spike build error: price widget got null');
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: user == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(children: [
              ListTile(title: Text('Hello ${user!['name']}')),
              for (final o in orders!) ListTile(title: Text('Order ${o['id']}: ${o['total']}')),
            ]),
    );
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});
  @override
  State<CatalogScreen> createState() => _CatalogState();
}

class _CatalogState extends State<CatalogScreen> {
  List<dynamic>? items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = ScreenTimer('catalog');
    final r = await t.network((p) => getJson('/api/catalog', p, isolate: true));
    await t.render(() => setState(() => items = r as List<dynamic>));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final snap = frameStats.snapshot();
    if (faroOk) obs.measurement('frames', snap);
    mark('frames ${jsonEncode(snap)}');
    mark('done');
  }

  String _label(Map<String, dynamic> it) => Prof.run('CatalogState._label', () {
        var h = 0;
        for (var i = 0; i < 4000; i++) {
          h = (h * 31 + (it['id'] as int) + i) & 0x7fffffff;
        }
        return Prof.run('CatalogState._format', () => '${it['name']} #${h % 997}');
      });

  @override
  Widget build(BuildContext context) => Prof.run('CatalogState.build', () => Scaffold(
        appBar: AppBar(title: const Text('Catalog')),
        body: items == null
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Wrap(children: [
                  for (final it in items!)
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: Chip(label: Text(_label(it as Map<String, dynamic>))),
                    ),
                ]),
              ),
      ));
}
