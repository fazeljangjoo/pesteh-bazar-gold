// S26.T26.1 — local cache tables for currencies and daily rates (offline read-only copy).
// The server is the source of truth (server/backend/api/fx_currencies.php, fx_rates.php).
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

class FxLocal {
  FxLocal._();

  /// Creates both cache tables (IF NOT EXISTS, so re-running is safe). Called from _onCreate and _onUpgrade(oldV < 20).
  static Future<void> createTables(DatabaseExecutor d) async {
    await d.execute('CREATE TABLE IF NOT EXISTS currencies('
        'id INTEGER PRIMARY KEY, code TEXT NOT NULL, name TEXT NOT NULL, symbol TEXT, '
        'decimals INTEGER NOT NULL DEFAULT 2, is_base INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1)');
    await d.execute('CREATE TABLE IF NOT EXISTS fx_rates('
        'id INTEGER PRIMARY KEY, ccy TEXT NOT NULL, rate_date TEXT NOT NULL, rate TEXT NOT NULL, source TEXT, '
        'UNIQUE(ccy, rate_date))');
  }

  /// Replaces the cached currency list with the server copy.
  static Future<void> saveCurrencies(List<Map<String, dynamic>> rows) async {
    final Database d = await AppDb.I.db;
    await d.transaction((Transaction t) async {
      await t.execute('DELETE FROM currencies');
      for (final Map<String, dynamic> r in rows) {
        await t.insert('currencies', <String, Object?>{
          'id': r['id'],
          'code': r['code'],
          'name': r['name'],
          'symbol': r['symbol'] ?? '',
          'decimals': r['decimals'] ?? 2,
          'is_base': (r['is_base'] == true) ? 1 : 0,
          'active': (r['active'] == true) ? 1 : 0,
        });
      }
    });
  }

  /// Cached currencies in the same shape as the server (for offline display).
  static Future<List<Map<String, dynamic>>> loadCurrencies() async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> rows = await d.rawQuery('SELECT * FROM currencies ORDER BY is_base DESC, code');
    return rows.map((Map<String, Object?> r) => <String, dynamic>{
          'id': r['id'],
          'code': r['code'],
          'name': r['name'],
          'symbol': r['symbol'],
          'decimals': r['decimals'],
          'is_base': r['is_base'] == 1,
          'active': r['active'] == 1,
        }).toList();
  }

  /// Cached rates of one currency, newest first (offline read-only view).
  static Future<List<Map<String, dynamic>>> loadRatesCached(String ccy) async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> rows = await d.rawQuery(
        'SELECT * FROM fx_rates WHERE ccy = ? ORDER BY rate_date DESC', <Object?>[ccy]);
    return rows.map((Map<String, Object?> r) => <String, dynamic>{
          'id': r['id'],
          'ccy': r['ccy'],
          'rate_date': r['rate_date'],
          'rate': r['rate'],
          'source': r['source'] ?? '',
        }).toList();
  }

  /// Replaces cached rates of one currency (or all when [ccy] is null) with the server copy.
  static Future<void> saveRates(List<Map<String, dynamic>> rows, {String? ccy}) async {
    final Database d = await AppDb.I.db;
    await d.transaction((Transaction t) async {
      if (ccy == null) {
        await t.execute('DELETE FROM fx_rates');
      } else {
        await t.execute('DELETE FROM fx_rates WHERE ccy = ?', <Object?>[ccy]);
      }
      for (final Map<String, dynamic> r in rows) {
        await t.insert('fx_rates', <String, Object?>{
          'id': r['id'],
          'ccy': r['ccy'],
          'rate_date': r['rate_date'],
          'rate': r['rate'].toString(),
          'source': r['source'] ?? '',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
  /// S27c: آخرین نرخ کش‌شده ≤ [isoDate] (yyyy-MM-dd). null = برای این ارز نرخی در دستگاه نیست.
  /// rate = ریال به‌ازای یک واحد ارز؛ date = تاریخ همان نرخ (برای هشدار کهنگی).
  static Future<({double rate, String date})?> rateAt(String ccy, String isoDate) async {
    final Database d = await AppDb.I.db;
    final List<Map<String, Object?>> rows = await d.rawQuery(
        'SELECT rate, rate_date FROM fx_rates WHERE ccy = ? AND rate_date <= ? ORDER BY rate_date DESC LIMIT 1',
        <Object?>[ccy, isoDate]);
    if (rows.isEmpty) return null;
    final double? v = double.tryParse((rows.first['rate'] ?? '').toString());
    if (v == null || v <= 0) return null;
    return (rate: v, date: (rows.first['rate_date'] ?? '').toString());
  }

  /// فاصلهٔ روزی نرخ تا امروز؛ نرخِ ≥ ۳۰ روز قدیمی هشدار می‌گیرد.
  static int ageDays(String rateIsoDate) {
    final DateTime? d = DateTime.tryParse(rateIsoDate);
    if (d == null) return 0;
    return DateTime.now().difference(d).inDays;
  }

  static const int staleAfterDays = 30;

  /// کش ارزها و نرخ‌ها را از سرور تازه می‌کند (آنلاین). خطا بی‌صدا نادیده گرفته می‌شود (آفلاین = همان کش قبلی).
  /// بعد از موفقیت، عملیات «نرخ ثبت نشده»ی صف دوباره pending می‌شوند. true = کش تازه شد.
  static Future<bool> refresh() async {
    try {
      final Map<String, dynamic> cr = await StockApi.call('fx.currencies.list');
      final List<Map<String, dynamic>> curs = fxAsList(cr['currencies']);
      if (curs.isEmpty) return false;
      await saveCurrencies(curs);
      final List<Map<String, dynamic>> all = <Map<String, dynamic>>[];
      for (final Map<String, dynamic> c in curs) {
        if (c['is_base'] == true || c['active'] != true) continue;
        final Map<String, dynamic> rr = await StockApi.call('fx.rates.list', <String, dynamic>{'ccy': c['code']});
        all.addAll(fxAsList(rr['rates']));
      }
      await saveRates(all);
      await AppDb.I.retryRateMissingOps();
      return true;
    } on StockApiException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Safe conversion of a server list field into typed rows.
List<Map<String, dynamic>> fxAsList(Object? v) {
  if (v is! List) return <Map<String, dynamic>>[];
  return v.whereType<Map>().map((Map m) => Map<String, dynamic>.from(m)).toList();
}

/// yyyy-MM-dd (Gregorian) for the server's rate_date.
String fxIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
