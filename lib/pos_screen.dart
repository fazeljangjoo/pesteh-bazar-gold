import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'license_service.dart';
import 'party_field.dart';
import 'print_service.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'scan_entry.dart';
import 'utils.dart';
import 'widgets.dart';

// S12.T12.2 — Touch POS. Creates NORMAL sales through AppDb.insertSale (same path as SaleForm):
// one sale per cart line (a sale is bound to one lot). Payments = normal receipts (lump tx).
// Hold/shift data lives per device in SharedPreferences. Fully offline (local SQLite only).

const String _kHeldKey = 'pos_held_carts';
const String _kShiftKey = 'pos_shift';

double _r3p(double v) => (v * 1000).round() / 1000;
double _r2p(double v) => (v * 100).round() / 100;
String _n(String s) => toEnDigits(s.replaceAll('ي', 'ی').replaceAll('ك', 'ک')).trim().toLowerCase();

class _Line {
  final Map<String, dynamic> lot;
  double qty;
  double price;
  double discPct;
  _Line(this.lot, this.qty, this.price, this.discPct);

  int get pid => (lot['id'] as num).toInt();
  double get effPrice => _r2p(price * (1 - discPct / 100));
  double get total => _r2p(qty * effPrice);
  String get name => '${lot['type_name'] ?? '-'}';
  String get code => '${lot['code'] ?? '-'}';
}

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});
  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  List<Map<String, dynamic>> _lots = <Map<String, dynamic>>[];
  final List<_Line> _cart = <_Line>[];
  final TextEditingController _search = TextEditingController();
  final TextEditingController _buyer = TextEditingController();
  final TextEditingController _usdRate = TextEditingController();
  final Map<int, double> _lastPrice = <int, double>{};
  List<Map<String, dynamic>> _held = <Map<String, dynamic>>[];
  Map<String, dynamic> _shift = <String, dynamic>{};
  Map<String, dynamic>? _lastReceipt;
  bool _autoPrint = true;
  bool _loading = true;
  bool _busy = false;
  String _q = '';

  bool get _fx => LicenseService.I.isFx.value;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _search.dispose();
    _buyer.dispose();
    _usdRate.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    try {
      final String? h = sp.getString(_kHeldKey);
      if (h != null) _held = (jsonDecode(h) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final String? s = sp.getString(_kShiftKey);
      if (s != null) _shift = Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      _held = <Map<String, dynamic>>[];
      _shift = <String, dynamic>{};
    }
    if (_shift['start'] == null) {
      _shift = <String, dynamic>{'start': DateTime.now().toIso8601String(), 'float': 0, 'sales': <dynamic>[]};
    }
    await _reloadLots();
  }

  Future<void> _reloadLots() async {
    final List<Map<String, dynamic>> l = await AppDb.I.lots();
    if (!mounted) return;
    setState(() {
      _lots = l.where((e) => ((e['remaining'] as num?) ?? 0) > 0).toList();
      _loading = false;
    });
  }

  Future<void> _saveHeld() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kHeldKey, jsonEncode(_held));
  }

  Future<void> _saveShift() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kShiftKey, jsonEncode(_shift));
  }

  // ---------------------------- cart ----------------------------
  double _inCart(int pid) {
    double s = 0;
    for (final _Line l in _cart) {
      if (l.pid == pid) s += l.qty;
    }
    return s;
  }

  double _avail(Map<String, dynamic> lot) =>
      ((lot['remaining'] as num).toDouble() - _inCart((lot['id'] as num).toInt()));

  double get _total {
    double s = 0;
    for (final _Line l in _cart) {
      s += l.total;
    }
    return _r2p(s);
  }

  Future<void> _addLot(Map<String, dynamic> lot) async {
    final double avail = _avail(lot);
    if (avail <= 0) {
      snack(context, 'موجودی این قلم تمام شده یا همه‌اش در سبد است');
      return;
    }
    final int pid = (lot['id'] as num).toInt();
    final _Line? r = await showDialog<_Line>(
      context: context,
      builder: (_) => _QtyDialog(lot: lot, avail: avail, price: _lastPrice[pid]),
    );
    if (r == null || !mounted) return;
    _lastPrice[pid] = r.price;
    setState(() => _cart.add(r));
  }

  Future<void> _scan() async {
    final String? code = await scanBarcode(context);
    if (code == null || !mounted) return;
    final Map<String, dynamic>? lot = await AppDb.I.lotByCode(code);
    if (!mounted) return;
    if (lot == null) {
      snack(context, 'قلمی با این کد پیدا نشد');
      return;
    }
    final int id = (lot['id'] as num).toInt();
    Map<String, dynamic>? mine;
    for (final Map<String, dynamic> e in _lots) {
      if (e['id'] == id) mine = e;
    }
    if (mine == null) {
      snack(context, 'موجودی این قلم صفر است');
      return;
    }
    await _addLot(mine);
  }

  Future<void> _editLine(int i) async {
    final _Line l = _cart[i];
    final double others = _inCart(l.pid) - l.qty;
    final double avail = (l.lot['remaining'] as num).toDouble() - others;
    final _Line? r = await showDialog<_Line>(
      context: context,
      builder: (_) => _QtyDialog(lot: l.lot, avail: avail, price: l.price, qty: l.qty, disc: l.discPct),
    );
    if (r == null || !mounted) return;
    setState(() {
      l.qty = r.qty;
      l.price = r.price;
      l.discPct = r.discPct;
    });
  }

  // ---------------------------- hold / resume ----------------------------
  Future<void> _hold() async {
    if (_cart.isEmpty) return;
    _held.add(<String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'buyer': _buyer.text.trim(),
      'lines': _cart
          .map((l) => <String, dynamic>{'pid': l.pid, 'qty': l.qty, 'price': l.price, 'disc': l.discPct})
          .toList(),
    });
    await _saveHeld();
    if (!mounted) return;
    setState(() {
      _cart.clear();
      _buyer.clear();
    });
    snack(context, 'سبد نگه داشته شد');
  }

  Future<void> _resume() async {
    if (_held.isEmpty) {
      snack(context, 'سبد نگه‌داشته‌شده‌ای نیست');
      return;
    }
    final int? idx = await showDialog<int>(
      context: context,
      builder: (BuildContext c) => SimpleDialog(
        title: const Text('سبدهای نگه‌داشته‌شده'),
        children: <Widget>[
          for (int i = 0; i < _held.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, i),
              child: ListTile(
                title: Text('${jalaliDate(_held[i]['ts'] as String)} — ${(_held[i]['lines'] as List).length} قلم'),
                subtitle: Text((_held[i]['buyer'] as String?)?.isNotEmpty == true
                    ? _held[i]['buyer'] as String
                    : 'مشتری متفرقه'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    _held.removeAt(i);
                    await _saveHeld();
                    if (c.mounted) Navigator.pop(c, -1);
                  },
                ),
              ),
            ),
        ],
      ),
    );
    if (idx == null || idx < 0 || !mounted) {
      if (idx == -1 && mounted) setState(() {});
      return;
    }
    if (_cart.isNotEmpty) {
      final bool ok = await confirm(context, 'سبد فعلی پاک و سبد انتخابی جایگزین شود؟');
      if (!ok || !mounted) return;
    }
    final Map<String, dynamic> h = _held[idx];
    final List<_Line> lines = <_Line>[];
    int skipped = 0;
    for (final dynamic raw in (h['lines'] as List)) {
      final Map<String, dynamic> m = Map<String, dynamic>.from(raw as Map);
      Map<String, dynamic>? lot;
      for (final Map<String, dynamic> e in _lots) {
        if (e['id'] == (m['pid'] as num).toInt()) lot = e;
      }
      if (lot == null) {
        skipped++;
        continue;
      }
      lines.add(_Line(lot, (m['qty'] as num).toDouble(), (m['price'] as num).toDouble(), (m['disc'] as num).toDouble()));
    }
    _held.removeAt(idx);
    await _saveHeld();
    if (!mounted) return;
    setState(() {
      _cart
        ..clear()
        ..addAll(lines);
      _buyer.text = (h['buyer'] as String?) ?? '';
    });
    if (skipped > 0) snack(context, '$skipped قلم دیگر در انبار موجود نبود و حذف شد');
  }

  // ---------------------------- checkout ----------------------------
  Future<void> _checkout() async {
    if (_busy || _cart.isEmpty) return;
    final double rate = parseNum(_usdRate.text) ?? 0;
    if (_fx && rate <= 0) {
      snack(context, 'قیمت دلار روز فروش را وارد کنید');
      return;
    }
    for (final _Line l in _cart) {
      if (l.price <= 0 || l.qty <= 0) {
        snack(context, 'فی و وزن همهٔ اقلام باید بیشتر از صفر باشد');
        return;
      }
      final double rem = (l.lot['remaining'] as num).toDouble();
      if (_inCart(l.pid) > rem + 1e-6) {
        snack(context, 'وزن «${l.name}» در سبد از موجودی بیشتر است');
        return;
      }
    }
    final String buyer = _buyer.text.trim();
    final double total = _total;
    final Map<String, double>? pay = await showDialog<Map<String, double>>(
      context: context,
      builder: (_) => _PayDialog(total: total, hasCustomer: buyer.isNotEmpty),
    );
    if (pay == null || !mounted) return;

    setState(() => _busy = true);
    double cashLeft = pay['cash'] ?? 0;
    double cardLeft = pay['card'] ?? 0;
    final DateTime now = DateTime.now();
    final List<_Line> done = <_Line>[];
    double paidCash = 0, paidCard = 0;
    String? err;
    for (final _Line l in List<_Line>.from(_cart)) {
      try {
        final double net = _r3p(l.qty);
        final List<Map<String, dynamic>> items = <Map<String, dynamic>>[
          <String, dynamic>{
            'purchase_id': l.pid,
            'weight': net,
            'item_price': l.effPrice,
            'small_sacks': null,
            'large_sacks': null,
          }
        ];
        final Map<String, dynamic> saleData = <String, dynamic>{
          if (_fx) 'usd_rate': rate,
          'price': l.effPrice,
          'total_weight': net,
          'small_sack_count': 0,
          'large_sack_count': 0,
          'net_weight': net,
          'buyer': buyer.isEmpty ? null : buyer,
          'note': 'POS',
          'labor_cost': null,
          'transport_cost': null,
          'date': now.toIso8601String(),
        };
        final int sid = await AppDb.I.insertSale(saleData, items);
        // allocate payments (cash first, then card); the remainder stays unpaid = credit
        double due = l.total;
        final double c = cashLeft < due ? cashLeft : due;
        due -= c;
        final double k = cardLeft < due ? cardLeft : due;
        if (c + k > 0) {
          final int rid = await AppDb.I.setReceiptType(sid, 'lump', null);
          if (c > 0) await AppDb.I.addReceiptLumpTx(rid, _rx(c, 'نقد', buyer, now));
          if (k > 0) await AppDb.I.addReceiptLumpTx(rid, _rx(k, 'کارت', buyer, now));
        }
        cashLeft -= c;
        cardLeft -= k;
        paidCash += c;
        paidCard += k;
        done.add(l);
      } catch (e) {
        err = '$e';
        break;
      }
    }
    final double doneTotal = _r2p(done.fold<double>(0, (double a, _Line l) => a + l.total));
    final double credit = _r2p(doneTotal - paidCash - paidCard);
    if (done.isNotEmpty) {
      (_shift['sales'] as List).add(<String, dynamic>{
        'ts': now.toIso8601String(),
        'total': doneTotal,
        'cash': paidCash,
        'card': paidCard,
        'credit': credit < 0 ? 0 : credit,
      });
      await _saveShift();
      _lastReceipt = <String, dynamic>{
        'ts': now.toIso8601String(),
        'buyer': buyer,
        'lines': done
            .map((l) => <String, dynamic>{
                  'name': l.name,
                  'code': l.code,
                  'qty': l.qty,
                  'price': l.effPrice,
                  'total': l.total,
                })
            .toList(),
        'total': doneTotal,
        'cash': paidCash,
        'card': paidCard,
        'credit': credit < 0 ? 0 : credit,
      };
    }
    await _reloadLots();
    if (!mounted) return;
    setState(() {
      for (final _Line l in done) {
        _cart.remove(l);
      }
      _busy = false;
      if (_cart.isEmpty) _buyer.clear();
    });
    if (err != null) {
      snack(context, '${done.length} قلم ثبت شد؛ ادامه ناموفق بود: $err');
    } else {
      snack(context, 'فروش ثبت شد');
    }
    if (done.isNotEmpty && _autoPrint && mounted) await _printLast();
  }

  Map<String, dynamic> _rx(double amount, String acc, String buyer, DateTime d) => <String, dynamic>{
        'amount': amount,
        'date': d.toIso8601String(),
        'from_account': acc,
        'payer_name': buyer,
        'to_account': '',
        'receiver_name': '',
        'paid': 1,
      };

  Future<void> _printLast() async {
    final Map<String, dynamic>? r = _lastReceipt;
    if (r == null) {
      snack(context, 'رسیدی برای چاپ نیست');
      return;
    }
    try {
      final List<List<String>> rows = <List<String>>[
        for (final dynamic raw in (r['lines'] as List))
          <String>[
            '${(raw as Map)['name']} (${raw['code']})',
            faNum(raw['qty'] as num),
            faNum(raw['price'] as num),
            faNum(raw['total'] as num),
          ]
      ];
      final String buyer = (r['buyer'] as String?) ?? '';
      final File file = await PdfService.buildDocument(
        title: 'رسید فروش',
        fileTag: 'POS',
        header: <List<String>>[
          <String>['تاریخ', jalaliDate(r['ts'] as String)],
          <String>['مشتری', buyer.isEmpty ? 'متفرقه' : buyer],
        ],
        columns: const <String>['شرح', 'وزن (کیلو)', 'فی', 'مبلغ'],
        rows: rows,
        totals: <List<String>>[
          <String>['جمع کل', faNum(r['total'] as num)],
          <String>['نقد', faNum(r['cash'] as num)],
          <String>['کارت', faNum(r['card'] as num)],
          <String>['نسیه', faNum(r['credit'] as num)],
        ],
        qrData: 'POS-${DateTime.parse(r['ts'] as String).millisecondsSinceEpoch}',
      );
      if (mounted) await PrintService.printFile(context, file);
    } catch (e) {
      if (mounted) snack(context, 'خطا در چاپ رسید: $e');
    }
  }

  // ---------------------------- shift ----------------------------
  Future<void> _shiftDialog() async {
    final List<dynamic> sales = _shift['sales'] as List;
    double cash = 0, card = 0, credit = 0, total = 0;
    for (final dynamic s in sales) {
      final Map m = s as Map;
      cash += (m['cash'] as num).toDouble();
      card += (m['card'] as num).toDouble();
      credit += (m['credit'] as num).toDouble();
      total += (m['total'] as num).toDouble();
    }
    final TextEditingController fl = TextEditingController(text: plain((_shift['float'] as num?) ?? 0));
    final String? act = await showDialog<String>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c2, StateSetter ss) {
          final double fv = parseNum(fl.text) ?? 0;
          return AlertDialog(
            title: const Text('خلاصهٔ شیفت'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('شروع: ${jalaliDate(_shift['start'] as String)}'),
                  Text('تعداد فروش: ${faNum(sales.length)}'),
                  const Divider(),
                  Text('جمع فروش: ${faNum(total)}'),
                  Text('نقد: ${faNum(cash)}'),
                  Text('کارت: ${faNum(card)}'),
                  Text('نسیه: ${faNum(credit)}'),
                  const Divider(),
                  TextField(
                    controller: fl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'موجودی اولیهٔ کشو'),
                    onChanged: (_) => ss(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text('موجودی مورد انتظار کشو: ${faNum(fv + cash)}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(onPressed: () => Navigator.pop(c, 'close'), child: const Text('بستن')),
              TextButton(onPressed: () => Navigator.pop(c, 'save'), child: const Text('ذخیرهٔ موجودی اولیه')),
              TextButton(onPressed: () => Navigator.pop(c, 'end'), child: const Text('پایان شیفت')),
            ],
          );
        },
      ),
    );
    final double fv = parseNum(fl.text) ?? 0;
    fl.dispose();
    if (act == null || act == 'close') return;
    if (act == 'save') {
      _shift['float'] = fv;
      await _saveShift();
    } else if (act == 'end') {
      if (!mounted) return;
      final bool ok = await confirm(context, 'شیفت بسته و شمارنده‌ها صفر شود؟ (فروش‌های ثبت‌شده دست‌نخورده می‌مانند)');
      if (!ok) return;
      _shift = <String, dynamic>{'start': DateTime.now().toIso8601String(), 'float': fv, 'sales': <dynamic>[]};
      await _saveShift();
    }
  }

  // ---------------------------- UI ----------------------------
  List<Map<String, dynamic>> get _filtered {
    final String q = _n(_q);
    if (q.isEmpty) return _lots;
    return _lots.where((e) => _n('${e['type_name'] ?? ''} ${e['code'] ?? ''} ${e['category_name'] ?? ''}').contains(q)).toList();
  }

  Widget _products() {
    final List<Map<String, dynamic>> l = _filtered;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _search,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search), hintText: 'جستجوی نوع یا کد', border: OutlineInputBorder()),
                  onChanged: (String v) => setState(() => _q = v),
                  onSubmitted: (String v) async {
                    final Map<String, dynamic>? lot = await AppDb.I.lotByCode(v);
                    if (lot != null && mounted) {
                      _search.clear();
                      setState(() => _q = '');
                      for (final Map<String, dynamic> e in _lots) {
                        if (e['id'] == lot['id']) {
                          await _addLot(e);
                          return;
                        }
                      }
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                    onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('اسکن')),
              ),
            ],
          ),
        ),
        Expanded(
          child: l.isEmpty
              ? const Center(child: Text('قلمی پیدا نشد'))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 220, mainAxisExtent: 110, crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: l.length,
                  itemBuilder: (BuildContext c, int i) {
                    final Map<String, dynamic> e = l[i];
                    final double a = _avail(e);
                    return Card(
                      child: InkWell(
                        onTap: a > 0 ? () => _addLot(e) : null,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Text('${e['type_name'] ?? '-'}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                              Text('کد ${e['code'] ?? '-'}'),
                              Text('موجودی: ${faNum(a)} کیلو',
                                  style: TextStyle(color: a > 0 ? Colors.green.shade800 : Colors.red)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _cartPanel() {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Column(
            children: <Widget>[
              PartyField(controller: _buyer, label: 'مشتری (خالی = متفرقه)'),
              if (_fx)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _usdRate,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                        labelText: 'قیمت دلار امروز', border: OutlineInputBorder()),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _cart.isEmpty
              ? const Center(child: Text('سبد خالی است'))
              : ListView.separated(
                  itemCount: _cart.length,
                  separatorBuilder: (BuildContext c, int i) => const Divider(height: 1),
                  itemBuilder: (BuildContext c, int i) {
                    final _Line l = _cart[i];
                    return ListTile(
                      minVerticalPadding: 12,
                      title: Text('${l.name} (${l.code})', style: const TextStyle(fontSize: 16)),
                      subtitle: Text(
                          '${faNum(l.qty)} کیلو × ${faNum(l.effPrice)}${l.discPct > 0 ? '  (تخفیف ${faNum(l.discPct)}٪)' : ''}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(faNum(l.total), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => setState(() => _cart.removeAt(i))),
                        ],
                      ),
                      onTap: () => _editLine(i),
                    );
                  },
                ),
        ),
        Container(
          padding: const EdgeInsets.all(8),
          color: Colors.black12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('جمع کل: ${faNum(_total)}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _cart.isEmpty ? null : _hold, child: const Text('نگه داشتن'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _resume, child: Text('سبدها (${faNum(_held.length)})'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton(
                          onPressed: _cart.isEmpty ? null : () => setState(() => _cart.clear()),
                          child: const Text('خالی کردن'))),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 60,
                child: FilledButton(
                  onPressed: (_cart.isEmpty || _busy) ? null : _checkout,
                  child: _busy
                      ? const CircularProgressIndicator()
                      : const Text('پرداخت و ثبت فروش', style: TextStyle(fontSize: 20)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!StaffPerms.I.can('pos.use') || !StaffPerms.I.can('sales.create')) {
      return Scaffold(
        appBar: AppBar(title: const Text('صندوق فروش')),
        body: const Center(child: Text('مجوز استفاده از صندوق فروش را ندارید')),
      );
    }
    final List<Widget> actions = <Widget>[
      IconButton(
          tooltip: 'چاپ خودکار رسید',
          icon: Icon(_autoPrint ? Icons.print : Icons.print_disabled),
          onPressed: () => setState(() => _autoPrint = !_autoPrint)),
      IconButton(tooltip: 'چاپ آخرین رسید', icon: const Icon(Icons.receipt_long), onPressed: _printLast),
      IconButton(tooltip: 'تنظیمات چاپ', icon: const Icon(Icons.settings_outlined), onPressed: () => showPrintSettings(context)),
      IconButton(tooltip: 'خلاصهٔ شیفت', icon: const Icon(Icons.point_of_sale), onPressed: _shiftDialog),
    ];
    if (_loading) {
      return Scaffold(
          appBar: AppBar(title: const Text('صندوق فروش')), body: const Center(child: CircularProgressIndicator()));
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints bc) {
        if (bc.maxWidth >= 800) {
          return Scaffold(
            appBar: AppBar(title: const Text('صندوق فروش'), actions: actions),
            body: Row(
              children: <Widget>[
                Expanded(flex: 3, child: _products()),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: _cartPanel()),
              ],
            ),
          );
        }
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('صندوق فروش'),
              actions: actions,
              bottom: TabBar(tabs: <Widget>[
                const Tab(text: 'اجناس'),
                Tab(text: 'سبد (${faNum(_cart.length)})'),
              ]),
            ),
            body: TabBarView(children: <Widget>[_products(), _cartPanel()]),
          ),
        );
      },
    );
  }
}

