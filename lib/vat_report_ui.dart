import 'dart:io';

import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S17.T17.2b — VAT report screen (server actions `reports.vat` + `vat.settle`, gold only, perm `tax.view`).
/// All amounts come from the server in integer rial (DECISIONS §B / Q1) and are shown as rial.
/// `VatReportData.docsTable()/linesTable()/kv` are plain tables shared by screen, PDF and Excel.

const List<List<String>> kVatPeriods = <List<String>>[
  <String>['month', 'ماه'],
  <String>['quarter', 'فصل'],
  <String>['year', 'سال'],
  <String>['custom', 'بازهٔ دلخواه'],
];

const List<String> kVatMonths = <String>[
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند', //
];

const Map<String, String> kVatDocTypes = <String, String>{
  'sale': 'فروش',
  'sreturn': 'برگشت از فروش',
  'purchase': 'خرید',
  'preturn': 'برگشت از خرید',
};

const Map<String, String> kVatStatuses = <String, String>{
  'taxable': 'مشمول',
  'exempt': 'معاف',
  'zero': 'نرخ صفر',
  'unspecified': 'نامشخص',
};

double _d(dynamic v) => ReturnsHelp.d(v);
String _m(dynamic v) => faNum(_d(v), dec: 0);
String _jd(dynamic iso) => (iso == null || '$iso'.isEmpty) ? '-' : jalaliDate('$iso');
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Plain table form of a `reports.vat` response.
class VatReportData {
  VatReportData(this.raw);
  final Map<String, dynamic> raw;

  Map<String, dynamic> get _summary => Map<String, dynamic>.from(raw['summary'] as Map? ?? <String, dynamic>{});
  Map<String, dynamic> get _period => Map<String, dynamic>.from(raw['period'] as Map? ?? <String, dynamic>{});

  String get label => '${_period['label'] ?? ''}';
  String get subtitle => '${label.isEmpty ? '' : '$label · '}از ${_jd(_period['from'])} تا ${_jd(_period['to'])}${raw['status_filter'] == 'posted' ? ' · فقط اسناد نهایی/ثبت‌شده' : ''}';

  int get netPayable => _d(_summary['net_payable']).round();
  bool get checkOk => Map<String, dynamic>.from(raw['check'] as Map? ?? <String, dynamic>{})['ok'] == true;
  bool get linesTruncated => raw['lines_truncated'] == true;
  List<String> get warnings => ReturnsHelp.maps(raw['warnings']).map((Map<String, dynamic> w) => '${w['detail'] ?? w['code']}').toList();

  /// Key/value rows (3rd element 'b' = bold).
  List<List<String>> get kv {
    final Map<String, dynamic> s = _summary;
    final int net = netPayable;
    return <List<String>>[
      <String>['فروش مشمول مالیات (ریال)', _m(s['taxable_sales'])],
      <String>['فروش معاف (ریال)', _m(s['exempt_sales'])],
      <String>['فروش نرخ صفر (ریال)', _m(s['zero_rated_sales'])],
      <String>['فروش بدون وضعیت مالیاتی (ریال)', _m(s['unspecified_sales'])],
      <String>['مالیات فروش — ستانده (ریال)', _m(s['output_vat']), 'b'],
      <String>['خرید مشمول مالیات (ریال)', _m(s['taxable_purchases'])],
      <String>['خرید معاف (ریال)', _m(s['exempt_purchases'])],
      <String>['خرید نرخ صفر (ریال)', _m(s['zero_rated_purchases'])],
      <String>['خرید بدون وضعیت مالیاتی (ریال)', _m(s['unspecified_purchases'])],
      <String>['مالیات خرید — قابل اعتبار (ریال)', _m(s['input_vat']), 'b'],
      <String>[net >= 0 ? 'مالیات قابل پرداخت (ریال)' : 'مالیات قابل استرداد (ریال)', _m(net.abs()), 'b'],
      <String>['تسویه‌شده تاکنون: فروش / خرید (ریال)', '${_m(s['settled_output'])} / ${_m(s['settled_input'])}'],
    ];
  }

  (List<String>, List<List<String>>) docsTable() {
    return (
      <String>['تاریخ', 'نوع', 'طرف حساب', 'وضعیت مالیاتی', 'مبلغ پایه (ریال)', 'مالیات (ریال)'],
      ReturnsHelp.maps(raw['documents'])
          .map((Map<String, dynamic> r) => <String>[
                _jd(r['date']),
                kVatDocTypes['${r['type']}'] ?? '${r['type']}',
                '${r['party'] ?? '-'}',
                kVatStatuses['${r['status']}'] ?? '${r['status']}',
                _m(r['base']),
                _m(r['tax']),
              ])
          .toList(),
    );
  }

