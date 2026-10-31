// S29.T29.3 — local money unit (toman -> rial).
//
// The server tells the client its stored unit (`money_unit` in bootstrap / backup.export).
// The local mirror keeps its own unit in `meta.money_unit` ('toman' = legacy, 'rial').
// When the server is rial and the local mirror is still toman, [MoneyUnit.migrateLocal] multiplies
// the local category-A money columns by 10 in ONE transaction, and only when `sync_ops` is empty
// (queued ops carry toman amounts and must be sent before the switch). The next full pull then
// replaces the mirror with server data anyway; the x10 keeps the offline mirror consistent until then.
// Column list = plan/MONEY_COLUMNS.md section A, restricted to tables that exist locally.
// NEVER multiply: weights, counts, pct, price_usd, price_ccy, total_ccy, ccy_amount, fx_rate.
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class MoneyUnit {
  MoneyUnit._();

  static const String kMetaKey = 'money_unit';
  static const String toman = 'toman';
  static const String rial = 'rial';

  /// local table -> money columns (stored in the tenant unit)
  static const Map<String, List<String>> kLocalMoneyCols = <String, List<String>>{
    'purchases': <String>['price', 'labor_cost', 'transport_cost', 'usd_rate'], // usd_rate = stored unit per USD: moves with price
    'sales': <String>['price', 'labor_cost', 'transport_cost', 'usd_rate'],
    'sale_items': <String>['item_price'],
    'lump_tx': <String>['amount'],
    'credit_inst': <String>['amount'],
    'cheque_inst': <String>['amount'],
    'receipt_lump_tx': <String>['amount'],
    'receipt_credit_inst': <String>['amount'],
    'receipt_cheque_inst': <String>['amount'],
    'loan_entries': <String>['amount'],
    'loan_dues': <String>['amount'],
    'sale_returns': <String>['refund_amount', 'tax_amount'],
    'purchase_returns': <String>['refund_amount', 'tax_amount'],
    'sale_return_items': <String>['unit_price'],
    'purchase_return_items': <String>['unit_price'],
    'proformas': <String>['tax_amount'],
    'proforma_items': <String>['unit_price', 'discount'],
  };

  /// generic entity JSON (`entity_rows.data`): entity -> money fields
  static const Map<String, List<String>> kEntityMoneyFields = <String, List<String>>{
    'bank_accounts': <String>['opening_balance'],
    'expenses': <String>['amount'],
    'owner_draws': <String>['amount'],
    'dev_notes': <String>['amount'],
  };

  /// 'rial' only when the server said so; anything else (missing/unknown) = legacy toman
  static String normalize(Object? v) => v == 'rial' ? rial : toman;

  static Future<bool> _queueEmpty(DatabaseExecutor t) async {
    final int n = Sqflite.firstIntValue(await t.rawQuery('SELECT COUNT(*) FROM sync_ops')) ?? 0;
    return n == 0;
  }

  static Future<Set<String>> _cols(DatabaseExecutor t, String table) async {
    final List<Map<String, Object?>> r = await t.rawQuery('PRAGMA table_info($table)');
    return r.map((Map<String, Object?> e) => e['name'] as String).toSet();
  }

  static Future<String?> _meta(DatabaseExecutor t) async {
    final List<Map<String, Object?>> r =
        await t.query('meta', columns: <String>['v'], where: 'k=?', whereArgs: <Object?>[kMetaKey], limit: 1);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  /// Unit of the local mirror; legacy databases (no meta row) are toman.
  static Future<String> localUnit(DatabaseExecutor t) async => normalize(await _meta(t));

  /// Multiplies local money columns x10 and flips the meta to 'rial'. Returns false (nothing changed)
  /// when already rial or when the offline queue is not empty. Exact: INTEGER x10 / REAL x10 on values
  /// that are whole or 2-decimals in toman. Runs in its own transaction on [d].
  static Future<bool> migrateLocal(Database d) async {
    bool done = false;
    await d.transaction((Transaction t) async {
      if (await localUnit(t) == rial) return;
      if (!await _queueEmpty(t)) return;
      for (final MapEntry<String, List<String>> e in kLocalMoneyCols.entries) {
        final Set<String> have = await _cols(t, e.key);
        if (have.isEmpty) continue; // table absent in this local schema
        for (final String c in e.value) {
          if (!have.contains(c)) continue;
          await t.execute('UPDATE ${e.key} SET $c = ROUND($c * 10, 2) WHERE $c IS NOT NULL');
        }
      }
      await _migrateEntities(t);
      await t.insert('meta', <String, Object?>{'k': kMetaKey, 'v': rial}, conflictAlgorithm: ConflictAlgorithm.replace);
      done = true;
    });
    return done;
  }

  static Future<void> _migrateEntities(DatabaseExecutor t) async {
    final List<Map<String, Object?>> tb =
        await t.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='entity_rows'");
    if (tb.isEmpty) return;
    for (final MapEntry<String, List<String>> e in kEntityMoneyFields.entries) {
      final List<Map<String, Object?>> rows = await t.query('entity_rows',
          columns: <String>['uid', 'data'], where: 'entity=?', whereArgs: <Object?>[e.key]);
      for (final Map<String, Object?> r in rows) {
        Object? j;
        try {
          j = jsonDecode(r['data'] as String);
        } catch (_) {
          continue;
        }
        if (j is! Map<String, dynamic>) continue;
        bool changed = false;
        for (final String f in e.value) {
          final Object? v = j[f];
          if (v is num) {
            j[f] = v is int ? v * 10 : (v * 10);
            changed = true;
          }
        }
        if (changed) {
          await t.update('entity_rows', <String, Object?>{'data': jsonEncode(j)},
              where: 'entity=? AND uid=?', whereArgs: <Object?>[e.key, r['uid']]);
        }
      }
    }
  }
}
