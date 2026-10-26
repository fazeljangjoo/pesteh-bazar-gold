import 'package:flutter/material.dart';

import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S18.T18.3b — gross margin by lot/type/ounce (`reports.margin`) + statement mapping editor (`statements.map` / `statements.map_save`).
/// Amounts are integer rial. Mapping prefixes = comma separated account codes (longest prefix wins); the accountant reviews them.

String _mm(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 0);
List<Map<String, dynamic>> _ml(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

class MarginScreen extends StatefulWidget {
  const MarginScreen({super.key});

  @override
  State<MarginScreen> createState() => _MarginScreenState();
}

class _MarginScreenState extends State<MarginScreen> {
  String _group = 'type';
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _rep;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.margin', <String, dynamic>{'group': _group});
      if (!mounted) return;
      setState(() {
        _rep = r;
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

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> rows = _ml(_rep?['rows']);
    final Map<String, dynamic> t = Map<String, dynamic>.from((_rep?['totals'] as Map?) ?? <String, dynamic>{});
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('حاشیه سود ناخالص', style: TextStyle(fontSize: 16)),
          actions: <Widget>[IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh))],
        ),
        body: Column(children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: <Widget>[
              for (final List<String> g in const <List<String>>[
                <String>['type', 'به تفکیک نوع'],
                <String>['ounce', 'به تفکیک اونس'],
                <String>['lot', 'به تفکیک لات'],
              ])
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(g[1]),
                    selected: _group == g[0],
                    onSelected: (_) {
                      setState(() => _group = g[0]);
                      _load();
                    },
                  ),
                ),
            ]),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (_rep != null) Padding(padding: const EdgeInsets.all(4), child: Text('${_rep!['fiscal_year']?['name'] ?? ''} · ${_rep!['from']} تا ${_rep!['to']} · ریال', style: const TextStyle(fontSize: 12))),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text(_loading ? '' : 'داده‌ای برای نمایش نیست'))
                : ListView(children: <Widget>[
                    for (final Map<String, dynamic> r in rows)
                      ListTile(
                        dense: true,
                        title: Text('${r['label']}'),
                        subtitle: Text('وزن ${faNum(((r['kg'] as num?) ?? 0).toDouble(), dec: 1)} کیلو · فروش ${_mm(r['revenue'])} · بهای تمام‌شده ${_mm(r['cogs'])}'
                            '${r['per_kg'] == null ? '' : ' · هر کیلو ${_mm(r['per_kg'])}'}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
                          Text(_mm(r['margin']), style: TextStyle(fontWeight: FontWeight.bold, color: ((r['margin'] as num?) ?? 0) < 0 ? Colors.red : null)),
                          Text(r['margin_pct'] == null ? '-' : '${faNum(((r['margin_pct'] as num)).toDouble(), dec: 1)}٪', style: const TextStyle(fontSize: 11)),
                        ]),
                      ),
                    if (rows.isNotEmpty)
                      ListTile(
                        tileColor: Colors.black12,
                        title: const Text('جمع', style: TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('فروش ${_mm(t['revenue'])} · بهای تمام‌شده ${_mm(t['cogs'])}'),
                        trailing: Text(_mm(t['margin']), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                  ]),
          ),
        ]),
      ),
    );
  }
}

class StatementMapScreen extends StatefulWidget {
  const StatementMapScreen({super.key});

  @override
  State<StatementMapScreen> createState() => _StatementMapScreenState();
}

class _StatementMapScreenState extends State<StatementMapScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  final Map<int, TextEditingController> _label = <int, TextEditingController>{};
  final Map<int, TextEditingController> _pref = <int, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _label.values) {
      c.dispose();
    }
    for (final TextEditingController c in _pref.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(List<Map<String, dynamic>> items) {
    _items = items;
    for (final Map<String, dynamic> r in items) {
      final int id = (r['id'] is num) ? (r['id'] as num).toInt() : (int.tryParse('${r['id']}') ?? 0);
      final TextEditingController lc = _label.putIfAbsent(id, () => TextEditingController());
      final TextEditingController pc = _pref.putIfAbsent(id, () => TextEditingController());
      lc.text = '${r['label'] ?? ''}';
      pc.text = '${r['prefixes'] ?? ''}';
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('statements.map');
      if (!mounted) return;
      setState(() {
        _fill(_ml(r['items']));
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

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final List<Map<String, dynamic>> lines = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> r in _items) {
      final int id = (r['id'] is num) ? (r['id'] as num).toInt() : (int.tryParse('${r['id']}') ?? 0);
      lines.add(<String, dynamic>{'id': id, 'label': _label[id]?.text ?? '', 'prefixes': _pref[id]?.text ?? ''});
    }
    try {
      final Map<String, dynamic> r = await StockApi.call('statements.map_save', <String, dynamic>{'lines': lines});
      if (!mounted) return;
      setState(() {
        _fill(_ml(r['items']));
        _saving = false;
      });
      snack(context, 'نگاشت ذخیره شد');
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    String last = '';
    final List<Widget> kids = <Widget>[];
    for (final Map<String, dynamic> r in _items) {
      final int id = (r['id'] is num) ? (r['id'] as num).toInt() : (int.tryParse('${r['id']}') ?? 0);
      final String st = '${r['statement']}';
      if (st != last) {
        last = st;
        kids.add(Padding(padding: const EdgeInsets.fromLTRB(12, 14, 12, 4), child: Text(st == 'is' ? 'صورت سود و زیان' : (st == 'bs' ? 'ترازنامه' : st), style: const TextStyle(fontWeight: FontWeight.bold))));
      }
      kids.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: <Widget>[
          Expanded(flex: 3, child: TextField(controller: _label[id], decoration: const InputDecoration(labelText: 'عنوان سطر', isDense: true))),
          const SizedBox(width: 8),
          Expanded(flex: 2, child: TextField(controller: _pref[id], keyboardType: TextInputType.text, decoration: const InputDecoration(labelText: 'پیشوند کدها (با ویرگول)', isDense: true))),
        ]),
      ));
    }
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('نگاشت حساب به سطرهای صورت‌ها', style: TextStyle(fontSize: 16)),
          actions: <Widget>[IconButton(tooltip: 'ذخیره', onPressed: _loading || _saving ? null : _save, icon: const Icon(Icons.save_outlined))],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(children: <Widget>[
                const Padding(padding: EdgeInsets.all(12), child: Text('هر حساب به سطری می‌رود که طولانی‌ترین پیشوند کدش با کد حساب بخواند؛ حساب‌های نگاشت‌نشده در «سایر» می‌آیند. حسابدار بازبینی کند.', style: TextStyle(fontSize: 12))),
                if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
                if (_saving) const LinearProgressIndicator(),
                ...kids,
                const SizedBox(height: 24),
              ]),
      ),
    );
  }
}
