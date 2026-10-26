import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S04.T04.4b — offline-first replacement for `StockApi.call` for returns and pro-formas.
///
/// Same action names / payload / result shapes as the server (`returns.php`, `sale_returns.php`,
/// `proformas.php`) so the UI only swaps the caller. Writes go to the local mirror tables
/// (negative temp ids) + `sync_ops` (idempotent through `uid`); reads come from the local mirror.
/// The next successful pull replaces everything with the server's numbers (number, ids).
/// `proformas.convert` is local too (T04.4c): local sales + `proformas.link_sales` op.
class OfflineDocs {
  OfflineDocs._();

  static double _d(dynamic v) => (v is num) ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0.0);
  static int _i(dynamic v) => (v is num) ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
  static String? _s(dynamic v, int max) {
    final String t = '${v ?? ''}'.trim();
    if (t.isEmpty) return null;
    return t.length > max ? t.substring(0, max) : t;
  }

  static String _today() {
    final DateTime n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static String _date(dynamic v) {
    final String t = '${v ?? ''}'.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(t)) throw StockApiException('تاریخ نامعتبر است');
    return t.substring(0, 10);
  }

  static String _uid(dynamic v, String prefix) {
    final String t = '${v ?? ''}'.trim();
    if (RegExp(r'^[A-Za-z0-9_-]{8,40}$').hasMatch(t)) return t;
    return '$prefix${DateTime.now().microsecondsSinceEpoch}';
  }

  static const List<String> _saleModes = <String>['reduce_receivable', 'cash_refund', 'cheque_given'];
  static const List<String> _purModes = <String>['reduce_payable', 'cash_refund', 'cheque_back'];

  /// Local-first call. Unknown actions fall through to the online API.
  static Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> p = const <String, dynamic>{}]) async {
    try {
      switch (action) {
        case 'sale_returns.create':
          return await _createReturn(true, p);
        case 'purchase_returns.create':
          return await _createReturn(false, p);
        case 'sale_returns.delete':
          return await _deleteReturn(true, p);
        case 'purchase_returns.delete':
          return await _deleteReturn(false, p);
        case 'sale_returns.list':
          return await _listReturns(true, p);
        case 'purchase_returns.list':
          return await _listReturns(false, p);
        case 'sale_returns.get':
          return await _getReturn(true, p);
        case 'purchase_returns.get':
          return await _getReturn(false, p);
        case 'sale_returns.summary':
          return await _summary(p);
        case 'proformas.list':
          return await _pfList(p);
        case 'proformas.get':
          return await _pfGet(p);
        case 'proformas.save':
          return await _pfSave(p);
        case 'proformas.set_status':
          return await _pfStatus(p);
        case 'proformas.delete':
          return await _pfDelete(p);
        case 'proformas.convert':
          return await _pfConvert(p);
      }
    } on StockApiException {
      rethrow;
    } on DatabaseException catch (e) {
      throw StockApiException('خطای دیتابیس محلی: $e');
    }
    return StockApi.call(action, p);
  }

  // ======================= returns =======================
  static Future<Map<String, dynamic>> _createReturn(bool isSale, Map<String, dynamic> p) async {
    final String tbl = isSale ? 'sale_returns' : 'purchase_returns';
    final String itbl = isSale ? 'sale_return_items' : 'purchase_return_items';
    final String kind = isSale ? 'sret' : 'pret';
    final Database d = await AppDb.I.db;
    final String uid = _uid(p['uid'], 'r');
    final List<Map<String, Object?>> dup = await d.query(tbl, columns: <String>['id', 'number'], where: 'uid=?', whereArgs: <Object?>[uid], limit: 1);
    if (dup.isNotEmpty) return <String, dynamic>{'id': _i(dup.first['id']), 'number': _i(dup.first['number'])};
    final String date = _date(p['date']);
    final String? note = _s(p['note'], 500);
    final List<String> modes = isSale ? _saleModes : _purModes;
    final String mode = '${p['refund_mode'] ?? modes.first}';
    if (!modes.contains(mode)) throw StockApiException('نوع تسویهٔ برگشت نامعتبر است');
    final dynamic rawItems = p['items'];
    if (rawItems is! List || rawItems.isEmpty || rawItems.length > 20) {
      throw StockApiException('حداقل یک و حداکثر ۲۰ قلم برای برگشت لازم است');
    }
    late int rid;
    late double total;
    late double refund;
    late int number;
    await AppDb.I.docWrite((Database d) async {
      await d.transaction((Transaction t) async {
        String? party;
        final List<Map<String, dynamic>> lines = <Map<String, dynamic>>[];
        final Map<String, List<double>> asked = <String, List<double>>{};
        for (final dynamic raw in rawItems) {
          if (raw is! Map) throw StockApiException('قلم برگشت نامعتبر است');
          final double kg = _d(raw['kg']);
          if (kg <= 0 || kg > 1e9) throw StockApiException('وزن برگشت باید بزرگ‌تر از صفر باشد');
          final double small = _d(raw['small_sacks']);
          final double large = _d(raw['large_sacks']);
          if (small < 0 || large < 0) throw StockApiException('تعداد گونی نامعتبر است');
          int lot;
          int saleId = 0;
          String key;
          double price;
          if (isSale) {
            saleId = await AppDb.I.currentId('sale', _i(raw['sale_id']));
            if (saleId == 0) throw StockApiException('فروش مورد برگشت را انتخاب کنید');
            final List<Map<String, Object?>> sale = await t.query('sales', where: 'id=?', whereArgs: <Object?>[saleId], limit: 1);
            if (sale.isEmpty) throw StockApiException('فروش انتخابی یافت نشد');
            final int want = _i(raw['lot_id'] ?? raw['purchase_id']);
            final List<Map<String, Object?>> its = await t.query('sale_items',
                where: want == 0 ? 'sale_id=?' : 'sale_id=? AND purchase_id=?',
                whereArgs: want == 0 ? <Object?>[saleId] : <Object?>[saleId, want]);
            if (its.isEmpty) throw StockApiException('فروش انتخابی یافت نشد');
            if (its.length > 1) throw StockApiException('این فروش چندقلمی است؛ قلم (خرید) را مشخص کنید');
            final Map<String, Object?> it = its.first;
            lot = _i(it['purchase_id']);
            key = '$saleId:$lot';
            final String bk = '${sale.first['buyer'] ?? ''}'.trim();
            if (bk.isEmpty) throw StockApiException('این فروش خریدار (طرف‌حساب) ندارد؛ ابتدا نام خریدار را در فروش ثبت کنید');
            if (party == null) {
              party = bk;
            } else if (party != bk) {
              throw StockApiException('همهٔ اقلام یک برگشت باید مربوط به یک طرف‌حساب باشند');
            }
            final List<Map<String, Object?>> prev = await t.rawQuery(
                'SELECT COALESCE(SUM(kg),0) AS k, COALESCE(SUM(small_sacks),0) AS s, COALESCE(SUM(large_sacks),0) AS l '
                'FROM sale_return_items WHERE sale_id=? AND lot_id=?',
                <Object?>[saleId, lot]);
            final List<double> a = asked[key] ?? <double>[0, 0, 0];
            a[0] += kg;
            a[1] += small;
            a[2] += large;
            asked[key] = a;
            if (a[0] + _d(prev.first['k']) - _d(it['weight']) > 1e-6) {
              throw StockApiException('مجموع برگشت‌ها از وزن فروخته‌شده بیشتر می‌شود');
            }
            if (a[1] + _d(prev.first['s']) - _d(it['small_sacks']) > 1e-6 || a[2] + _d(prev.first['l']) - _d(it['large_sacks']) > 1e-6) {
              throw StockApiException('گونی برگشتی از گونی فروخته‌شده بیشتر می‌شود');
            }
            final double sold = it['item_price'] != null ? _d(it['item_price']) : _d(sale.first['price']);
            price = (raw['unit_price'] == null || '${raw['unit_price']}'.isEmpty) ? sold : _d(raw['unit_price']);
          } else {
            lot = await AppDb.I.currentId('pur', _i(raw['lot_id'] ?? raw['purchase_id']));
            final List<Map<String, Object?>> pu = await t.query('purchases', where: 'id=?', whereArgs: <Object?>[lot], limit: 1);
            if (pu.isEmpty) throw StockApiException('خرید (لات) انتخابی یافت نشد');
            key = '$lot';
            final String sk = '${pu.first['seller'] ?? ''}'.trim();
            if (sk.isEmpty) throw StockApiException('این خرید فروشنده (طرف‌حساب) ندارد؛ ابتدا نام فروشنده را در خرید ثبت کنید');
            if (party == null) {
              party = sk;
            } else if (party != sk) {
              throw StockApiException('همهٔ اقلام یک برگشت باید مربوط به یک طرف‌حساب باشند');
            }
            final List<double> a = asked[key] ?? <double>[0, 0, 0];
            a[0] += kg;
            asked[key] = a;
            if (a[0] - _d(pu.first['remaining']) > 1e-6) throw StockApiException('موجودی این بار از وزن برگشت کمتر است');
            price = (raw['unit_price'] == null || '${raw['unit_price']}'.isEmpty) ? _d(pu.first['price']) : _d(raw['unit_price']);
          }
          if (price < 0 || price > 1e13) throw StockApiException('فی برگشت نامعتبر است');
          lines.add(<String, dynamic>{'sale': saleId, 'lot': lot, 'kg': kg, 'small': small, 'large': large, 'price': price});
        }
        total = 0;
        for (final Map<String, dynamic> l in lines) {
          total += (l['kg'] as double) * (l['price'] as double);
        }
        refund = 0;
        String? chequeNo;
        String? chequeDue;
        if (mode != modes.first) {
          refund = (p['refund_amount'] == null || '${p['refund_amount']}'.isEmpty) ? total : _d(p['refund_amount']);
          if (refund < 0 || refund - total > 0.005) throw StockApiException('مبلغ بازپرداخت نمی‌تواند از ارزش برگشت بیشتر باشد');
          if (mode == 'cheque_given' || mode == 'cheque_back') {
            chequeNo = _s(p['cheque_no'], 60);
            final String cd = '${p['cheque_due'] ?? ''}'.trim();
            chequeDue = cd.isEmpty ? null : _date(cd);
          }
        }
        final List<Map<String, Object?>> mx = await t.rawQuery('SELECT COALESCE(MAX(number),0)+1 AS n FROM $tbl');
        number = _i(mx.first['n']);
        rid = await AppDb.I.docTempId(t, tbl);
        await t.insert(tbl, <String, Object?>{
          'id': rid, 'uid': uid, 'number': number, 'party': party, 'date': date, 'refund_mode': mode,
          'refund_amount': refund, 'cheque_no': chequeNo, 'cheque_due': chequeDue, 'note': note,
          'created_at': date,
        });
        final List<Map<String, dynamic>> payItems = <Map<String, dynamic>>[];
        for (final Map<String, dynamic> l in lines) {
          final int iid = await AppDb.I.docTempId(t, itbl);
          await t.insert(itbl, <String, Object?>{
            'id': iid, 'return_id': rid, if (isSale) 'sale_id': l['sale'], 'lot_id': l['lot'],
            'kg': l['kg'], 'small_sacks': l['small'], 'large_sacks': l['large'], 'unit_price': l['price'],
          });
          final double sgn = isSale ? 1 : -1;
          await AppDb.I.docStock(t, l['lot'] as int, sgn * (l['kg'] as double), sgn * (l['small'] as double), sgn * (l['large'] as double));
          payItems.add(<String, dynamic>{
            if (isSale) 'sale_id': l['sale'], 'lot_id': l['lot'], 'kg': l['kg'],
            'small_sacks': l['small'], 'large_sacks': l['large'], 'unit_price': l['price'],
          });
        }
        await AppDb.I.docEnqueue(t, '$tbl.create', <String, dynamic>{
          'uid': uid, 'date': date, 'note': note, 'refund_mode': mode,
          if (mode != modes.first) 'refund_amount': refund,
          if (chequeNo != null) 'cheque_no': chequeNo,
          if (chequeDue != null) 'cheque_due': chequeDue,
          'items': payItems,
        }, refKind: kind, refId: rid, mapKind: kind, localId: rid);
      });
    });
    AppDb.I.version.value++;
    return <String, dynamic>{'id': rid, 'number': number, 'total': total, 'refund_amount': refund};
  }

  static Future<Map<String, dynamic>> _deleteReturn(bool isSale, Map<String, dynamic> p) async {
    final String tbl = isSale ? 'sale_returns' : 'purchase_returns';
    final String itbl = isSale ? 'sale_return_items' : 'purchase_return_items';
    final String kind = isSale ? 'sret' : 'pret';
    final Database d = await AppDb.I.db;
    final int id = await AppDb.I.currentId(kind, _i(p['id']));
    await AppDb.I.docWrite((Database d) async {
      await d.transaction((Transaction t) async {
        final List<Map<String, Object?>> r = await t.query(tbl, where: 'id=?', whereArgs: <Object?>[id], limit: 1);
        if (r.isEmpty) throw StockApiException('برگشت یافت نشد');
        final List<Map<String, Object?>> its = await t.query(itbl, where: 'return_id=?', whereArgs: <Object?>[id]);
        for (final Map<String, Object?> it in its) {
          final int lot = _i(it['lot_id']);
          final double kg = _d(it['kg']);
          if (isSale) {
            // goods came back into the lot: they must still be there
            final List<Map<String, Object?>> pu = await t.query('purchases', columns: <String>['remaining'], where: 'id=?', whereArgs: <Object?>[lot], limit: 1);
            if (pu.isNotEmpty && kg - _d(pu.first['remaining']) > 1e-6) {
              throw StockApiException('کالای این برگشت دوباره فروخته/مصرف شده؛ حذف برگشت ممکن نیست');
            }
          }
          final double sgn = isSale ? -1 : 1;
          await AppDb.I.docStock(t, lot, sgn * kg, sgn * _d(it['small_sacks']), sgn * _d(it['large_sacks']));
        }
        await t.delete(itbl, where: 'return_id=?', whereArgs: <Object?>[id]);
        await t.delete(tbl, where: 'id=?', whereArgs: <Object?>[id]);
        if (id < 0) {
          await AppDb.I.docPurgeOps(t, kind, id);
        } else {
          await AppDb.I.docEnqueue(t, '$tbl.delete', <String, dynamic>{'id': id}, refKind: kind, refId: id);
        }
      });
    });
    AppDb.I.version.value++;
    return <String, dynamic>{'ok': true};
  }

  static Map<String, dynamic> _retRow(Map<String, Object?> r, double total) {
    final double refund = _d(r['refund_amount']);
    return <String, dynamic>{
      'id': _i(r['id']), 'uid': r['uid'], 'number': _i(r['number']), 'party': r['party'], 'date': r['date'],
      'refund_mode': r['refund_mode'], 'refund_amount': refund, 'cheque_no': r['cheque_no'], 'cheque_due': r['cheque_due'],
      'note': r['note'], 'total': total, 'net_effect': total - refund,
      'tax_amount': r['tax_amount'] == null ? null : _d(r['tax_amount']), 'voucher_id': null,
    };
  }

  static Future<Map<String, dynamic>> _listReturns(bool isSale, Map<String, dynamic> p) async {
    final String tbl = isSale ? 'sale_returns' : 'purchase_returns';
    final String itbl = isSale ? 'sale_return_items' : 'purchase_return_items';
    final Database d = await AppDb.I.db;
    final StringBuffer sql = StringBuffer(
        'SELECT r.*, COALESCE((SELECT SUM(i.kg * i.unit_price) FROM $itbl i WHERE i.return_id=r.id),0) AS total FROM $tbl r WHERE 1=1');
    final List<Object?> args = <Object?>[];
    final String party = '${p['party'] ?? ''}'.trim();
    if (party.isNotEmpty) {
      sql.write(' AND r.party=?');
      args.add(party);
    }
    if (isSale && _i(p['sale_id']) != 0) {
      sql.write(' AND EXISTS (SELECT 1 FROM sale_return_items x WHERE x.return_id=r.id AND x.sale_id=?)');
      args.add(await AppDb.I.currentId('sale', _i(p['sale_id'])));
    }
    if ('${p['from'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date>=?');
      args.add(_date(p['from']));
    }
    if ('${p['to'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date<=?');
      args.add(_date(p['to']));
    }
    sql.write(' ORDER BY r.date DESC, r.number DESC, r.id DESC LIMIT 500');
    final List<Map<String, Object?>> rows = await d.rawQuery(sql.toString(), args);
    return <String, dynamic>{'items': rows.map((Map<String, Object?> r) => _retRow(r, _d(r['total']))).toList()};
  }

  static Future<Map<String, dynamic>> _getReturn(bool isSale, Map<String, dynamic> p) async {
    final String tbl = isSale ? 'sale_returns' : 'purchase_returns';
    final String itbl = isSale ? 'sale_return_items' : 'purchase_return_items';
    final String kind = isSale ? 'sret' : 'pret';
    final Database d = await AppDb.I.db;
    final int id = await AppDb.I.currentId(kind, _i(p['id']));
    final List<Map<String, Object?>> r = await d.query(tbl, where: 'id=?', whereArgs: <Object?>[id], limit: 1);
    if (r.isEmpty) throw StockApiException('برگشت یافت نشد');
    final List<Map<String, Object?>> its = await d.rawQuery(
        'SELECT i.*, pu.code AS code, pu.type_name AS type_name, pu.price AS cost FROM $itbl i '
        'LEFT JOIN purchases pu ON pu.id=i.lot_id WHERE i.return_id=? ORDER BY i.id DESC',
        <Object?>[id]);
    double total = 0;
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final Map<String, Object?> x in its.reversed) {
      final double amt = _d(x['kg']) * _d(x['unit_price']);
      total += amt;
      items.add(<String, dynamic>{
        if (isSale) 'sale_id': _i(x['sale_id']), 'lot_id': _i(x['lot_id']), 'code': x['code'], 'type_name': x['type_name'],
        'warehouse_uid': x['warehouse_uid'], 'kg': _d(x['kg']), 'small_sacks': _d(x['small_sacks']), 'large_sacks': _d(x['large_sacks']),
        'unit_price': _d(x['unit_price']), 'amount': amt, if (isSale) 'cost': x['cost'] == null ? null : _d(x['cost']),
      });
    }
    return <String, dynamic>{..._retRow(r.first, total), 'items': items};
  }

  /// Local equivalent of `sale_returns.summary` (revenue/COGS reversed in a period, by return date).
  static Future<Map<String, dynamic>> _summary(Map<String, dynamic> p) async {
    final Database d = await AppDb.I.db;
    final StringBuffer sql = StringBuffer(
        'SELECT COALESCE(SUM(i.kg * i.unit_price),0) AS rev, COALESCE(SUM(i.kg * COALESCE(pu.price,0)),0) AS cogs, COUNT(DISTINCT r.id) AS n '
        'FROM sale_returns r JOIN sale_return_items i ON i.return_id=r.id LEFT JOIN purchases pu ON pu.id=i.lot_id WHERE 1=1');
    final List<Object?> args = <Object?>[];
    if ('${p['from'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date>=?');
      args.add(_date(p['from']));
    }
    if ('${p['to'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date<=?');
      args.add(_date(p['to']));
    }
    final List<Map<String, Object?>> r = await d.rawQuery(sql.toString(), args);
    final double rev = _d(r.first['rev']);
    final double cogs = _d(r.first['cogs']);
    return <String, dynamic>{'count': _i(r.first['n']), 'revenue_reversed': rev, 'cogs_reversed': cogs, 'profit_reversed': rev - cogs};
  }

  // ======================= pro-formas =======================
  static String _effective(String status, String? validUntil) {
    if ((status == 'draft' || status == 'sent') && validUntil != null && validUntil.isNotEmpty && validUntil.compareTo(_today()) < 0) {
      return 'expired';
    }
    return status;
  }

  static Map<String, dynamic> _pfRow(Map<String, Object?> r, double total) {
    final String? vu = (r['valid_until'] == null || '${r['valid_until']}'.isEmpty) ? null : '${r['valid_until']}';
    return <String, dynamic>{
      'id': _i(r['id']), 'uid': r['uid'], 'number': _i(r['number']), 'party': r['party'], 'date': r['date'],
      'valid_until': vu, 'status': _effective('${r['status']}', vu), 'status_raw': r['status'],
      'reserve': _i(r['reserve']) == 1, 'note': r['note'], 'terms': r['terms'], 'total': total,
      'converted_at': r['converted_at'], 'tax_amount': r['tax_amount'] == null ? null : _d(r['tax_amount']),
    };
  }

  static Future<Map<String, dynamic>> _pfList(Map<String, dynamic> p) async {
    final Database d = await AppDb.I.db;
    final StringBuffer sql = StringBuffer(
        'SELECT r.*, COALESCE((SELECT SUM(i.kg * i.unit_price - COALESCE(i.discount,0)) FROM proforma_items i WHERE i.proforma_id=r.id),0) AS total '
        'FROM proformas r WHERE 1=1');
    final List<Object?> args = <Object?>[];
    final String party = '${p['party'] ?? ''}'.trim();
    if (party.isNotEmpty) {
      sql.write(' AND r.party=?');
      args.add(party);
    }
    if ('${p['from'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date>=?');
      args.add(_date(p['from']));
    }
    if ('${p['to'] ?? ''}'.isNotEmpty) {
      sql.write(' AND r.date<=?');
      args.add(_date(p['to']));
    }
    sql.write(' ORDER BY r.date DESC, r.number DESC, r.id DESC LIMIT 500');
    final String want = '${p['status'] ?? ''}';
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, Object?> r in await d.rawQuery(sql.toString(), args)) {
      final Map<String, dynamic> row = _pfRow(r, _d(r['total']));
      if (want.isNotEmpty && row['status'] != want) continue;
      out.add(row);
    }
    return <String, dynamic>{'items': out};
  }

  static Future<Map<String, dynamic>> _pfGet(Map<String, dynamic> p) async {
    final Database d = await AppDb.I.db;
    final int id = await AppDb.I.currentId('pf', _i(p['id']));
    final List<Map<String, Object?>> r = await d.query('proformas', where: 'id=?', whereArgs: <Object?>[id], limit: 1);
    if (r.isEmpty) throw StockApiException('پیش‌فاکتور یافت نشد');
    final List<Map<String, Object?>> its = await d.rawQuery(
        'SELECT i.*, pu.code AS code, pu.type_name AS type_name, pu.remaining AS lot_remaining FROM proforma_items i '
        'LEFT JOIN purchases pu ON pu.id=i.lot_id WHERE i.proforma_id=? ORDER BY i.id DESC',
        <Object?>[id]);
    double total = 0;
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    for (final Map<String, Object?> x in its.reversed) {
      final double amt = _d(x['kg']) * _d(x['unit_price']) - _d(x['discount']);
      total += amt;
      items.add(<String, dynamic>{
        'lot_id': x['lot_id'] == null ? null : _i(x['lot_id']), 'description': x['description'], 'code': x['code'],
        'type_name': x['type_name'], 'kg': _d(x['kg']), 'unit_price': _d(x['unit_price']), 'discount': _d(x['discount']),
        'amount': amt, 'sale_id': x['sale_id'] == null ? null : _i(x['sale_id']),
        'lot_remaining': x['lot_remaining'] == null ? null : _d(x['lot_remaining']),
      });
    }
    return <String, dynamic>{..._pfRow(r.first, total), 'items': items};
  }

  static Future<Map<String, dynamic>> _pfSave(Map<String, dynamic> p) async {
    final Database d = await AppDb.I.db;
    int id = _i(p['id']);
    if (id != 0) id = await AppDb.I.currentId('pf', id);
    final String? party = _s(p['party'], 150);
    if (party == null) throw StockApiException('نام مشتری را وارد کنید');
    final String date = _date(p['date']);
    final String vuRaw = '${p['valid_until'] ?? ''}'.trim();
    final String? validUntil = vuRaw.isEmpty ? null : _date(vuRaw);
    if (validUntil != null && validUntil.compareTo(date) < 0) throw StockApiException('تاریخ اعتبار نمی‌تواند قبل از تاریخ پیش‌فاکتور باشد');
    final int reserve = (p['reserve'] == true || _i(p['reserve']) == 1) ? 1 : 0;
    final String? note = _s(p['note'], 500);
    final String? terms = _s(p['terms'], 1000);
    final dynamic rawItems = p['items'];
    if (rawItems is! List || rawItems.isEmpty || rawItems.length > 50) {
      throw StockApiException('حداقل یک و حداکثر ۵۰ قلم برای پیش‌فاکتور لازم است');
    }
    final List<Map<String, dynamic>> lines = <Map<String, dynamic>>[];
    for (final dynamic raw in rawItems) {
      if (raw is! Map) throw StockApiException('قلم پیش‌فاکتور نامعتبر است');
      final double kg = _d(raw['kg']);
      final double price = _d(raw['unit_price']);
      final double disc = _d(raw['discount']);
      if (kg <= 0 || kg > 1e9) throw StockApiException('وزن قلم باید بزرگ‌تر از صفر باشد');
      if (price <= 0 || price > 1e13) throw StockApiException('فی قلم نامعتبر است');
      if (disc < 0 || disc - kg * price > 0.005) throw StockApiException('تخفیف قلم نامعتبر است');
      int lot = _i(raw['lot_id'] ?? raw['purchase_id']);
      if (lot != 0) lot = await AppDb.I.currentId('pur', lot);
      final String? desc = _s(raw['description'], 200);
      if (lot == 0 && desc == null) throw StockApiException('برای هر قلم، لات انبار یا شرح کالا لازم است');
      lines.add(<String, dynamic>{'lot_id': lot == 0 ? null : lot, 'description': desc, 'kg': kg, 'unit_price': price, 'discount': disc});
    }
    double total = 0;
    for (final Map<String, dynamic> l in lines) {
      total += (l['kg'] as double) * (l['unit_price'] as double) - (l['discount'] as double);
    }
    late int number;
    await AppDb.I.docWrite((Database d) async {
      await d.transaction((Transaction t) async {
        final Map<String, dynamic> body = <String, dynamic>{
          'party': party, 'date': date, 'valid_until': validUntil, 'reserve': reserve, 'note': note, 'terms': terms, 'items': lines,
        };
        if (id != 0) {
          final List<Map<String, Object?>> cur = await t.query('proformas', where: 'id=?', whereArgs: <Object?>[id], limit: 1);
          if (cur.isEmpty) throw StockApiException('پیش‌فاکتور یافت نشد');
          if (cur.first['status'] == 'converted') throw StockApiException('پیش‌فاکتور تبدیل‌شده قابل ویرایش نیست');
          number = _i(cur.first['number']);
          await t.update('proformas', <String, Object?>{
            'party': party, 'date': date, 'valid_until': validUntil, 'reserve': reserve, 'note': note, 'terms': terms,
          }, where: 'id=?', whereArgs: <Object?>[id]);
          await t.delete('proforma_items', where: 'proforma_id=?', whereArgs: <Object?>[id]);
          await _pfInsertItems(t, id, lines);
          // still-unsent create: just refresh that queued op (same queue position, no `id`)
          final List<Map<String, Object?>> op = id < 0
              ? await t.query('sync_ops',
                  columns: <String>['seq', 'payload'],
                  where: "ref_kind='pf' AND ref_id=? AND action='proformas.save' AND state='pending'",
                  whereArgs: <Object?>[id],
                  orderBy: 'seq',
                  limit: 1)
              : <Map<String, Object?>>[];
          if (op.isNotEmpty) {
            final String uid = '${cur.first['uid']}';
            await AppDb.I.entityUpdateOp(t, _i(op.first['seq']), <String, dynamic>{'uid': uid, ...body});
          } else {
            await AppDb.I.docEnqueue(t, 'proformas.save', <String, dynamic>{'id': id, ...body}, refKind: 'pf', refId: id);
          }
        } else {
          final String uid = _uid(p['uid'], 'pf');
          final List<Map<String, Object?>> dup = await t.query('proformas', columns: <String>['id', 'number'], where: 'uid=?', whereArgs: <Object?>[uid], limit: 1);
          if (dup.isNotEmpty) {
            id = _i(dup.first['id']);
            number = _i(dup.first['number']);
            return;
          }
          final List<Map<String, Object?>> mx = await t.rawQuery('SELECT COALESCE(MAX(number),0)+1 AS n FROM proformas');
          number = _i(mx.first['n']);
          id = await AppDb.I.docTempId(t, 'proformas');
          await t.insert('proformas', <String, Object?>{
            'id': id, 'uid': uid, 'number': number, 'party': party, 'date': date, 'valid_until': validUntil, 'status': 'draft',
            'reserve': reserve, 'note': note, 'terms': terms, 'created_at': date,
          });
          await _pfInsertItems(t, id, lines);
          await AppDb.I.docEnqueue(t, 'proformas.save', <String, dynamic>{'uid': uid, ...body},
              refKind: 'pf', refId: id, mapKind: 'pf', localId: id);
        }
      });
    });
    AppDb.I.version.value++;
    return <String, dynamic>{'id': id, 'number': number, 'total': total};
  }

  static Future<void> _pfInsertItems(Transaction t, int pfId, List<Map<String, dynamic>> lines) async {
    for (final Map<String, dynamic> l in lines) {
      final int iid = await AppDb.I.docTempId(t, 'proforma_items');
      await t.insert('proforma_items', <String, Object?>{
        'id': iid, 'proforma_id': pfId, 'lot_id': l['lot_id'], 'description': l['description'],
        'kg': l['kg'], 'unit_price': l['unit_price'], 'discount': l['discount'],
      });
    }
  }

  static Future<Map<String, dynamic>> _pfStatus(Map<String, dynamic> p) async {
    final String to = '${p['status'] ?? ''}';
    if (!<String>['draft', 'sent', 'accepted', 'cancelled'].contains(to)) {
      throw StockApiException('وضعیت نامعتبر است (تبدیل به فروش با عملیات تبدیل انجام می‌شود)');
    }
    final Database d = await AppDb.I.db;
    final int id = await AppDb.I.currentId('pf', _i(p['id']));
    await AppDb.I.docWrite((Database d) async {
      await d.transaction((Transaction t) async {
        final List<Map<String, Object?>> cur = await t.query('proformas', columns: <String>['status'], where: 'id=?', whereArgs: <Object?>[id], limit: 1);
        if (cur.isEmpty) throw StockApiException('پیش‌فاکتور یافت نشد');
        if (cur.first['status'] == 'converted') throw StockApiException('پیش‌فاکتور تبدیل‌شده قابل تغییر وضعیت نیست');
        await t.update('proformas', <String, Object?>{'status': to}, where: 'id=?', whereArgs: <Object?>[id]);
        await AppDb.I.docEnqueue(t, 'proformas.set_status', <String, dynamic>{'id': id, 'status': to}, refKind: 'pf', refId: id);
      });
    });
    AppDb.I.version.value++;
    return <String, dynamic>{'ok': true};
  }

  static Future<Map<String, dynamic>> _pfDelete(Map<String, dynamic> p) async {
    final Database d = await AppDb.I.db;
    final int id = await AppDb.I.currentId('pf', _i(p['id']));
    await AppDb.I.docWrite((Database d) async {
      await d.transaction((Transaction t) async {
        final List<Map<String, Object?>> cur = await t.query('proformas', columns: <String>['status'], where: 'id=?', whereArgs: <Object?>[id], limit: 1);
        if (cur.isEmpty) throw StockApiException('پیش‌فاکتور یافت نشد');
        if (cur.first['status'] == 'converted') throw StockApiException('پیش‌فاکتور تبدیل‌شده حذف نمی‌شود (ابتدا فروش‌های آن را حذف کنید)');
        await t.delete('proforma_items', where: 'proforma_id=?', whereArgs: <Object?>[id]);
        await t.delete('proformas', where: 'id=?', whereArgs: <Object?>[id]);
        if (id < 0) {
          await AppDb.I.docPurgeOps(t, 'pf', id);
        } else {
          await AppDb.I.docEnqueue(t, 'proformas.delete', <String, dynamic>{'id': id}, refKind: 'pf', refId: id);
        }
      });
    });
    AppDb.I.version.value++;
    return <String, dynamic>{'ok': true};
  }

  /// Offline convert: local sales (one per item) + a queued `proformas.link_sales` op.
  static Future<Map<String, dynamic>> _pfConvert(Map<String, dynamic> p) async {
    final int id = await AppDb.I.currentId('pf', _i(p['id']));
    try {
      final List<int> ids = await AppDb.I.convertProformaLocal(id, _date(p['date'] ?? _today()));
      return <String, dynamic>{'ok': true, 'sale_ids': ids};
    } on DatabaseException catch (e) {
      throw StockApiException('خطای دیتابیس محلی: $e');
    } on StockApiException {
      rethrow;
    } catch (e) {
      throw StockApiException(e.toString().replaceFirst('Exception: ', ''));
    }
  }
}
