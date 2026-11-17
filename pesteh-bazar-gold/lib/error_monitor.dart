import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'warehouse_ui.dart' show StockApi;

/// S31.T31.18 — app error monitoring. Uncaught errors (FlutterError, zone, platform dispatcher) are de-duplicated,
/// kept in a small persisted queue and sent in batches to the server action `error.report` (any logged-in user).
/// Never throws, never blocks the UI; when offline / not logged in the queue simply waits for the next flush.
/// No user data is attached: only message, first stack lines and the (optional) screen name.
class ErrorMonitor {
  ErrorMonitor._();
  static final ErrorMonitor I = ErrorMonitor._();

  /// Keep in sync with pubspec.yaml `version:`.
  static const String appVersion = '1.5.0+6';
  static const String _prefKey = 'pb_err_queue_v1';
  static const int _maxQueue = 30;

  final List<Map<String, dynamic>> _queue = <Map<String, dynamic>>[];
  bool _loaded = false;
  bool _flushing = false;
  Timer? _timer;

  /// Call once from main() before runApp: loads the persisted queue and starts a slow periodic flush.
  Future<void> start() async {
    await _load();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (Timer _) {
      flush();
    });
    flush();
  }

  /// Record an error (sync, safe to call from any error handler).
  void record(Object error, StackTrace? stack, {String? screen}) {
    try {
      final String msg = _clip('$error', 400);
      final String st = stack == null ? '' : stack.toString().split('\n').take(8).join('\n');
      final String loc = st.isEmpty ? '' : _clip(st.split('\n').first, 200);
      for (final Map<String, dynamic> e in _queue) {
        if (e['message'] == msg && e['location'] == loc) {
          e['count'] = ((e['count'] as int?) ?? 1) + 1;
          _save();
          return;
        }
      }
      if (_queue.length >= _maxQueue) _queue.removeAt(0);
      _queue.add(<String, dynamic>{
        'message': msg,
        'location': loc,
        'stack': _clip(st, 1500),
        if (screen != null) 'screen': _clip(screen, 60),
        'count': 1,
      });
      _save();
      _schedule();
    } catch (_) {}
  }

  void _schedule() {
    Timer(const Duration(seconds: 20), () {
      flush();
    });
  }

  /// Send queued events; on success they are removed. Offline / not logged in -> kept for later.
  Future<void> flush() async {
    if (_flushing) return;
    await _load();
    if (_queue.isEmpty) return;
    _flushing = true;
    try {
      final List<Map<String, dynamic>> batch = _queue.take(20).map((Map<String, dynamic> e) => Map<String, dynamic>.from(e)).toList();
      await StockApi.call('error.report', <String, dynamic>{
        'events': batch,
        'app_version': appVersion,
        'platform': _platform(),
      });
      _queue.removeRange(0, batch.length);
      await _save();
    } catch (_) {
      // keep the queue
    } finally {
      _flushing = false;
    }
  }

  String _platform() {
    try {
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  String _clip(String s, int max) => s.length > max ? s.substring(0, max) : s;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final String? raw = sp.getString(_prefKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic j = jsonDecode(raw);
        if (j is List) {
          for (final dynamic e in j) {
            if (e is Map) _queue.add(Map<String, dynamic>.from(e));
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setString(_prefKey, jsonEncode(_queue));
    } catch (_) {}
  }
}