// ---------------------------- dialogs ----------------------------

class _QtyDialog extends StatefulWidget {
  final Map<String, dynamic> lot;
  final double avail;
  final double? price;
  final double? qty;
  final double? disc;
  const _QtyDialog({required this.lot, required this.avail, this.price, this.qty, this.disc});
  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late String _qty;
  late final TextEditingController _price;
  late final TextEditingController _disc;

  @override
  void initState() {
    super.initState();
    _qty = widget.qty == null ? '' : plain(widget.qty!);
    _price = TextEditingController(text: widget.price == null ? '' : plain(widget.price!));
    _disc = TextEditingController(text: (widget.disc ?? 0) > 0 ? plain(widget.disc!) : '');
  }

  @override
  void dispose() {
    _price.dispose();
    _disc.dispose();
    super.dispose();
  }

  void _key(String k) {
    setState(() {
      if (k == '<') {
        if (_qty.isNotEmpty) _qty = _qty.substring(0, _qty.length - 1);
      } else if (k == '.') {
        if (!_qty.contains('.')) _qty = _qty.isEmpty ? '0.' : '$_qty.';
      } else {
        if (_qty.length < 9) _qty = '$_qty$k';
      }
    });
  }

  void _add(double v) => setState(() => _qty = plain(_r3p((double.tryParse(_qty) ?? 0) + v)));

