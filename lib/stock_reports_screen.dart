import 'dart:io';

import 'package:flutter/material.dart';

import 'charts.dart';
import 'db.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'stock_ccy.dart';
import 'utils.dart';
import 'warehouse_ui.dart';
import 'widgets.dart';

/// T01.5 گزارش‌های انبار: گردش (ledger)، موجودی (balance)، ترکیب موجودی (mix).
/// آنلاین است (StockApi → reports.stock_*). خروجی Excel در S13 به همین صفحه اضافه می‌شود.

const List<Color> _palette = <Color>[
  Color(0xFF2E7D32),
  Color(0xFFEF6C00),
  Color(0xFF1565C0),
  Color(0xFF8E24AA),
  Color(0xFFC62828),
  Color(0xFF00897B),
  Color(0xFFF9A825),
  Color(0xFF6D4C41),
];

const Map<String, String> _byOptions = <String, String>{
  'warehouse': 'انبار',
  'ounce': 'انس',
  'type': 'نوع پسته',
};

double _n(Map<String, dynamic>? p, String k) {
  final v = p?[k];
  return v is num ? v.toDouble() : 0;
}

Map<String, dynamic>? _m(Map<String, dynamic>? p, String k) {
  final v = p?[k];
  return v is Map ? Map<String, dynamic>.from(v) : null;
}

List<Map<String, dynamic>> _listOf(Map<String, dynamic>? p, String k) {
  final out = <Map<String, dynamic>>[];
  final raw = p?[k];
  if (raw is List) {
    for (final x in raw) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
  }
  return out;
}

String _itemLabel(Map<String, dynamic> it) => (it['label'] ?? '-').toString();

String _kindLabel(String k) {
  const Map<String, String> m = <String, String>{
    'purchase': 'خرید',
    'mix_in': 'ورود ترکیب',
    'mix_out': 'مصرف ترکیب',
    'sale': 'فروش',
    'adjust': 'اصلاح',
    'transfer_in': 'انتقال ورودی',
    'transfer_out': 'انتقال خروجی',
  };
  return m[k] ?? k;
}

class StockReportsScreen extends StatefulWidget {
  const StockReportsScreen({super.key});

  @override
  State<StockReportsScreen> createState() => _StockReportsScreenState();
}

