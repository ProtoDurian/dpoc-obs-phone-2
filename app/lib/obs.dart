// Adapter: Faro Flutter SDK (faro 0.18.0) behind the small obs port (phones only).
import 'dart:async';
import 'dart:io';

import 'package:faro/faro.dart';
import 'package:flutter/widgets.dart';

class ObsSpan {
  ObsSpan(this.inner);
  final Span inner;
  String get traceId => inner.traceId;
  void setAttributes(Map<String, Object> a) => inner.setAttributes(a);
  void end() => inner.end();
}

FaroConfig config({required String collector, required String version, required String user, required double rate, required Map<String, Object> attrs}) => FaroConfig(
      appName: 'spike-shop',
      appEnv: 'spike',
      appVersion: version,
      apiKey: 'spike-key',
      collectorUrl: collector,
      sessionAttributes: attrs,
      initialUser: FaroUser(id: user),
      persistSession: false,
      persistUser: false,
      sampling: SamplingRate(rate),
      enableCrashReporting: true,
      anrTracking: true,
      refreshRateVitals: true,
      memoryUsageVitals: true,
      cpuUsageVitals: true,
      fetchVitalsInterval: const Duration(seconds: 5),
    );

/// Faro().runApp installs FlutterError.onError + PlatformDispatcher.onError, then runs [app].
Future<void> runWithFaro(FaroConfig c, FutureOr<void> Function() app) async {
  final previous = HttpOverrides.current;
  HttpOverrides.global = FaroHttpOverrides(previous);
  await Faro().runApp(optionsConfiguration: c, appRunner: () async {
    if (Faro().isSampled != true) HttpOverrides.global = previous; // S7 trap 2 fix
    await app();
  });
}

bool? sampled() => Faro().isSampled;

ObsSpan startSpan(String name, {Map<String, Object> attributes = const {}, ObsSpan? parent}) =>
    ObsSpan(Faro().startSpanManual(name, attributes: attributes, parentSpan: parent?.inner));

Future<T> runInSpan<T>(String name, Future<T> Function(ObsSpan) fn, {Map<String, Object> attributes = const {}, ObsSpan? parent}) async =>
    await Faro().startSpan<T>(name, (s) => fn(ObsSpan(s)), attributes: attributes, parentSpan: parent?.inner);

void measurement(String type, Map<String, num> values) => Faro().pushMeasurement(values, type);
void event(String name, Map<String, String> attrs) => Faro().pushEvent(name, attributes: attrs);
void error(String type, String value, StackTrace? st, Map<String, String> ctx) =>
    Faro().pushError(type: type, value: value, stacktrace: st, context: ctx);
void log(String msg, Map<String, String> ctx) => Faro().pushLog(msg, level: LogLevel.info, context: ctx);
List<NavigatorObserver> navObservers() => [FaroNavigationObserver()];
