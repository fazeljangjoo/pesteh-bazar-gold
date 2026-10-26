import 'dart:io';

import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S18.T18.2 — trial balance (server action `reports.trial`, gold, perm accounting.view). Integer rial.
/// Levels: 1 گروه · 2 کل · 3 معین · tafsili. Columns: 2 (closing) · 4 (period + closing) · 6 (opening + period + closing).
/// A banner shows whether every shown column pair balances (Σdebit = Σcredit).

const Map<String, String> kTbLevels = <String, String>{'1': 'گروه', '2': 'کل', '3': 'معین', 'tafsili': 'تفصیلی'};
const Map<String, String> kTbStatuses = <String, String>{'posted': 'ثبت‌شده (موقت+قطعی)', 'final': 'فقط قطعی', 'all': 'همه (با پیش‌نویس)'};

String _m(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 0);
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Plain table form shared by screen, PDF and Excel.
class TrialTable {
  static List<String> headers(Map<String, dynamic> rep) {
    final int cols = (rep['columns'] as num?)?.toInt() ?? 6;
    final bool taf = rep['level'] == 'tafsili';
    return <String>[
      'کد',
      'نام',
      if (taf) 'تفصیلی',
      if (cols == 6) ...<String>['اول دوره بد', 'اول دوره بس'],
      if (cols >= 4) ...<String>['گردش بد', 'گردش بس'],
      'مانده بد',
      'مانده بس',
    ];
  }

  static List<String> _vals(Map<String, dynamic> r, int cols) => <String>[
        if (cols == 6) ...<String>[_m(r['open_debit']), _m(r['open_credit'])],
        if (cols >= 4) ...<String>[_m(r['period_debit']), _m(r['period_credit'])],
        _m(r['close_debit']),
        _m(r['close_credit']),
      ];

  static List<List<String>> rows(Map<String, dynamic> rep) {
    final int cols = (rep['columns'] as num?)?.toInt() ?? 6;
    final bool taf = rep['level'] == 'tafsili';
    final List<List<String>> out = <List<String>>[];
    for (final dynamic e in (rep['rows'] as List<dynamic>? ?? <dynamic>[])) {
      final Map<String, dynamic> r = Map<String, dynamic>.from(e as Map);
      out.add(<String>['${r['code']}', '${r['name']}', if (taf) '${r['tafsili_code'] ?? ''} ${r['tafsili_name'] ?? ''}'.trim(), ..._vals(r, cols)]);
    }
    final Map<String, dynamic> t = Map<String, dynamic>.from(rep['totals'] as Map? ?? <String, dynamic>{});
    out.add(<String>['', 'جمع', if (taf) '', ..._vals(t, cols)]);
    return out;
  }
}

class TrialBalanceScreen extends StatefulWidget {
  const TrialBalanceScreen({super.key});

  @override
  State<TrialBalanceScreen> createState() => _TrialBalanceScreenState();
}

