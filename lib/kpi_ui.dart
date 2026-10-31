import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.13b — KPI dashboard (kpi.dashboard {from,to}), all editions, online. Amounts are STORED units (shown via Fmt.money).
/// Profit card only when the server returns profit != null (gold + profit.view). Default period = last 30 days (server).

class KpiDashboardScreen extends StatefulWidget {
  const KpiDashboardScreen({super.key});

  @override
  State<KpiDashboardScreen> createState() => _KpiDashboardScreenState();
}

class _KpiDashboardScreenState extends State<KpiDashboardScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = false;
  String? _from;
  String? _to;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('kpi.dashboard', <String, dynamic>{if (_from != null) 'from': _from, if (_to != null) 'to': _to});
      if (!mounted) return;
      setState(() {
        _d = r;
        _from = '${r['from'] ?? _from}';
        _to = '${r['to'] ?? _to}';
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _pick(bool isFrom) async {
    final DateTime now = DateTime.now();
    final DateTime init = DateTime.tryParse((isFrom ? _from : _to) ?? '') ?? now;
    final DateTime? d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(now.year - 6), lastDate: now);
    if (d == null) return;
    _from ??= _iso(d);
    _to ??= _iso(d);
    if (isFrom) {
      _from = _iso(d);
    } else {
      _to = _iso(d);
    }
    await _load();
  }

  Map<String, dynamic> _m(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

  String _money(dynamic v) => v is num ? Fmt.money(v) : '—';

  String _kg(dynamic v) => v is num ? '${faNum(v, dec: 1)} کیلو' : '—';

  Widget _card(String title, IconData icon, List<Widget> kids, {Color? accent}) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[Icon(icon, size: 20, color: accent), const SizedBox(width: 8), Text(title, style: const TextStyle(fontWeight: FontWeight.bold))]),
            const Divider(height: 14),
            ...kids,
          ]),
        ),
      );

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: <Widget>[Expanded(child: Text(k, style: const TextStyle(fontSize: 13))), Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: color))]),
      );

  List<Widget> _dues(Map<String, dynamic> m) => <Widget>[
        _row('معوق', '${_money(m['overdue_sum'])} (${toFaDigits('${m['overdue_count'] ?? 0}')} مورد)', color: ((m['overdue_sum'] as num?) ?? 0) > 0 ? Colors.red : null),
        if (m['oldest_due'] != null) _row('قدیمی‌ترین سررسید', jalaliDate('${m['oldest_due']}')),
        _row('سررسید ۷ روز آینده', _money(m['due_7d_sum'])),
      ];

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _d;
    final Map<String, dynamic> s = _m(d?['sales']);
    final Map<String, dynamic> p = _m(d?['purchases']);
    final Map<String, dynamic> inv = _m(d?['inventory']);
    final num? chg = s['change_pct'] is num ? s['change_pct'] as num : null;
    final Map<String, dynamic>? profit = d?['profit'] is Map ? _m(d!['profit']) : null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('داشبورد KPI'), actions: <Widget>[IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            Row(children: <Widget>[
              Expanded(child: OutlinedButton.icon(onPressed: () => _pick(true), icon: const Icon(Icons.event), label: Text('از ${_from == null ? '…' : jalaliDate(_from!)}'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: () => _pick(false), icon: const Icon(Icons.event), label: Text('تا ${_to == null ? '…' : jalaliDate(_to!)}'))),
            ]),
            if (d != null) ...<Widget>[
              _card('فروش', Icons.point_of_sale, <Widget>[
                _row('درآمد (پس از برگشتی)', _money(s['revenue'])),
                _row('وزن', _kg(s['kg'])),
                _row('تعداد فاکتور', toFaDigits('${s['count'] ?? 0}')),
                if (chg != null) _row('تغییر نسبت به دورهٔ قبل', '${chg > 0 ? '+' : ''}${faNum(chg, dec: 1)}٪', color: chg >= 0 ? Colors.green : Colors.red) else _row('دورهٔ قبل', 'دادهٔ قابل مقایسه نیست'),
              ]),
              _card('خرید', Icons.shopping_cart_outlined, <Widget>[
                _row('جمع خرید', _money(p['total'])),
                _row('وزن', _kg(p['kg'])),
                _row('تعداد', toFaDigits('${p['count'] ?? 0}')),
              ]),
              _card('موجودی (برآورد)', Icons.warehouse_outlined, <Widget>[
                _row('وزن', _kg(inv['kg'])),
                _row('ارزش برآوردی', _money(inv['value_est'])),
                _row('تعداد لات', toFaDigits('${inv['lots'] ?? 0}')),
                const Text('وزن باقی‌مانده × قیمت خرید؛ هزینه‌های سرشکن‌شده را شامل نمی‌شود.', style: TextStyle(fontSize: 11, color: Colors.grey)),
              ]),
              _card('مطالبات', Icons.call_received, _dues(_m(d['receivables']))),
              _card('بدهی‌ها', Icons.call_made, _dues(_m(d['payables']))),
              if (profit != null)
                _card('سود ناخالص', Icons.trending_up, <Widget>[
                  _row('سود ناخالص', _money(profit['gross'])),
                  if (profit['margin_pct'] is num) _row('حاشیه سود', '${faNum(profit['margin_pct'] as num, dec: 1)}٪'),
                ], accent: Colors.green),
            ],
          ]),
        ),
      ),
    );
  }
}