  (List<String>, List<List<String>>) linesTable() {
    return (
      <String>['تاریخ', 'شمارهٔ سند', 'سمت', 'منبع', 'شرح', 'مبلغ (ریال)'],
      ReturnsHelp.maps(raw['lines'])
          .map((Map<String, dynamic> r) => <String>[
                _jd(r['date']),
                r['number'] == null ? '-' : faNum(_d(r['number']), dec: 0),
                '${r['side']}' == 'output' ? 'ستانده (فروش)' : 'مالیات خرید',
                '${r['source_type'] ?? ''}',
                '${r['description'] ?? ''}',
                _m(r['amount']),
              ])
          .toList(),
    );
  }

  /// One flat sheet for Excel: summary, then documents, then VAT voucher lines.
  List<List<String>> excelRows() {
    final (List<String> dh, List<List<String>> dr) = docsTable();
    final (List<String> lh, List<List<String>> lr) = linesTable();
    return <List<String>>[
      for (final List<String> e in kv) <String>[e[0], e[1]],
      <String>[''],
      <String>['اسناد عملیاتی'],
      dh,
      ...dr,
      <String>[''],
      <String>['ردیف‌های مالیاتی اسناد حسابداری'],
      lh,
      ...lr,
    ];
  }
}

class VatReportScreen extends StatefulWidget {
  const VatReportScreen({super.key});
  @override
  State<VatReportScreen> createState() => _VatReportScreenState();
}

class _VatReportScreenState extends State<VatReportScreen> {
  String _period = 'month';
  late int _jy;
  late int _m;
  late int _q;
  DateTime? _from;
  DateTime? _to;
  bool _postedOnly = false;
  int _tab = 0; // 0 summary · 1 documents · 2 voucher lines
  bool _loading = false;
  String? _error;
  VatReportData? _data;

  @override
  void initState() {
    super.initState();
    final DateTime n = DateTime.now();
    final List<int> j = gregorianToJalali(n.year, n.month, n.day);
    _jy = j[0];
    _m = j[1];
    _q = ((j[1] - 1) ~/ 3) + 1;
    _load();
  }

  Map<String, dynamic>? _params() {
    final Map<String, dynamic> p = <String, dynamic>{'period': _period, 'jy': _jy, 'm': _m, 'q': _q};
    if (_period == 'custom') {
      if (_from == null || _to == null) return null;
      p['from'] = _iso(_from!);
      p['to'] = _iso(_to!);
    }
    if (_postedOnly) p['status'] = 'posted';
    return p;
  }

