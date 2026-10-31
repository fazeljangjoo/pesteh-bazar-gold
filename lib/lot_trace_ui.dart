import 'package:flutter/material.dart';

import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S31.T31.7b — lot tracing (lot_trace.get) and orchard flow report (reports.orchard_flow). Online only, both tiers.
/// Revenue column only when the server returns can_profit (profit.view).

String _kg(dynamic v) => v is num ? faNum(v, dec: 1) : '—';

List<Map<String, dynamic>> _maps(dynamic v) {
  if (v is! List) return <Map<String, dynamic>>[];
  return <Map<String, dynamic>>[for (final dynamic e in v) if (e is Map) Map<String, dynamic>.from(e)];
}

String _via(dynamic v) => v == 'mix' ? 'مخلوط' : (v == 'separation' ? 'جداسازی' : '$v');

// ───────────────────────── Lot trace ─────────────────────────

class LotTraceScreen extends StatefulWidget {
  const LotTraceScreen({super.key});

  @override
  State<LotTraceScreen> createState() => _LotTraceScreenState();
}

class _LotTraceScreenState extends State<LotTraceScreen> {
  final TextEditingController _c = TextEditingController();
  Map<String, dynamic>? _r;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final String t = _c.text.trim();
    if (t.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final int? id = int.tryParse(t);
      final Map<String, dynamic> r = await StockApi.call('lot_trace.get', <String, dynamic>{if (id != null) 'lot_id': id else 'code': t});
      if (!mounted) return;
      setState(() {
        _r = r;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _r = null;
        _error = e.message;
        _loading = false;
      });
    }
  }

  Widget _origin(Map<String, dynamic> n) {
    final List<Map<String, dynamic>> o = _maps(n['origin']);
    if (o.isEmpty) return const SizedBox.shrink();
    return Text(
      'منشأ: ${o.map((Map<String, dynamic> e) => '${e['orchard'] ?? ''} ${toFaDigits('${e['season_year'] ?? ''}')} (${faNum(((e['fraction'] as num?) ?? 0) * 100, dec: 1)}٪)').join('، ')}',
      style: const TextStyle(fontSize: 12, color: Colors.green),
    );
  }

  Widget _node(Map<String, dynamic> n, {String? head}) {
    final List<Map<String, dynamic>> sales = _maps(n['sales']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          if (head != null) Text(head, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Text('${n['code'] ?? 'لات ${n['lot_id']}'} · ${n['type_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
          Text('تاریخ: ${toFaDigits('${n['date'] ?? ''}')} · وزن: ${_kg(n['kg'])} · مانده: ${_kg(n['remaining'])} · فروخته: ${_kg(n['sold_kg'])} کیلو', style: const TextStyle(fontSize: 12)),
          _origin(n),
          for (final Map<String, dynamic> s in sales)
            Text('  فروش ${toFaDigits('${s['sale_id']}')} · ${toFaDigits('${s['date'] ?? ''}')} · ${s['buyer'] ?? ''} · ${_kg(s['kg'])} کیلو', style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? r = _r;
    final List<Map<String, dynamic>> up = _maps(r?['upstream']);
    final List<Map<String, dynamic>> down = _maps(r?['downstream']);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('ردیابی لات')),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          TextField(
            controller: _c,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _go(),
            decoration: InputDecoration(labelText: 'کد یا شمارهٔ لات', border: const OutlineInputBorder(), suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _go)),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (r != null && r['lot'] is Map) ...<Widget>[
            const SizedBox(height: 8),
            _node(Map<String, dynamic>.from(r['lot'] as Map), head: 'لات انتخابی'),
            Text('جمع فروش این لات و فرزندانش: ${_kg(r['descendant_sold_kg_total'])} کیلو', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('بالادست (${toFaDigits('${up.length}')})', style: const TextStyle(fontWeight: FontWeight.bold)),
            if (up.isEmpty) const Text('منشأ ثبت نشده', style: TextStyle(fontSize: 12, color: Colors.grey)),
            for (final Map<String, dynamic> n in up) _node(n, head: 'سطح ${toFaDigits('${n['depth']}')} · ${_via(n['via'])} ${toFaDigits('${n['doc_id']}')} · ${_kg(n['kg'])} کیلو ← لات ${toFaDigits('${n['to_lot_id']}')}'),
            const SizedBox(height: 8),
            Text('پایین‌دست (${toFaDigits('${down.length}')})', style: const TextStyle(fontWeight: FontWeight.bold)),
            if (down.isEmpty) const Text('فرزندی ندارد', style: TextStyle(fontSize: 12, color: Colors.grey)),
            for (final Map<String, dynamic> n in down) _node(n, head: 'سطح ${toFaDigits('${n['depth']}')} · ${_via(n['via'])} ${toFaDigits('${n['doc_id']}')} ← از لات ${toFaDigits('${n['from_lot_id']}')}'),
            const Text('فرآوری و امانی ردیابی نمی‌شوند.', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ]),
      ),
    );
  }
}

// ───────────────────────── Orchard flow ─────────────────────────

class OrchardFlowScreen extends StatefulWidget {
  const OrchardFlowScreen({super.key});

  @override
  State<OrchardFlowScreen> createState() => _OrchardFlowScreenState();
}

class _OrchardFlowScreenState extends State<OrchardFlowScreen> {
  Map<String, dynamic>? _r;
  String? _error;
  bool _loading = false;
  final TextEditingController _season = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _season.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final int? sy = int.tryParse(_season.text.trim());
      final Map<String, dynamic> r = await StockApi.call('reports.orchard_flow', <String, dynamic>{if (sy != null) 'season_year': sy});
      if (!mounted) return;
      setState(() {
        _r = r;
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

  Widget _row(String k, String v, {Color? color}) => Row(children: <Widget>[Expanded(child: Text(k, style: const TextStyle(fontSize: 13))), Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: color))]);

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> items = _maps(_r?['items']);
    final bool canProfit = _r?['can_profit'] == true;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('جریان باغ تا فروش'), actions: <Widget>[IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          TextField(
            controller: _season,
            keyboardType: TextInputType.number,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(labelText: 'سال زراعی (اختیاری)', border: const OutlineInputBorder(), suffixIcon: IconButton(icon: const Icon(Icons.filter_alt_outlined), onPressed: _load)),
          ),
          if (_loading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (_r != null && items.isEmpty && !_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('برداشتی ثبت نشده است'))),
          for (final Map<String, dynamic> it in items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text('${it['orchard'] ?? ''} · ${toFaDigits('${it['season_year'] ?? ''}')}', style: const TextStyle(fontWeight: FontWeight.bold)),
                  const Divider(height: 14),
                  _row('برداشت', '${_kg(it['harvest_kg'])} کیلو'),
                  _row('رفته به جداسازی', '${_kg(it['to_separation_kg'])} کیلو'),
                  _row('ضایعات', '${_kg(it['waste_kg'])} کیلو${it['waste_pct_of_separated'] is num ? ' (${faNum(it['waste_pct_of_separated'] as num, dec: 1)}٪)' : ''}'),
                  if (it['abnormal_waste_kg'] is num && (it['abnormal_waste_kg'] as num) > 0) _row('ضایعات غیرعادی', '${_kg(it['abnormal_waste_kg'])} کیلو', color: Colors.orange),
                  _row('فروخته‌شده', '${_kg(it['sold_kg'])} کیلو'),
                  _row('مانده', '${_kg(it['remaining_kg'])} کیلو'),
                  if (it['unaccounted_kg'] is num && (it['unaccounted_kg'] as num).abs() > 0.5) _row('بی‌حساب', '${_kg(it['unaccounted_kg'])} کیلو', color: Colors.red),
                  if (it['net_yield_pct'] is num) _row('بازده خالص', '${faNum(it['net_yield_pct'] as num, dec: 1)}٪'),
                  if (canProfit && it['revenue'] is num) _row('درآمد فروش', faNum(it['revenue'] as num, dec: 0)),
                ]),
              ),
            ),
          if (_r != null && '${_r!['note'] ?? ''}'.isNotEmpty) Text('${_r!['note']}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ]),
      ),
    );
  }
}