class _StockReportsScreenState extends State<StockReportsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tc;
  String? _wh;
  String? _ounce;
  String? _type;
  DateTime? _from;
  DateTime? _to;
  String _by = 'warehouse';
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _ledger;
  Map<String, dynamic>? _balance;
  Map<String, dynamic>? _mix;
  final StockCcy _fx = StockCcy(); // S30.T30.6b: ارز نمودار موجودی (null = کیلو)
  Map<String, String> _whNames = <String, String>{};
  Map<String, String> _ounceNames = <String, String>{};
  List<WhOption> _whOpts = <WhOption>[];
  List<String> _types = <String>[];

  @override
  void initState() {
    super.initState();
    _tc = TabController(length: 3, vsync: this);
    _fx.load(() {
      if (mounted) setState(() {});
    });
    _init();
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final whNames = await StockLookup.warehouseNames();
      final ounces = await StockLookup.ounceCodes();
      final whOpts = await StockLookup.warehouses(includeInactive: true);
      final all = await AppDb.I.inventoryAll();
      final types = <String>{};
      for (final Map<String, dynamic> l in all) {
        final t = (l['type_name'] ?? '').toString();
        if (t.isNotEmpty) types.add(t);
      }
      if (!mounted) return;
      setState(() {
        _whNames = whNames;
        _ounceNames = ounces;
        _whOpts = whOpts;
        _types = types.toList()..sort();
      });
    } catch (_) {
      // فهرست‌ها اختیاری‌اند؛ گزارش بدونشان هم کار می‌کند
    }
    await _reload();
  }

  Map<String, dynamic> _filters() {
    final m = <String, dynamic>{};
    if (_wh != null) m['warehouse_uid'] = _wh;
    if (_ounce != null) m['ounce_uid'] = _ounce;
    if (_type != null) m['type_name'] = _type;
    return m;
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _periodText() {
    final f = _from == null ? '...' : jalaliDateFromDt(_from!);
    final t = _to == null ? '...' : jalaliDateFromDt(_to!);
    return 'بازه: $f تا $t';
  }

  String _byLabel() => _byOptions[_by] ?? '';

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final ledgerP = <String, dynamic>{..._filters()};
    if (_from != null) ledgerP['from'] = _iso(_from!);
    if (_to != null) ledgerP['to'] = _iso(_to!);
    final balP = <String, dynamic>{..._filters(), 'by': _by};
    if (_to != null) balP['to'] = _iso(_to!);
    final mixP = <String, dynamic>{..._filters(), 'by': _by};
    try {
      final r = await Future.wait<Map<String, dynamic>>(<Future<Map<String, dynamic>>>[
        StockApi.call('reports.stock_ledger', ledgerP),
        StockApi.call('reports.stock_balance', balP),
        StockApi.call('reports.stock_mix', mixP),
      ]);
      if (!mounted) return;
      setState(() {
        _ledger = r[0];
        _balance = r[1];
        _mix = r[2];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pick(bool isFrom) async {
    final d = await pickDate(context, initial: isFrom ? (_from ?? _to) : (_to ?? _from));
    if (d == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _to = d;
      }
    });
    await _reload();
  }

  String _whLabel(String? uid) {
    if (uid == null || uid.isEmpty) return '-';
    return _whNames[uid] ?? 'انبار نامشخص';
  }

  // ---------------- فیلترها ----------------

  Widget _dropdown(String label, String? value, List<DropdownMenuItem<String?>> items, ValueChanged<String?> onChanged) {
    return SizedBox(
      width: 160,
      child: DropdownButtonFormField<String?>(
        value: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  Widget _filterBar(BuildContext context) {
    final whItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('همه')),
      ..._whOpts.map((WhOption o) => DropdownMenuItem<String?>(value: o.uid, child: Text(o.name))),
    ];
    final ounceItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('همه')),
      ..._ounceNames.entries.map((MapEntry<String, String> e) => DropdownMenuItem<String?>(value: e.key, child: Text(e.value))),
    ];
    final typeItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('همه')),
      ..._types.map((String t) => DropdownMenuItem<String?>(value: t, child: Text(t))),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Wrap(spacing: 8, runSpacing: 6, children: <Widget>[
          _dropdown('انبار', _wh, whItems, (String? v) {
            setState(() {
              _wh = v;
            });
            _reload();
          }),
          _dropdown('انس', _ounce, ounceItems, (String? v) {
            setState(() {
              _ounce = v;
            });
            _reload();
          }),
          _dropdown('نوع پسته', _type, typeItems, (String? v) {
            setState(() {
              _type = v;
            });
            _reload();
          }),
        ]),
        const SizedBox(height: 6),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pick(true),
              icon: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!), overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pick(false),
              icon: const Icon(Icons.date_range_outlined, size: 18),
              label: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!), overflow: TextOverflow.ellipsis),
            ),
          ),
          if (_from != null || _to != null)
            IconButton(
              tooltip: 'پاک‌کردن بازهٔ تاریخ',
              icon: const Icon(Icons.clear),
              onPressed: () {
                setState(() {
                  _from = null;
                  _to = null;
                });
                _reload();
              },
            ),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 6, children: <Widget>[
          for (final MapEntry<String, String> e in _byOptions.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _by == e.key,
              onSelected: (bool sel) {
                setState(() {
                  _by = e.key;
                });
                _reload();
              },
            ),
        ]),
      ]),
    );
  }

  // ---------------- تب گردش ----------------

  Widget _ledgerRow(Map<String, dynamic> r) {
    final kg = _n(r, 'kg');
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        title: Text('${jalaliDate((r['date'] ?? '').toString())}  •  ${_kindLabel((r['kind'] ?? '').toString())}'),
        subtitle: Text(
          '${(r['lot_code'] ?? '-')} • ${_whLabel(r['warehouse_uid']?.toString())} • مانده ${faNum(_n(r, 'balance_kg'))} کیلو',
        ),
        trailing: Text(
          faNum(kg),
          style: TextStyle(
            color: kg < 0 ? Colors.red.shade700 : Colors.green.shade800,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _ledgerTab(BuildContext context) {
    final l = _ledger;
    if (l == null) return const Center(child: CircularProgressIndicator());
    final op = _m(l, 'opening');
    final inn = _m(l, 'in');
    final out = _m(l, 'out');
    final cl = _m(l, 'closing');
    final rows = _listOf(l, 'rows');
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        ChartCard(
          title: 'خلاصهٔ گردش (کیلو)',
          subtitle: _periodText(),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            infoRow('موجودی ابتدای دوره', faNum(_n(op, 'kg'))),
            infoRow('ورودی', '+${faNum(_n(inn, 'kg'))}', valueColor: Colors.green.shade800),
            infoRow('خروجی', '-${faNum(_n(out, 'kg'))}', valueColor: Colors.red.shade700),
            infoRow('موجودی پایان دوره', faNum(_n(cl, 'kg'))),
            infoRow('گونی کوچک / بزرگ (پایان)', '${faNum(_n(cl, 'small_sacks'), dec: 0)} / ${faNum(_n(cl, 'large_sacks'), dec: 0)}'),
          ]),
        ),
        const SizedBox(height: 12),
        if (l['truncated'] == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'فقط ۲۰۰۰ حرکت اول فهرست شده؛ اعداد خلاصه کامل هستند.',
              style: TextStyle(color: Colors.orange.shade800, fontSize: 12),
            ),
          ),
        if (rows.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('حرکتی در این بازه نیست'))),
        for (final Map<String, dynamic> r in rows) _ledgerRow(r),
      ],
    );
  }

  // ---------------- تب موجودی ----------------

  Widget _groupTile(Map<String, dynamic> it) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        title: Text(_itemLabel(it)),
        subtitle: Text(
          '${faNum(_n(it, 'small_sacks'), dec: 0)} گونی کوچک • ${faNum(_n(it, 'large_sacks'), dec: 0)} گونی بزرگ • ${faNum(_n(it, 'lots'), dec: 0)} لات',
        ),
        trailing: Text('${faNum(_n(it, 'kg'))} کیلو', style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _balanceTab(BuildContext context) {
    final b = _balance;
    if (b == null) return const Center(child: CircularProgressIndicator());
    final items = _listOf(b, 'items');
    final tot = _m(b, 'total');
    final hasCheck = b['cached_kg'] != null;
    final diff = _n(b, 'diff_kg');
    final groups = <BarGroup>[];
    final String? cc = _fx.ccy;
    final String iso = StockCcy.isoOf(_to);
    int noRate = 0;
    for (final Map<String, dynamic> it in items) {
      final lbl = _itemLabel(it);
      final short = lbl.length > 6 ? '${lbl.substring(0, 6)}…' : lbl;
      if (cc == null) {
        groups.add(BarGroup(short, lbl, <double>[_n(it, 'kg')]));
      } else {
        final double? v = _fx.convert(_n(it, 'value'), iso);
        if (v == null) {
          noRate++;
        } else {
          groups.add(BarGroup(short, lbl, <double>[v]));
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        ChartCard(
          title: 'موجودی بر اساس ${_byLabel()}',
          subtitle: _to == null ? 'موجودی امروز' : 'موجودی تا ${jalaliDateFromDt(_to!)}',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            infoRow('مجموع موجودی (کیلو)', faNum(_n(tot, 'kg'))),
            infoRow('گونی کوچک', faNum(_n(tot, 'small_sacks'))),
            infoRow('گونی بزرگ', faNum(_n(tot, 'large_sacks'))),
            if (hasCheck) infoRow('مجموع باقیمانده لات‌ها', faNum(_n(b, 'cached_kg'))),
            if (hasCheck)
              infoRow(
                'اختلاف دفتر با لات‌ها',
                faNum(diff),
                valueColor: diff.abs() < 0.0005 ? Colors.green.shade800 : Colors.red.shade700,
              ),
          ]),
        ),
        const SizedBox(height: 12),
        if (groups.isNotEmpty || cc != null)
          ChartCard(
            title: cc == null ? 'نمودار موجودی (کیلو)' : 'نمودار ارزش موجودی ($cc)',
            subtitle: cc == null ? null : 'به بهای تمام‌شدهٔ لات‌ها، با آخرین نرخ ثبت‌شده تا ${jalaliDateFromDt(_to ?? DateTime.now())}',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              StockCcySwitch(st: _fx, onChanged: (String? v) => setState(() => _fx.ccy = v)),
              if (groups.isEmpty)
                ChartEmpty('برای $cc نرخ ثبت‌شده‌ای در جدول نرخ نیست')
              else
                GroupedBarChart(
                  groups: groups,
                  series: <BarSeries>[BarSeries(cc ?? 'کیلو', const Color(0xFF2E7D32))],
                  format: (double v) => cc == null ? faNum(v) : '${faCompactCcy(v)} $cc',
                  compact: (double v) => cc == null ? faCompact(v) : faCompactCcy(v),
                ),
              if (cc != null && noRate > 0 && groups.isNotEmpty)
                Text('${faNum(noRate, dec: 0)} مورد به‌دلیل نبودنِ نرخ ثبت‌شده در نمودار نیامده است.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade900)),
            ]),
          ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Padding(padding: EdgeInsets.all(20), child: Center(child: Text('موجودی‌ای یافت نشد')))
        else
          for (final Map<String, dynamic> it in items) _groupTile(it),
      ],
    );
  }

  // ---------------- تب ترکیب ----------------

  Widget _mixTab(BuildContext context) {
    final m = _mix;
    if (m == null) return const Center(child: CircularProgressIndicator());
    final items = _listOf(m, 'items');
    final slices = <ChartSlice>[];
    final String? cc = _fx.ccy;
    final String iso = StockCcy.isoOf(_to);
    double totCc = 0;
    for (int i = 0; i < items.length; i++) {
      final kg = _n(items[i], 'kg');
      if (kg <= 0) continue;
      if (cc == null) {
        slices.add(ChartSlice(_itemLabel(items[i]), kg, _palette[i % _palette.length]));
      } else {
        final double? v = _fx.convert(_n(items[i], 'value'), iso);
        if (v != null && v > 0) {
          slices.add(ChartSlice(_itemLabel(items[i]), v, _palette[i % _palette.length]));
          totCc += v;
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        ChartCard(
          title: 'ترکیب موجودی',
          subtitle: 'بر اساس ${_byLabel()} • فقط مقادیر مثبت',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            StockCcySwitch(st: _fx, onChanged: (String? v) => setState(() => _fx.ccy = v)),
            if (slices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(cc == null ? 'موجودی مثبتی یافت نشد' : 'برای $cc نرخ ثبت‌شده‌ای در جدول نرخ نیست'),
              )
            else
              Center(
                child: DonutChart(
                  slices: slices,
                  centerTitle: cc == null ? 'کل (کیلو)' : 'ارزش کل ($cc)',
                  format: (double v) => cc == null ? faNum(v) : faCompactCcy(v),
                  centerValue: cc == null ? _n(m, 'positive_kg') : totCc,
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < items.length; i++)
          Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: CircleAvatar(radius: 8, backgroundColor: _palette[i % _palette.length]),
              title: Text(_itemLabel(items[i])),
              subtitle: Text('${faNum(_n(items[i], 'kg'))} کیلو'),
              trailing: Text(
                '${faNum(_n(items[i], 'percent'), dec: 1)}٪',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }

  // ---------------- خروجی PDF ----------------
  // S13 hook: خروجی Excel همین منو/دکمه را خواهد داشت؛ فعلاً فقط PDF.

  Future<void> _exportPdf() async {
    try {
      final summary = <List<String>>[];
      final table = <List<String>>[];
      String title;
      if (_tc.index == 0) {
        final l = _ledger;
        final op = _m(l, 'opening');
        final inn = _m(l, 'in');
        final out = _m(l, 'out');
        final cl = _m(l, 'closing');
        title = 'گزارش گردش انبار';
        summary.add(<String>['موجودی ابتدای دوره (کیلو)', faNum(_n(op, 'kg'))]);
        summary.add(<String>['ورودی (کیلو)', faNum(_n(inn, 'kg'))]);
        summary.add(<String>['خروجی (کیلو)', faNum(_n(out, 'kg'))]);
        summary.add(<String>['موجودی پایان دوره (کیلو)', faNum(_n(cl, 'kg'))]);
        table.add(<String>['تاریخ', 'نوع حرکت', 'کد لات', 'انبار', 'تغییر (کیلو)', 'مانده (کیلو)']);
        for (final Map<String, dynamic> r in _listOf(l, 'rows')) {
          table.add(<String>[
            jalaliDate((r['date'] ?? '').toString()),
            _kindLabel((r['kind'] ?? '').toString()),
            (r['lot_code'] ?? '-').toString(),
            _whLabel(r['warehouse_uid']?.toString()),
            faNum(_n(r, 'kg')),
            faNum(_n(r, 'balance_kg')),
          ]);
        }
      } else if (_tc.index == 1) {
        final b = _balance;
        final tot = _m(b, 'total');
        title = 'گزارش موجودی انبار بر اساس ${_byLabel()}';
        summary.add(<String>['مجموع موجودی (کیلو)', faNum(_n(tot, 'kg'))]);
        table.add(<String>['گروه', 'کیلو', 'گونی کوچک', 'گونی بزرگ', 'تعداد لات']);
        for (final Map<String, dynamic> it in _listOf(b, 'items')) {
          table.add(<String>[
            _itemLabel(it),
            faNum(_n(it, 'kg')),
            faNum(_n(it, 'small_sacks'), dec: 0),
            faNum(_n(it, 'large_sacks'), dec: 0),
            faNum(_n(it, 'lots'), dec: 0),
          ]);
        }
      } else {
        final m = _mix;
        title = 'گزارش ترکیب موجودی بر اساس ${_byLabel()}';
        summary.add(<String>['مجموع مثبت (کیلو)', faNum(_n(m, 'positive_kg'))]);
        table.add(<String>['گروه', 'کیلو', 'درصد']);
        for (final Map<String, dynamic> it in _listOf(m, 'items')) {
          table.add(<String>[
            _itemLabel(it),
            faNum(_n(it, 'kg')),
            '${faNum(_n(it, 'percent'), dec: 1)}٪',
          ]);
        }
      }
      final File file = await PdfService.buildStockReport(
        title: title,
        periodLabel: _periodText(),
        summary: summary,
        tableRows: table,
      );
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'خطا در ساخت PDF: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('گزارش‌های انبار'),
        bottom: TabBar(
          controller: _tc,
          tabs: const <Tab>[
            Tab(text: 'گردش انبار'),
            Tab(text: 'موجودی'),
            Tab(text: 'ترکیب'),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'خروجی PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _loading ? null : () => _exportPdf(),
          ),
          IconButton(
            tooltip: 'بروزرسانی',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _reload(),
          ),
        ],
      ),
      body: Column(children: <Widget>[
        _filterBar(context),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
          ),
        Expanded(
          child: TabBarView(
            controller: _tc,
            children: <Widget>[
              _ledgerTab(context),
              _balanceTab(context),
              _mixTab(context),
            ],
          ),
        ),
      ]),
    );
  }
}
