import 'package:flutter/material.dart';

import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.4b — daily reconciliation dashboard (online only, gold). Server action: daily_recon.get {date?}.
/// Amounts are integer rial (ledger units), shown as-is.

class DailyReconScreen extends StatefulWidget {
  const DailyReconScreen({super.key});

  @override
  State<DailyReconScreen> createState() => _DailyReconScreenState();
}

class _DailyReconScreenState extends State<DailyReconScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = false;
  DateTime _date = DateTime.now();

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
      final Map<String, dynamic> r = await StockApi.call('daily_recon.get', <String, dynamic>{'date': _iso(_date)});
      if (!mounted) return;
      setState(() {
        _d = r;
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

  Future<void> _pickDate() async {
    final DateTime? p = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2015), lastDate: DateTime.now());
    if (p != null) {
      _date = p;
      await _load();
    }
  }

  List<Map<String, dynamic>> _rows(dynamic v) {
    if (v is! List) return <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[for (final dynamic e in v) if (e is Map) Map<String, dynamic>.from(e)];
  }

  Color _lc(String? level) => level == 'error' ? Colors.red : (level == 'warning' ? Colors.orange : Colors.green);

  String _m(dynamic v) => v is num ? faNum(v, dec: 0) : '—';

  String _roleName(String r) {
    switch (r) {
      case 'cheque_in_hand':
        return 'چک‌های دریافتی در دست';
      case 'cheque_collect':
        return 'چک‌های در جریان وصول';
      case 'cheque_payable':
        return 'چک‌های پرداختنی';
    }
    return r;
  }

  Widget _card(String title, IconData icon, List<Widget> kids, {String? level}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Icon(icon, size: 20, color: level == null ? null : _lc(level)),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const Divider(height: 16),
          ...kids,
        ]),
      ),
    );
  }

  Widget _line(String name, dynamic book, {dynamic other, dynamic diff, String? level, String? note, String? extra}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(name)),
          Text(_m(book), style: TextStyle(fontWeight: FontWeight.w600, color: level == null ? null : _lc(level))),
        ]),
        if (other != null) Text('مقایسه: ${_m(other)}  ·  اختلاف: ${_m(diff)}', style: const TextStyle(fontSize: 12)),
        if (extra != null && extra.isNotEmpty) Text(extra, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (note != null && note.isNotEmpty) Text(note, style: TextStyle(fontSize: 12, color: _lc(level ?? 'warning'))),
      ]),
    );
  }

  List<Widget> _treasury(dynamic sec) {
    final List<Map<String, dynamic>> rows = _rows(sec);
    if (rows.isEmpty) return <Widget>[const Text('موردی نیست', style: TextStyle(fontSize: 12, color: Colors.grey))];
    return <Widget>[
      for (final Map<String, dynamic> r in rows)
        _line('${r['name'] ?? ''}', r['book'],
            other: r['other'], diff: r['diff'], level: r['level'] as String?, note: r['note'] as String?,
            extra: 'گردش روز: بدهکار ${_m(r['day_debit'])} · بستانکار ${_m(r['day_credit'])}'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _d;
    final List<Map<String, dynamic>> alerts = _rows(d?['alerts']);
    final Map<String, dynamic> parties = d?['parties'] is Map ? Map<String, dynamic>.from(d!['parties'] as Map) : <String, dynamic>{};
    final Map<String, dynamic> inv = d?['inventory'] is Map ? Map<String, dynamic>.from(d!['inventory'] as Map) : <String, dynamic>{};
    final Map<String, dynamic> integ = d?['integrity'] is Map ? Map<String, dynamic>.from(d!['integrity'] as Map) : <String, dynamic>{};
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('داشبورد تطبیق روزانه'), actions: <Widget>[
          IconButton(icon: const Icon(Icons.event), tooltip: 'تاریخ', onPressed: _pickDate),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'بازخوانی', onPressed: _load),
        ]),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
            Text('تاریخ: ${toFaDigits(_iso(_date))}', style: const TextStyle(fontSize: 12)),
            if (d != null && '${d['as_of_now_note'] ?? ''}'.isNotEmpty) Text('${d['as_of_now_note']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (d != null)
              _card(alerts.isEmpty ? 'هشدارها: بدون هشدار' : 'هشدارها (${toFaDigits('${alerts.length}')})', alerts.isEmpty ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                  alerts.isEmpty
                      ? <Widget>[const Text('همه چیز با هم می‌خواند', style: TextStyle(fontSize: 12))]
                      : <Widget>[
                          for (final Map<String, dynamic> a in alerts)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text('• ${a['title'] ?? ''}${'${a['detail'] ?? ''}'.isEmpty ? '' : ' — ${a['detail']}'}${(a['diff'] is num && a['diff'] != 0) ? ' (اختلاف ${_m(a['diff'])})' : ''}',
                                  style: const TextStyle(fontSize: 13)),
                            ),
                        ],
                  level: alerts.isEmpty ? 'ok' : 'warning'),
            if (d != null) _card('صندوق‌ها', Icons.payments_outlined, _treasury(d['cash'])),
            if (d != null) _card('بانک‌ها', Icons.account_balance_outlined, _treasury(d['bank'])),
            if (d != null)
              _card('طرف‌حساب‌ها', Icons.people_outline, <Widget>[
                if (parties['error'] != null)
                  Text('${parties['error']}', style: const TextStyle(color: Colors.red))
                else ...<Widget>[
                  Text('بررسی‌شده: ${toFaDigits('${parties['checked'] ?? 0}')} · مغایر: ${toFaDigits('${parties['mismatched'] ?? 0}')}'),
                  for (final Map<String, dynamic> r in _rows(parties['rows'])) _line('${r['party'] ?? ''}', r['book'], other: r['other'], diff: r['diff'], level: 'warning'),
                ],
              ], level: (parties['mismatched'] ?? 0) == 0 ? 'ok' : 'warning'),
            if (d != null)
              _card('موجودی انبار', Icons.warehouse_outlined, <Widget>[
                if (inv['error'] != null) Text('${inv['error']}', style: const TextStyle(color: Colors.red)) else _line('دفتر در برابر ارزش لات‌ها', inv['book'], other: inv['other'], diff: inv['diff'], level: inv['level'] as String?),
              ], level: inv['level'] as String?),
            if (d != null)
              _card('چک‌ها', Icons.receipt_long_outlined, <Widget>[
                if (d['cheques'] is Map) Text('${(d['cheques'] as Map)['error'] ?? ''}', style: const TextStyle(color: Colors.red)) else for (final Map<String, dynamic> r in _rows(d['cheques'])) _line(_roleName('${r['role'] ?? ''}'), r['book'], other: r['other'], diff: r['diff'], level: r['level'] as String?),
              ]),
            if (d != null)
              _card('یکپارچگی حسابداری', Icons.verified_outlined, <Widget>[
                if (integ['error'] != null)
                  Text('${integ['error']}', style: const TextStyle(color: Colors.red))
                else ...<Widget>[
                  Text('خطا: ${toFaDigits('${integ['errors'] ?? 0}')} · هشدار: ${toFaDigits('${integ['warnings'] ?? 0}')}'),
                  for (final Map<String, dynamic> i in _rows(integ['issues'])) Text('• ${i['message'] ?? i['title'] ?? i['code'] ?? ''}', style: const TextStyle(fontSize: 12)),
                ],
              ], level: (integ['errors'] ?? 0) == 0 ? ((integ['warnings'] ?? 0) == 0 ? 'ok' : 'warning') : 'error'),
          ]),
        ),
      ),
    );
  }
}