  Future<void> _load() async {
    final Map<String, dynamic>? p = _params();
    if (p == null) {
      setState(() {
        _data = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.vat', p);
      if (!mounted) return;
      setState(() {
        _data = VatReportData(r);
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _data = null;
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

  Future<void> _settle() async {
    final VatReportData? d = _data;
    final Map<String, dynamic>? p = _params();
    if (d == null || p == null) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('تسویه مالیات دوره'),
        content: Text('یک سند حسابداری موقت برای تهاتر مالیات فروش و خرید «${d.label}» ثبت (یا جایگزین) می‌شود. ادامه می‌دهید؟'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ثبت سند تسویه')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final Map<String, dynamic> r = await StockApi.call('vat.settle', p);
      if (!mounted) return;
      snack(context, 'سند تسویه ثبت شد — مبلغ ${faNum(_d(r['amount']), dec: 0)} ریال');
      _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  Future<void> _pdf() async {
    final VatReportData? d = _data;
    if (d == null) return;
    try {
      final (List<String> h, List<List<String>> r) = d.docsTable();
      final File file = await PdfService.buildTableReport(
          title: 'گزارش مالیات بر ارزش افزوده', subtitle: d.subtitle, kv: d.kv, headers: h, rows: r, filePrefix: 'vat_report');
      if (!mounted) return;
      await PdfOutput.show(context, file);
    } catch (e) {
      if (mounted) snack(context, 'ساخت PDF ناموفق بود: $e');
    }
  }

  Future<void> _excel() async {
    final VatReportData? d = _data;
    if (d == null) return;
    try {
      final File f = await ExcelIo.exportTable(
          columns: <String>['گزارش مالیات بر ارزش افزوده', d.label], rows: d.excelRows(), sheetName: 'VAT', filePrefix: 'vat_report');
      if (!mounted) return;
      await ExcelIo.saveOrShare(context, f);
    } catch (e) {
      if (mounted) snack(context, 'خروجی اکسل ناموفق بود: $e');
    }
  }

  Widget _periodBar() {
    final List<int> years = <int>[for (int y = _jy - 6; y <= _jy + 1; y++) y];
    final int curY = gregorianToJalali(DateTime.now().year, DateTime.now().month, DateTime.now().day)[0];
    if (!years.contains(curY)) years.add(curY);
    years.sort();
    return Column(children: <Widget>[
      SizedBox(
        height: 52,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: <Widget>[
          for (final List<String> k in kVatPeriods)
            Padding(
              padding: const EdgeInsets.all(5),
              child: ChoiceChip(
                  label: Text(k[1]),
                  selected: _period == k[0],
                  onSelected: (_) {
                    setState(() => _period = k[0]);
                    _load();
                  }),
            ),
          Padding(
            padding: const EdgeInsets.all(5),
            child: FilterChip(
                label: const Text('فقط نهایی'),
                selected: _postedOnly,
                onSelected: (bool v) {
                  setState(() => _postedOnly = v);
                  _load();
                }),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: _period == 'custom'
            ? Row(children: <Widget>[
                TextButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
                TextButton(onPressed: () => _pick(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
              ])
            : Row(children: <Widget>[
                DropdownButton<int>(
                  value: _jy,
                  items: <DropdownMenuItem<int>>[for (final int y in years) DropdownMenuItem<int>(value: y, child: Text(toFaDigits('$y')))],
                  onChanged: (int? v) {
                    if (v == null) return;
                    setState(() => _jy = v);
                    _load();
                  },
                ),
                const SizedBox(width: 16),
                if (_period == 'month')
                  DropdownButton<int>(
                    value: _m,
                    items: <DropdownMenuItem<int>>[for (int i = 1; i <= 12; i++) DropdownMenuItem<int>(value: i, child: Text(kVatMonths[i - 1]))],
                    onChanged: (int? v) {
                      if (v == null) return;
                      setState(() => _m = v);
                      _load();
                    },
                  ),
                if (_period == 'quarter')
                  DropdownButton<int>(
                    value: _q,
                    items: <DropdownMenuItem<int>>[for (int i = 1; i <= 4; i++) DropdownMenuItem<int>(value: i, child: Text('فصل ${toFaDigits('$i')}'))],
                    onChanged: (int? v) {
                      if (v == null) return;
                      setState(() => _q = v);
                      _load();
                    },
                  ),
              ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(label: Text(const <String>['خلاصه', 'اسناد', 'ردیف‌های مالیاتی'][i]), selected: _tab == i, onSelected: (_) => setState(() => _tab = i)),
            ),
        ]),
      ),
    ]);
  }

  Widget _grid((List<String>, List<List<String>>) t) {
    final List<String> headers = t.$1;
    final List<List<String>> rows = t.$2;
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

  Widget _summaryCard(VatReportData d) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(children: <Widget>[
          for (final List<String> e in d.kv)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: <Widget>[
                Flexible(child: Text(e[0])),
                Text(e[1], style: TextStyle(fontWeight: e.length > 2 ? FontWeight.bold : FontWeight.normal)),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final VatReportData? d = _data;
    final bool canSettle = StaffPerms.I.can('accounting.post');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('گزارش مالیات بر ارزش افزوده'),
          actions: <Widget>[
            IconButton(tooltip: 'خروجی PDF', onPressed: d == null || _loading ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(tooltip: 'خروجی اکسل', onPressed: d == null || _loading ? null : _excel, icon: const Icon(Icons.table_chart_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(children: <Widget>[
          _periodBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center)))
                    : d == null
                        ? const Center(child: Text('بازهٔ تاریخ را انتخاب کنید'))
                        : ListView(padding: const EdgeInsets.all(8), children: <Widget>[
                            Text(d.subtitle, style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 4),
                            if (!d.checkOk)
                              const Text('هشدار: مالیات اسناد با دفتر کل مطابقت ندارد', style: TextStyle(color: Colors.red)),
                            for (final String w in d.warnings) Text(w, style: const TextStyle(color: Colors.orange)),
                            const SizedBox(height: 6),
                            if (_tab == 0) ...<Widget>[
                              _summaryCard(d),
                              if (canSettle)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: FilledButton.icon(onPressed: _settle, icon: const Icon(Icons.balance), label: const Text('ثبت سند تسویه مالیات دوره')),
                                ),
                            ],
                            if (_tab == 1) _grid(d.docsTable()),
                            if (_tab == 2) ...<Widget>[
                              _grid(d.linesTable()),
                              if (d.linesTruncated)
                                const Padding(padding: EdgeInsets.only(top: 4), child: Text('تعداد ردیف‌ها زیاد است؛ فقط بخشی نمایش داده شد. بازه را محدودتر کنید.')),
                            ],
                          ]),
          ),
        ]),
      ),
    );
  }
}
