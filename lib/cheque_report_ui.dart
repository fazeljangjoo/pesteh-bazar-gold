import 'package:flutter/material.dart';

import 'cheque_ui.dart' show kChequeLabels;
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S06.T06.3 — cheque reports (server action `cheques.report`) + PDF. Online only (reports are computed from the server register).
/// `ChequeReportData.toTable()` returns plain headers/rows so the S13 Excel export can reuse it without touching this screen.
const List<List<String>> kChequeReportKinds = <List<String>>[
  <String>['due_week', 'سررسید هفتهٔ پیش‌رو'],
  <String>['due_month', 'سررسید ماه پیش‌رو'],
  <String>['in_bank', 'در جریان وصول'],
  <String>['bounced', 'برگشتی‌ها'],
  <String>['by_party', 'به تفکیک طرف حساب'],
  <String>['by_bank', 'به تفکیک بانک'],
  <String>['summary', 'خلاصهٔ دریافتی/پرداختی'],
];

double _d(dynamic v) => ReturnsHelp.d(v);
String _m(dynamic v) => faNum(_d(v), dec: 0);
String _dirLabel(dynamic d) => '$d' == 'received' ? 'دریافتی' : 'پرداختی';
String _jd(dynamic iso) => (iso == null || '$iso'.isEmpty) ? '-' : jalaliDate('$iso');
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Plain table form of a `cheques.report` response (shared by screen, PDF and the future Excel export).
class ChequeReportData {
  ChequeReportData(this.raw);
  final Map<String, dynamic> raw;

  String get kind => '${raw['kind']}';
  String get title => '${raw['title'] ?? ''}';

  String get subtitle {
    final List<String> p = <String>[];
    if (raw['from'] != null) p.add('از ${_jd(raw['from'])}');
    if (raw['to'] != null) p.add('تا ${_jd(raw['to'])}');
    if ('${raw['direction'] ?? ''}'.isNotEmpty) p.add(_dirLabel(raw['direction']));
    return p.join(' · ');
  }

  /// Key/value lines shown above the table. Totals are the server's `total` (= register sum, see register_total).
  List<List<String>> get kv {
    final List<List<String>> out = <List<String>>[
      <String>['تعداد چک', faNum(_d(raw['count']), dec: 0)],
      <String>['جمع مبلغ (ریال)', _m(raw['total']), 'b'],
    ];
    if (kind == 'summary') {
      final Map<String, dynamic> r = Map<String, dynamic>.from(raw['received'] as Map? ?? <String, dynamic>{});
      final Map<String, dynamic> i = Map<String, dynamic>.from(raw['issued'] as Map? ?? <String, dynamic>{});
      out.add(<String>['دریافتی باز (در انتظار نتیجه)', '${_m(r['open_amount'])} ریال — ${faNum(_d(r['open_count']), dec: 0)} چک']);
      out.add(<String>['پرداختی باز (در انتظار نتیجه)', '${_m(i['open_amount'])} ریال — ${faNum(_d(i['open_count']), dec: 0)} چک']);
      out.add(<String>['خالص باز (دریافتی منهای پرداختی)', '${_m(raw['net_open'])} ریال', 'b']);
    }
    return out;
  }

  bool get truncated => raw['truncated'] == true;

  /// True when the report total equals an independent SUM() over the same filter (Accept criterion).
  bool get matchesRegister => (_d(raw['total']) - _d(raw['register_total'])).abs() < 0.5 && _d(raw['count']) == _d(raw['register_count']);

  (List<String>, List<List<String>>) toTable() {
    if (kind == 'summary') {
      return (
        <String>['جهت', 'وضعیت', 'تعداد', 'مبلغ (ریال)'],
        ReturnsHelp.maps(raw['groups'])
            .map((Map<String, dynamic> g) => <String>[_dirLabel(g['direction']), kChequeLabels['${g['status']}'] ?? '${g['status']}', faNum(_d(g['count']), dec: 0), _m(g['amount'])])
            .toList(),
      );
    }
    if (kind == 'by_party' || kind == 'by_bank') {
      return (
        <String>[kind == 'by_party' ? 'طرف حساب' : 'بانک', 'دریافتی (تعداد)', 'دریافتی (مبلغ)', 'پرداختی (تعداد)', 'پرداختی (مبلغ)', 'باز', 'برگشتی'],
        ReturnsHelp.maps(raw['groups'])
            .map((Map<String, dynamic> g) => <String>[
                  '${g['name']}',
                  faNum(_d(g['received_count']), dec: 0),
                  _m(g['received_amount']),
                  faNum(_d(g['issued_count']), dec: 0),
                  _m(g['issued_amount']),
                  _m(g['open_amount']),
                  _m(g['bounced_amount']),
                ])
            .toList(),
      );
    }
    return (
      <String>['سررسید', 'جهت', 'شماره چک', 'بانک', 'طرف حساب', 'وضعیت', 'مبلغ (ریال)'],
      ReturnsHelp.maps(raw['items'])
          .map((Map<String, dynamic> c) => <String>[
                _jd(c['due_date']),
                _dirLabel(c['direction']),
                '${c['number'] ?? '-'}',
                '${c['bank'] ?? '-'}',
                '${c['party'] ?? '-'}',
                '${c['status_label'] ?? c['status']}',
                _m(c['amount']),
              ])
          .toList(),
    );
  }
}

