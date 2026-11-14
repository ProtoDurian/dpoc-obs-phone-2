// Small platform channel the spike app uses (MainActivity.kt / AppDelegate.swift).
import 'package:flutter/services.dart';

const _ch = MethodChannel('spike/native');

/// Launch arguments: Android intent extras, iOS SPIKE_* env vars (simctl SIMCTL_CHILD_SPIKE_*).
Future<Map<String, String>> launchArgs() async {
  try {
    final m = await _ch.invokeMapMethod<String, dynamic>('args');
    return (m ?? {}).map((k, v) => MapEntry(k, '$v'));
  } catch (_) {
    return {};
  }
}

/// Wall-clock epoch ms of process start (and Android: when the launch was requested).
Future<Map<String, num>> processStart() async {
  try {
    final m = await _ch.invokeMapMethod<String, dynamic>('processStart');
    return (m ?? {}).map((k, v) => MapEntry(k, v as num));
  } catch (_) {
    return {};
  }
}

/// Native main-thread stalls seen by our watchdog since last call: [{duration_ms, stack}].
Future<List<Map<String, dynamic>>> takeHangs() async {
  try {
    final l = await _ch.invokeListMethod<dynamic>('takeHangs');
    return (l ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } catch (_) {
    return [];
  }
}

Future<void> crashNative() => _ch.invokeMethod('crashNative');
Future<void> hangNative(int ms) => _ch.invokeMethod('hangNative', {'ms': ms});
