// S30.T30.5 — real foreign-currency profit of the listed sales, valued ONLY from the registered rate table
// (fx_rates: rial per one unit of currency, latest rate on or before the date). No rate => no number, a warning instead.
import 'package:flutter/material.dart';

import 'fx_doc_field.dart' show kFxRialPerStoredUnit;
import 'fx_local.dart';
import 'utils.dart';

class FxProfitBlock extends StatefulWidget {
  final List<Map<String, dynamic>> sales;
  const FxProfitBlock({super.key, required this.sales});

  @override
  State<FxProfitBlock> createState() => _FxProfitBlockState();
}

class _FxProfitBlockState extends State<FxProfitBlock> {
  List<String> _codes = <String>[];
  String? _ccy;
  List<({String date, double rate})> _rates = <({String date, double rate})>[]; // newest first
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final List<Map<String, dynamic>> cur = await FxLocal.loadCurrencies();
      final List<String> codes = cur
          .where((Map<String, dynamic> c) => c['is_base'] != true && c['active'] == true)
          .map((Map<String, dynamic> c) => '${c['code']}')
          .toList();
      if (!mounted) return;
      _codes = codes;
      if (codes.isNotEmpty) await _pick(codes.contains('USD') ? 'USD' : codes.first);
    } catch (_) {
      _codes = <String>[];
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _pick(String code) async {
    final List<Map<String, dynamic>> rows = await FxLocal.loadRatesCached(code);
    final List<({String date, double rate})> out = <({String date, double rate})>[];
    for (final Map<String, dynamic> r in rows) {
      final double? v = double.tryParse('${r['rate']}');
      if (v != null && v > 0) out.add((date: '${r['rate_date']}', rate: v));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    if (!mounted) return;
    setState(() {
      _ccy = code;
      _rates = out;
    });
  }

  /// Rate in the stored money unit per one foreign unit on [iso], or null when the table has none on/before that date.
  double? _rateOf(String iso) {
    for (final ({String date, double rate}) r in _rates) {
      if (r.date.compareTo(iso) <= 0) return r.rate / kFxRialPerStoredUnit;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _codes.isEmpty || _ccy == null) return const SizedBox.shrink();
    double rev = 0, cost = 0;
    int ok = 0, missing = 0;
    for (final Map<String, dynamic> s in widget.sales) {
      final ({double revenue, double cost, double profit})? f = saleFx(s, _rateOf);
      if (f == null) {
        missing++;
      } else {
        ok++;
        rev += f.revenue;
        cost += f.cost;
      }
    }
    final String c = _ccy!;
    Widget row(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: <Widget>[
            Expanded(child: Text(k)),
            Text(v, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const Divider(),
      Row(children: <Widget>[
        const Expanded(child: Text('سود ارزی (از جدول نرخ ثبت‌شده)', style: TextStyle(fontWeight: FontWeight.bold))),
        DropdownButton<String>(
          value: c,
          items: _codes.map((String x) => DropdownMenuItem<String>(value: x, child: Text(x))).toList(),
          onChanged: (String? v) {
            if (v != null) _pick(v);
          },
        ),
      ]),
      if (ok > 0) ...<Widget>[
        row('مجموع فروش ($c)', faCcy(c, rev)),
        row('مجموع بها و هزینه‌ها ($c)', faCcy(c, cost)),
        row('سود / زیان ($c)', faCcy(c, rev - cost), color: (rev - cost) >= 0 ? Colors.green.shade800 : Colors.red.shade800),
      ],
      if (missing > 0)
        Text(
          ok == 0
              ? 'برای $c نرخ ثبت‌شده‌ای پیش از تاریخ این فروش‌ها نیست؛ سود ارزی نمایش داده نمی‌شود. نرخ را در بخش نرخ ارز وارد کنید.'
              : '${faNum(missing, dec: 0)} فروش به‌دلیل نبودنِ نرخ ثبت‌شده در این جمع نیامده است.',
          style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
        ),
    ]);
  }
}

/// S30.T30.6 — in-memory book of the registered rates of every active foreign currency (for multi-currency charts).
class FxRateBook {
  final List<String> codes;
  final Map<String, List<({String date, double rate})>> _rates; // per ccy, newest first; rial per one unit
  FxRateBook._(this.codes, this._rates);

  static Future<FxRateBook> load() async {
    final List<Map<String, dynamic>> cur = await FxLocal.loadCurrencies();
    final List<String> codes = cur
        .where((Map<String, dynamic> c) => c['is_base'] != true && c['active'] == true)
        .map((Map<String, dynamic> c) => '${c['code']}')
        .toList();
    final Map<String, List<({String date, double rate})>> m = <String, List<({String date, double rate})>>{};
    for (final String code in codes) {
      final List<({String date, double rate})> out = <({String date, double rate})>[];
      for (final Map<String, dynamic> r in await FxLocal.loadRatesCached(code)) {
        final double? v = double.tryParse('${r['rate']}');
        if (v != null && v > 0) out.add((date: '${r['rate_date']}', rate: v));
      }
      out.sort((a, b) => b.date.compareTo(a.date));
      m[code] = out;
    }
    return FxRateBook._(codes, m);
  }

  /// Stored-money-unit rate per one [ccy] unit on [iso] (latest on/before), or null when none is registered.
  double? rateOf(String ccy, String iso) {
    for (final ({String date, double rate}) r in _rates[ccy] ?? const <({String date, double rate})>[]) {
      if (r.date.compareTo(iso) <= 0) return r.rate / kFxRialPerStoredUnit;
    }
    return null;
  }
}