  void _ok() {
    final double q = _r3p(double.tryParse(_qty) ?? 0);
    final double p = parseNum(_price.text) ?? 0;
    final double d = parseNum(_disc.text) ?? 0;
    if (q <= 0) return snack(context, 'وزن را وارد کنید');
    if (q > widget.avail + 1e-6) return snack(context, 'بیشتر از موجودی (${faNum(widget.avail)} کیلو) است');
    if (p <= 0) return snack(context, 'فی فروش را وارد کنید');
    if (d < 0 || d > 100) return snack(context, 'تخفیف باید بین ۰ تا ۱۰۰ درصد باشد');
    Navigator.pop(context, _Line(widget.lot, q, p, d));
  }

  @override
  Widget build(BuildContext context) {
    final List<String> keys = <String>['7', '8', '9', '4', '5', '6', '1', '2', '3', '.', '0', '<'];
    return AlertDialog(
      title: Text('${widget.lot['type_name'] ?? '-'} — موجودی ${faNum(widget.avail)} کیلو'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_qty.isEmpty ? '۰ کیلو' : '${toFaDigits(_qty)} کیلو',
                    style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              ),
              Wrap(
                spacing: 6,
                children: <Widget>[
                  for (final double v in <double>[0.5, 1, 5, 10, 25])
                    ActionChip(label: Text('+${faNum(v)}'), onPressed: () => _add(v)),
                  ActionChip(label: const Text('همه'), onPressed: () => setState(() => _qty = plain(widget.avail))),
                ],
              ),
              const SizedBox(height: 8),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.9,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: <Widget>[
                  for (final String k in keys)
                    FilledButton.tonal(
                      onPressed: () => _key(k),
                      child: k == '<'
                          ? const Icon(Icons.backspace_outlined)
                          : Text(k == '.' ? '٫' : toFaDigits(k), style: const TextStyle(fontSize: 24)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _price,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'فی فروش (هر کیلو)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _disc,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'تخفیف (درصد)', border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: _ok, child: const Text('افزودن به سبد')),
      ],
    );
  }
}

class _PayDialog extends StatefulWidget {
  final double total;
  final bool hasCustomer;
  const _PayDialog({required this.total, required this.hasCustomer});
  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  late final TextEditingController _cash = TextEditingController(text: plain(widget.total));
  final TextEditingController _card = TextEditingController();

  @override
  void dispose() {
    _cash.dispose();
    _card.dispose();
    super.dispose();
  }

  double get _cashV => parseNum(_cash.text) ?? 0;
  double get _cardV => parseNum(_card.text) ?? 0;
  double get _credit => _r2p(widget.total - _cashV - _cardV);

  void _ok() {
    if (_cashV < 0 || _cardV < 0) return snack(context, 'مبلغ نامعتبر است');
    if (_credit < -0.005) return snack(context, 'جمع نقد و کارت از مبلغ فروش بیشتر است');
    if (_credit > 0.005 && !widget.hasCustomer) {
      return snack(context, 'برای نسیه باید مشتری انتخاب شود');
    }
    Navigator.pop(context, <String, double>{'cash': _cashV, 'card': _cardV});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('پرداخت — ${faNum(widget.total)}'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _cash,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(labelText: 'نقد', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _card,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(labelText: 'کارت', border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Text('نسیه (باقی‌مانده): ${faNum(_credit < 0 ? 0 : _credit)}',
                style: TextStyle(fontSize: 18, color: _credit < -0.005 ? Colors.red : null)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: _ok, child: const Text('ثبت فروش')),
      ],
    );
  }
}