class _TrialBalanceScreenState extends State<TrialBalanceScreen> {
  String _level = '2';
  int _cols = 6;
  String _status = 'posted';
  bool _hideZero = true;
  int? _fy;
  DateTime? _from;
  DateTime? _to;
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _rep;

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
        _years = <Map<String, dynamic>>[for (final dynamic e in (y['items'] as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];
        for (final Map<String, dynamic> f in _years) {
          if (f['is_current'] == true) _fy = (f['id'] as num).toInt();
        }
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    _load();
  }

  Map<String, dynamic> _params({bool csv = false}) {
    final Map<String, dynamic> p = <String, dynamic>{'level': _level, 'columns': _cols, 'status': _status, 'hide_zero': _hideZero ? 1 : 0};
    if (_fy != null) p['fiscal_year_id'] = _fy;
    if (_from != null) p['from'] = _iso(_from!);
    if (_to != null) p['to'] = _iso(_to!);
    if (csv) p['csv'] = 1;
    return p;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.trial', _params());
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

  Future<void> _pick(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  String get _subtitle => 'سطح ${kTbLevels[_level]} · ${_cols == 2 ? 'دو' : (_cols == 4 ? 'چهار' : 'شش')} ستونی · ${kTbStatuses[_status]}'
      '${_from == null && _to == null ? '' : ' · ${_from == null ? '-' : jalaliDateFromDt(_from!)} تا ${_to == null ? '-' : jalaliDateFromDt(_to!)}'}';

  Future<void> _pdf() async {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return;
    final File f = await PdfService.buildTableReport(title: 'تراز آزمایشی', subtitle: _subtitle, headers: TrialTable.headers(r), rows: TrialTable.rows(r), filePrefix: 'trial');
    if (!mounted) return;
    await PdfOutput.show(context, f);
  }

  Future<void> _excel() async {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return;
    final File f = await ExcelIo.exportTable(columns: TrialTable.headers(r), rows: TrialTable.rows(r), sheetName: 'تراز', filePrefix: 'trial');
    if (!mounted) return;
    await ExcelIo.saveOrShare(context, f);
  }

  Widget _banner() {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return const SizedBox.shrink();
    final bool ok = r['balanced'] == true;
    final Map<String, dynamic> c = Map<String, dynamic>.from(r['check'] as Map? ?? <String, dynamic>{});
    final String bad = <String>[
      if (c['opening'] == false && _cols == 6) 'اول دوره',
      if (c['period'] == false && _cols >= 4) 'گردش',
      if (c['closing'] == false) 'مانده',
    ].join('، ');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: ok ? Colors.green.shade50 : Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
      child: Text(ok ? 'تراز متعادل است (جمع بدهکار = جمع بستانکار)' : 'عدم تعادل در ستون: $bad', style: TextStyle(color: ok ? Colors.green.shade800 : Colors.red.shade800, fontWeight: FontWeight.bold)),
    );
  }

  Widget _grid() {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return const SizedBox.shrink();
    final List<List<String>> rows = TrialTable.rows(r);
    final List<String> h = TrialTable.headers(r);
    if (rows.length <= 1) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی یافت نشد')));
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 16,
          headingRowHeight: 40,
          dataRowMinHeight: 34,
          dataRowMaxHeight: 42,
          columns: <DataColumn>[for (final String x in h) DataColumn(label: Text(x, style: const TextStyle(fontWeight: FontWeight.bold)))],
          rows: <DataRow>[
            for (int i = 0; i < rows.length; i++)
              DataRow(cells: <DataCell>[for (final String c in rows[i]) DataCell(Text(c, style: TextStyle(fontWeight: i == rows.length - 1 ? FontWeight.bold : FontWeight.normal)))]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تراز آزمایشی'),
          actions: <Widget>[
            IconButton(tooltip: 'خروجی PDF', onPressed: _rep == null || _loading ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(tooltip: 'خروجی اکسل', onPressed: _rep == null || _loading ? null : _excel, icon: const Icon(Icons.table_chart_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
              DropdownButton<String>(
                value: _level,
                items: <DropdownMenuItem<String>>[for (final MapEntry<String, String> e in kTbLevels.entries) DropdownMenuItem<String>(value: e.key, child: Text('سطح ${e.value}'))],
                onChanged: (String? v) {
                  if (v == null) return;
                  setState(() => _level = v);
                  _load();
                },
              ),
              DropdownButton<int>(
                value: _cols,
                items: <DropdownMenuItem<int>>[for (final int c in <int>[2, 4, 6]) DropdownMenuItem<int>(value: c, child: Text('${toFaDigits('$c')} ستونی'))],
                onChanged: (int? v) {
                  if (v == null) return;
                  setState(() => _cols = v);
                  _load();
                },
              ),
              DropdownButton<int?>(
                value: _fy,
                hint: const Text('سال مالی'),
                items: <DropdownMenuItem<int?>>[
                  const DropdownMenuItem<int?>(value: null, child: Text('همه سال‌ها')),
                  for (final Map<String, dynamic> f in _years) DropdownMenuItem<int?>(value: (f['id'] as num).toInt(), child: Text('${f['name']}')),
                ],
                onChanged: (int? v) {
                  setState(() => _fy = v);
                  _load();
                },
              ),
              DropdownButton<String>(
                value: _status,
                items: <DropdownMenuItem<String>>[for (final MapEntry<String, String> e in kTbStatuses.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value))],
                onChanged: (String? v) {
                  if (v == null) return;
                  setState(() => _status = v);
                  _load();
                },
              ),
              OutlinedButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
              OutlinedButton(onPressed: () => _pick(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
              if (_from != null || _to != null)
                IconButton(
                  tooltip: 'حذف بازه',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    setState(() {
                      _from = null;
                      _to = null;
                    });
                    _load();
                  },
                ),
              FilterChip(
                label: const Text('پنهان‌کردن صفرها'),
                selected: _hideZero,
                onSelected: (bool v) {
                  setState(() => _hideZero = v);
                  _load();
                },
              ),
            ]),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          _banner(),
          Expanded(child: _grid()),
        ]),
      ),
    );
  }
}
