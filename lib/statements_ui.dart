import 'dart:io';

import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'edition.dart';
import 'margin_ui.dart';
import 'excel_io.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S18.T18.3 — income statement, balance sheet, cost-center P&L (server `reports.income|balance|cc_pnl`, gold, perm accounting.view)
/// + `InstantPnlCard` for the home screen (`reports.instant`, current fiscal year, loads on open / pull via refresh button).
/// Amounts are integer rial. Account→line mapping lives on the server (`statements.map`), the accountant reviews it.
/// Gross margin + mapping editor: margin_ui.dart (T18.3b), opened from the AppBar here.

String _m(dynamic v) => Fmt.money(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), label: false);
int _i(dynamic v) => (v is num) ? v.toInt() : (int.tryParse('${v ?? 0}') ?? 0);
List<Map<String, dynamic>> _list(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

/// Plain tables shared by screen, PDF and Excel.
class StatementTables {
  static List<List<String>> income(Map<String, dynamic> r) {
    final List<List<String>> rows = <List<String>>[];
    void sect(String title, String kind, String section) {
      for (final Map<String, dynamic> l in _list(r['lines'])) {
        if (l['kind'] == kind && l['section'] == section && (_i(l['amount']) != 0 || l['synthetic'] != true)) rows.add(<String>[l['label'] as String, _m(l['amount'])]);
      }
    }

    sect('', 'revenue', 'gross');
    sect('', 'expense', 'gross');
    rows.add(<String>['سود (زیان) ناخالص', _m(r['gross_profit'])]);
    sect('', 'expense', 'op');
    rows.add(<String>['سود (زیان) عملیاتی', _m(r['operating_profit'])]);
    sect('', 'revenue', 'other');
    sect('', 'expense', 'other');
    rows.add(<String>['سود (زیان) خالص', _m(r['net_profit'])]);
    return rows;
  }

  static List<List<String>> balance(Map<String, dynamic> r) {
    final List<List<String>> rows = <List<String>>[];
    final Map<String, dynamic> t = Map<String, dynamic>.from(r['totals'] as Map? ?? <String, dynamic>{});
    void part(String kind, String title, String totalKey) {
      rows.add(<String>[title, '']);
      for (final Map<String, dynamic> l in _list(r['lines'])) {
        if (l['kind'] == kind && (_i(l['amount']) != 0 || l['synthetic'] != true)) rows.add(<String>['   ${l['label']}', _m(l['amount'])]);
      }
      if (kind == 'equity') {
        rows.add(<String>['   سود (زیان) سال‌های قبل', _m(t['prior_years_result'])]);
        rows.add(<String>['   سود (زیان) سال جاری', _m(t['current_year_result'])]);
      }
      rows.add(<String>['جمع $title', _m(t[totalKey])]);
    }

    part('asset', 'دارایی‌ها', 'assets');
    part('liability', 'بدهی‌ها', 'liabilities');
    part('equity', 'حقوق صاحبان سرمایه', 'equity');
    rows.add(<String>['جمع بدهی‌ها و حقوق صاحبان سرمایه (با نتیجهٔ سال‌ها)', _m(t['liab_equity_result'])]);
    return rows;
  }

  static List<List<String>> cc(Map<String, dynamic> r) {
    final List<List<String>> rows = <List<String>>[
      for (final Map<String, dynamic> x in _list(r['rows'])) <String>['${x['name']}', _m(x['revenue']), _m(x['expense']), _m(x['net'])],
    ];
    final Map<String, dynamic> t = Map<String, dynamic>.from(r['totals'] as Map? ?? <String, dynamic>{});
    rows.add(<String>['جمع', _m(t['revenue']), _m(t['expense']), _m(t['net'])]);
    return rows;
  }
}

class StatementsScreen extends StatefulWidget {
  const StatementsScreen({super.key});

  @override
  State<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends State<StatementsScreen> {
  int _tab = 0; // 0 income · 1 balance · 2 cost centers
  String _status = 'posted';
  int? _fy;
  DateTime? _from;
  DateTime? _to;
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _rep;

  static const List<String> _actions = <String>['reports.income', 'reports.balance', 'reports.cc_pnl'];
  static const List<String> _titles = <String>['صورت سود و زیان', 'ترازنامه', 'سود و زیان مراکز هزینه'];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final Map<String, dynamic> y = await StockApi.call('fiscal_years.list');
      if (!mounted) return;
      setState(() {
        _years = _list(y['items']);
        for (final Map<String, dynamic> f in _years) {
          if (f['is_current'] == true) _fy = _i(f['id']);
        }
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    _load();
  }

  String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final Map<String, dynamic> p = <String, dynamic>{'status': _status};
    if (_fy != null) p['fiscal_year_id'] = _fy;
    if (_tab != 1 && _from != null) p['from'] = _iso(_from!);
    if (_to != null) p['to'] = _iso(_to!);
    try {
      final Map<String, dynamic> r = await StockApi.call(_actions[_tab], p);
      if (!mounted) return;
      setState(() {
        _rep = r;
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _rep = null;
        _loading = false;
      });
    }
  }

  List<String> get _headers => _tab == 2 ? <String>['مرکز هزینه', 'درآمد', 'هزینه', 'خالص'] : <String>['سرفصل', 'مبلغ (${Fmt.unitLabel()})'];

  List<List<String>> get _rows {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return <List<String>>[];
    return _tab == 0 ? StatementTables.income(r) : (_tab == 1 ? StatementTables.balance(r) : StatementTables.cc(r));
  }

  String get _sub {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return '';
    final String fy = '${(r['fiscal_year'] as Map?)?['name'] ?? ''}';
    return _tab == 1 ? '$fy · تا تاریخ ${jalaliDate('${r['as_of']}')}' : '$fy · از ${jalaliDate('${r['from']}')} تا ${jalaliDate('${r['to']}')}';
  }

  Future<void> _pdf() async {
    final File f = await PdfService.buildTableReport(title: _titles[_tab], subtitle: _sub, headers: _headers, rows: _rows, filePrefix: 'statement');
    if (!mounted) return;
    await PdfOutput.show(context, f);
  }

  Future<void> _excel() async {
    final File f = await ExcelIo.exportTable(columns: _headers, rows: _rows, sheetName: _titles[_tab], filePrefix: 'statement');
    if (!mounted) return;
    await ExcelIo.saveOrShare(context, f);
  }

  Future<void> _pick(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  Widget _banner() {
    final Map<String, dynamic>? r = _rep;
    if (_tab != 1 || r == null) return const SizedBox.shrink();
    final bool ok = (r['check'] as Map?)?['balanced'] == true;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: ok ? Colors.green.shade50 : Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
      child: Text(ok ? 'ترازنامه متعادل است' : 'ترازنامه متعادل نیست؛ «کنترل صحت حسابداری» را اجرا کنید', style: TextStyle(color: ok ? Colors.green.shade800 : Colors.red.shade800, fontWeight: FontWeight.bold)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<List<String>> rows = _rows;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_titles[_tab], style: const TextStyle(fontSize: 16)),
          actions: <Widget>[
            IconButton(tooltip: 'حاشیه سود (لات/نوع/اونس)', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MarginScreen())), icon: const Icon(Icons.pie_chart_outline)),
            if (StaffPerms.I.can('settings.manage')) IconButton(tooltip: 'نگاشت حساب‌ها به سطرها', onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StatementMapScreen())), icon: const Icon(Icons.tune)),
            IconButton(tooltip: 'خروجی PDF', onPressed: _rep == null || _loading ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(tooltip: 'خروجی اکسل', onPressed: _rep == null || _loading ? null : _excel, icon: const Icon(Icons.table_chart_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: <Widget>[
              for (int i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(const <String>['سود و زیان', 'ترازنامه', 'مراکز هزینه'][i]),
                    selected: _tab == i,
                    onSelected: (_) {
                      setState(() {
                        _tab = i;
                        _rep = null;
                      });
                      _load();
                    },
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
              DropdownButton<int?>(
                value: _fy,
                hint: const Text('سال مالی'),
                items: <DropdownMenuItem<int?>>[for (final Map<String, dynamic> f in _years) DropdownMenuItem<int?>(value: _i(f['id']), child: Text('${f['name']}'))],
                onChanged: (int? v) {
                  setState(() => _fy = v);
                  _load();
                },
              ),
              DropdownButton<String>(
                value: _status,
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'posted', child: Text('ثبت‌شده')),
                  DropdownMenuItem<String>(value: 'final', child: Text('فقط قطعی')),
                  DropdownMenuItem<String>(value: 'all', child: Text('همه')),
                ],
                onChanged: (String? v) {
                  if (v == null) return;
                  setState(() => _status = v);
                  _load();
                },
              ),
              if (_tab != 1) OutlinedButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
              OutlinedButton(onPressed: () => _pick(false), child: Text(_to == null ? (_tab == 1 ? 'تا تاریخ (پایان سال)' : 'تا تاریخ') : jalaliDateFromDt(_to!))),
            ]),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (_sub.isNotEmpty) Padding(padding: const EdgeInsets.all(4), child: Text(_sub, style: const TextStyle(fontSize: 12))),
          _banner(),
          Expanded(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: rows.isEmpty
                    ? const Padding(padding: EdgeInsets.all(24), child: Text('موردی یافت نشد'))
                    : DataTable(
                        columnSpacing: 24,
                        columns: <DataColumn>[for (final String h in _headers) DataColumn(label: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)))],
                        rows: <DataRow>[
                          for (final List<String> r in rows)
                            DataRow(cells: <DataCell>[for (final String c in r) DataCell(Text(c, style: TextStyle(fontWeight: (r[0].startsWith('   ') || (_tab == 2 && r != rows.last)) ? FontWeight.normal : FontWeight.bold)))]),
                        ],
                      ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Home-screen card (gold + perm accounting.view). Opens StatementsScreen on tap.
class InstantPnlCard extends StatefulWidget {
  const InstantPnlCard({super.key});

  @override
  State<InstantPnlCard> createState() => _InstantPnlCardState();
}

class _InstantPnlCardState extends State<InstantPnlCard> {
  Map<String, dynamic>? _d;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.instant');
      if (!mounted) return;
      setState(() {
        _d = r;
        _err = null;
        _busy = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!StaffPerms.I.can('accounting.view')) return const SizedBox.shrink();
    return FeatureGate(
      feature: 'gold.vouchers',
      child: Card(
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const StatementsScreen())),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Row(children: <Widget>[
                const Expanded(child: Text('سود و زیان لحظه‌ای (سال مالی جاری)', style: TextStyle(fontWeight: FontWeight.bold))),
                IconButton(tooltip: 'تازه‌سازی', onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh, size: 20)),
              ]),
              if (_err != null) Text(_err!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              if (_d == null && _err == null) const LinearProgressIndicator(),
              if (_d != null) ...<Widget>[
                Text('درآمد: ${_m(_d!['revenue'])}   هزینه: ${_m(_d!['expense'])}'),
                Text('سود ناخالص: ${_m(_d!['gross_profit'])}'),
                Text('${_i(_d!['net_profit']) >= 0 ? 'سود' : 'زیان'} خالص: ${_m(_i(_d!['net_profit']).abs())} ${Fmt.unitLabel()}', style: TextStyle(fontWeight: FontWeight.bold, color: _i(_d!['net_profit']) >= 0 ? Colors.green.shade800 : Colors.red.shade800)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