class ChequeReportScreen extends StatefulWidget {
  const ChequeReportScreen({super.key, this.initialKind = 'due_week'});
  final String initialKind;
  @override
  State<ChequeReportScreen> createState() => _ChequeReportScreenState();
}

class _ChequeReportScreenState extends State<ChequeReportScreen> {
  late String _kind = widget.initialKind;
  String _dir = '';
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  String? _error;
  ChequeReportData? _data;

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
    final Map<String, dynamic> p = <String, dynamic>{'kind': _kind};
    if (_dir.isNotEmpty) p['direction'] = _dir;
    if (_from != null) p['from'] = _iso(_from!);
    if (_to != null) p['to'] = _iso(_to!);
    try {
      final Map<String, dynamic> r = await StockApi.call('cheques.report', p);
      if (!mounted) return;
      setState(() {
        _data = ChequeReportData(r);
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

  Future<void> _pick(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  Future<void> _pdf() async {
    final ChequeReportData? d = _data;
    if (d == null) return;
    try {
      final (List<String> headers, List<List<String>> rows) = d.toTable();
      final file = await PdfService.buildTableReport(
          title: d.title, subtitle: d.subtitle, kv: d.kv, headers: headers, rows: rows, filePrefix: 'cheque_${d.kind}');
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'ساخت PDF ناموفق بود: $e');
    }
  }

  Widget _table(ChequeReportData d) {
    final (List<String> headers, List<List<String>> rows) = d.toTable();
    if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی یافت نشد')));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 44,
        columns: <DataColumn>[for (final String h in headers) DataColumn(label: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)))],
        rows: <DataRow>[
          for (final List<String> r in rows) DataRow(cells: <DataCell>[for (final String c in r) DataCell(Text(c))]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ChequeReportData? d = _data;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('گزارش چک‌ها'),
          actions: <Widget>[
            IconButton(tooltip: 'خروجی PDF', onPressed: d == null || _loading ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(children: <Widget>[
          SizedBox(
            height: 52,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: <Widget>[
              for (final List<String> k in kChequeReportKinds)
                Padding(
                  padding: const EdgeInsets.all(5),
                  child: ChoiceChip(
                      label: Text(k[1]),
                      selected: _kind == k[0],
                      onSelected: (_) {
                        setState(() => _kind = k[0]);
                        _load();
                      }),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: <Widget>[
              for (final List<String> o in const <List<String>>[<String>['', 'همه'], <String>['received', 'دریافتی'], <String>['issued', 'پرداختی']])
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                      label: Text(o[1]),
                      selected: _dir == o[0],
                      onSelected: (_) {
                        setState(() => _dir = o[0]);
                        _load();
                      }),
                ),
              const Spacer(),
              TextButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
              TextButton(onPressed: () => _pick(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
              if (_from != null || _to != null)
                IconButton(
                    onPressed: () {
                      setState(() {
                        _from = null;
                        _to = null;
                      });
                      _load();
                    },
                    icon: const Icon(Icons.clear)),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center)))
                    : d == null
                        ? const SizedBox()
                        : ListView(padding: const EdgeInsets.all(8), children: <Widget>[
                            Text(d.title, style: Theme.of(context).textTheme.titleMedium),
                            if (d.subtitle.isNotEmpty) Text(d.subtitle),
                            const SizedBox(height: 6),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(children: <Widget>[
                                  for (final List<String> e in d.kv)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 2),
                                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
                                        Text(e[0]),
                                        Text(e[1], style: TextStyle(fontWeight: e.length > 2 ? FontWeight.bold : FontWeight.normal)),
                                      ]),
                                    ),
                                  if (!d.matchesRegister)
                                    const Padding(padding: EdgeInsets.only(top: 4), child: Text('هشدار: جمع گزارش با جمع دفتر چک‌ها مطابقت ندارد', style: TextStyle(color: Colors.red))),
                                  if (d.truncated)
                                    const Padding(padding: EdgeInsets.only(top: 4), child: Text('تعداد نتایج زیاد است؛ فقط ۵٬۰۰۰ چک نخست نمایش داده شد. بازه را محدودتر کنید.')),
                                ]),
                              ),
                            ),
                            const SizedBox(height: 6),
                            _table(d),
                          ]),
          ),
        ]),
      ),
    );
  }
}
