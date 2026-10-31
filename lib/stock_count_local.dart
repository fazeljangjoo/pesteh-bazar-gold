import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S19.T19.1b — offline mirror of the stock count (انبارگردانی).
/// * `stock_count_local`: one row per count draft created/edited on this device (`uid` = client UUID, the server's idempotency key).
///   status: `pending` (must be pushed) | `synced` | `error` (server refused, see `error`). Approved counts are never stored here.
/// * `stock_count_sheet`: last downloaded count sheet per warehouse ('' = all) so lots can be counted without a connection.
/// Push = `stock_count.save` with the same uid (idempotent), so retries and double pushes are safe.
class StockCountLocal {
  StockCountLocal._();

  static Future<void> createTables(Database d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS stock_count_local(
        uid TEXT PRIMARY KEY,
        server_id INTEGER,
        payload TEXT NOT NULL,
        status TEXT NOT NULL,
        error TEXT,
        updated_at TEXT NOT NULL
      )''');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS stock_count_sheet(
        wh TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        fetched_at TEXT NOT NULL
      )''');
  }

  static Future<Database> _d() async {
    final Database d = await AppDb.I.db;
    await createTables(d); // IF NOT EXISTS: also covers databases opened before this table existed
    return d;
  }

  /// Insert/replace the local draft and mark it pending.
  static Future<void> saveDraft(String uid, Map<String, dynamic> payload, {int? serverId}) async {
    final Database d = await _d();
    final List<Map<String, Object?>> ex = await d.query('stock_count_local', columns: <String>['server_id'], where: 'uid=?', whereArgs: <Object?>[uid], limit: 1);
    final int? sid = serverId ?? (ex.isEmpty ? null : ex.first['server_id'] as int?);
    await d.insert(
      'stock_count_local',
      <String, Object?>{'uid': uid, 'server_id': sid, 'payload': jsonEncode(payload), 'status': 'pending', 'error': null, 'updated_at': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Map<String, dynamic> _row(Map<String, Object?> r) {
    Map<String, dynamic> p = <String, dynamic>{};
    try {
      final dynamic j = jsonDecode('${r['payload']}');
      if (j is Map) p = Map<String, dynamic>.from(j);
    } catch (_) {}
    return <String, dynamic>{'uid': r['uid'], 'server_id': r['server_id'], 'status': r['status'], 'error': r['error'], 'payload': p};
  }

  static Future<Map<String, dynamic>?> byUid(String uid) async {
    final Database d = await _d();
    final List<Map<String, Object?>> r = await d.query('stock_count_local', where: 'uid=?', whereArgs: <Object?>[uid], limit: 1);
    return r.isEmpty ? null : _row(r.first);
  }

  static Future<Map<String, dynamic>?> byServerId(int id) async {
    final Database d = await _d();
    final List<Map<String, Object?>> r = await d.query('stock_count_local', where: 'server_id=?', whereArgs: <Object?>[id], limit: 1);
    return r.isEmpty ? null : _row(r.first);
  }

  /// Drafts that still need the server (pending or refused), newest first.
  static Future<List<Map<String, dynamic>>> unsynced() async {
    final Database d = await _d();
    final List<Map<String, Object?>> r = await d.query('stock_count_local', where: "status<>'synced'", orderBy: 'updated_at DESC');
    return <Map<String, dynamic>>[for (final Map<String, Object?> x in r) _row(x)];
  }

  static Future<void> remove(String uid) async {
    final Database d = await _d();
    await d.delete('stock_count_local', where: 'uid=?', whereArgs: <Object?>[uid]);
  }

  static Future<void> cacheSheet(String? wh, List<Map<String, dynamic>> items) async {
    final Database d = await _d();
    await d.insert('stock_count_sheet', <String, Object?>{'wh': wh ?? '', 'payload': jsonEncode(items), 'fetched_at': DateTime.now().toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>?> cachedSheet(String? wh) async {
    final Database d = await _d();
    final List<Map<String, Object?>> r = await d.query('stock_count_sheet', where: 'wh=?', whereArgs: <Object?>[wh ?? ''], limit: 1);
    if (r.isEmpty) return null;
    try {
      final dynamic j = jsonDecode('${r.first['payload']}');
      if (j is List) return <Map<String, dynamic>>[for (final dynamic e in j) Map<String, dynamic>.from(e as Map)];
    } catch (_) {}
    return null;
  }

  /// Push one draft. Returns the server count (id/uid/...) on success; null when offline (stays pending). A server refusal is stored as `error` and rethrown.
  static Future<Map<String, dynamic>?> push(String uid) async {
    final Map<String, dynamic>? row = await byUid(uid);
    if (row == null) return null;
    final Map<String, dynamic> body = Map<String, dynamic>.from(row['payload'] as Map<String, dynamic>);
    body['uid'] = uid;
    if (row['server_id'] != null) body['id'] = row['server_id'];
    final Database d = await _d();
    try {
      final Map<String, dynamic> r = await StockApi.call('stock_count.save', body);
      await d.update('stock_count_local', <String, Object?>{'server_id': (r['id'] as num).toInt(), 'status': 'synced', 'error': null, 'updated_at': DateTime.now().toIso8601String()},
          where: 'uid=?', whereArgs: <Object?>[uid]);
      return r;
    } on StockApiException catch (e) {
      if (e.network) return null;
      await d.update('stock_count_local', <String, Object?>{'status': 'error', 'error': e.message}, where: 'uid=?', whereArgs: <Object?>[uid]);
      rethrow;
    }
  }

  /// Push every pending draft (stops at the first connection failure). Returns how many were sent.
  static Future<int> pushAll() async {
    int n = 0;
    for (final Map<String, dynamic> r in await unsynced()) {
      if (r['status'] != 'pending') continue;
      try {
        final Map<String, dynamic>? res = await push('${r['uid']}');
        if (res == null) break; // offline
        n++;
      } on StockApiException {
        // refused by the server: kept as `error`, continue with the others
      }
    }
    return n;
  }
}
