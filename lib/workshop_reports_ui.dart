import 'dart:io';

import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'pdf_output.dart' show PdfOutput;
import 'pdf_service.dart' show PdfService;
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart' show JalaliDateField;
import 'workshop_calc.dart';
import 'workshop_ui.dart' show wsCanCost;

/// v81 — گزارش‌های چاپی کارگاه داخلی (فایل مشترک اندروید و ویندوز).
///   [CrackLineReportScreen]  گزارش خطوط شکست: گرم پرتی واقعی هر خط/عملیات در برابر گرم پرتی اعلامی خط (workshop.crack_report).
///   [wsPrintOp]              چاپ برگهٔ یک عملیات کارگاه (سربرگ، ورودی‌ها، خروجی‌ها، تراز و اطلاعات خروجی).
///   [wsPrintOpsList]         چاپ فهرست عملیات کارگاه.

String _kg(dynamic v) => faNum(ReturnsHelp.d(v), dec: 3);
String _g2(dynamic v) => v == null ? '—' : faNum(ReturnsHelp.d(v), dec: 2);
String _signed(dynamic v) {
  if (v == null) return '—';
  final double d = ReturnsHelp.d(v);
  if (d.abs() < 0.005) return '۰';
  return '${d > 0 ? '+' : '−'}${faNum(d.abs(), dec: 2)}';
}

class CrackLineReportScreen extends StatefulWidget {
  const CrackLineReportScreen({super.key});

  @override
  State<CrackLineReportScreen> createState() => _CrackLineReportScreenState();
}

class _CrackLineReportScreenState extends State<CrackLineReportScreen> {
  DateTime _from = DateTime.now().subtract(const Duration(days: 365));
  DateTime _to = DateTime.now();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _lines = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('workshop.crack_report', <String, dynamic>{'from': ReturnsHelp.iso(_from), 'to': ReturnsHelp.iso(_to)});
      if (!mounted) return;
      setState(() {
        _lines = ReturnsHelp.maps(r['lines']);
        _items = ReturnsHelp.maps(r['items']);
        _error = null;
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

  String get _range => 'از ${jalaliDateFromDt(_from)} تا ${jalaliDateFromDt(_to)}';

  static const List<String> _lineHeads = <String>['خط شکست', 'تعداد', 'ورودی (کیلو)', 'مغز (کیلو)', 'گرم اولیه', 'گرم دریافتی', 'افت گرم واقعی', 'گرم پرتی اعلامی', 'اختلاف', 'وزن پرتی (کیلو)', 'ضایعات (کیلو)'];

  List<String> _lineRow(Map<String, dynamic> l) => <String>[
        '${l['line_name'] ?? '—'}', faNum(ReturnsHelp.d(l['ops']), dec: 0), _kg(l['input_kg']), _kg(l['kernel_kg']), _g2(l['init_gram']), _g2(l['recv_gram']),
        _g2(l['loss_gram']), _g2(l['declared_loss']), _signed(l['gram_vs_line']), l['loss_kg'] == null ? '—' : _kg(l['loss_kg']), _kg(l['waste_kg']),
      ];

  List<String> get _opHeads => <String>[
        'تاریخ', 'خط', 'نوع پسته', 'ورودی', 'مغز', 'پوست', 'نشکن', 'ضایعات', 'گرم اولیه', 'گرم دریافتی', 'افت گرم', 'اعلامی', 'اختلاف', 'وزن پرتی',
        if (wsCanCost()) 'بهای هر کیلو مغز',
      ];

  List<String> _opRow(Map<String, dynamic> r) => <String>[
        jalaliDate('${r['date'] ?? ''}'), '${r['line_name'] ?? '—'}', '${r['pistachio_type'] ?? ''}', _kg(r['input_kg']), _kg(r['kernel_kg']), _kg(r['hull_kg']),
        _kg(r['uncracked_kg']), r['waste_kg'] == null ? '—' : _kg(r['waste_kg']), _g2(r['init_gram']), _g2(r['recv_gram']), _g2(r['loss_gram']),
        _g2(r['declared_loss']), _signed(r['gram_vs_line']), r['loss_kg'] == null ? '—' : _kg(r['loss_kg']),
        if (wsCanCost()) r['kernel_cost_per_kg'] == null ? '—' : Fmt.money(ReturnsHelp.d(r['kernel_cost_per_kg']), label: false),
      ];

  Future<void> _print() async {
    final File file = await PdfService.buildTableReport(
      title: 'گزارش خطوط شکست — گرم پرتی واقعی در برابر اعلامی',
      subtitle: _range,
      kv: <List<String>>[
        for (final Map<String, dynamic> l in _lines)
          <String>[
            '${l['line_name'] ?? '—'} (${faNum(ReturnsHelp.d(l['ops']), dec: 0)} عملیات، ${_kg(l['input_kg'])} کیلو)',
            'افت واقعی ${_g2(l['loss_gram'])} • اعلامی ${_g2(l['declared_loss'])} • اختلاف ${_signed(l['gram_vs_line'])} • وزن پرتی ${l['loss_kg'] == null ? '—' : _kg(l['loss_kg'])} کیلو',
            'b',
          ],
      ],
      headers: _opHeads,
      rows: <List<String>>[for (final Map<String, dynamic> r in _items) _opRow(r)],
      filePrefix: 'crack_lines_report',
      pageNumbers: true,
      footnote: 'افت گرم = گرم اولیه − گرم دریافتی (گرم دریافتی = مغز × ۱۰۰ ÷ وزن شکسته‌شده = ورودی − نشکن). اختلاف مثبت = پرتی واقعی بیشتر از اعلامی خط. '
          'میانگین‌های هر خط موزون به وزن شکسته‌شده‌اند. ضایعات = ورودی − جمع خروجی‌ها.',
    );
    if (!mounted) return;
    await PdfOutput.show(context, file);
  }

  @override
  Widget build(BuildContext context) {
    DataCell cell(String s, {Color? color, bool bold = false}) => DataCell(Text(s, style: TextStyle(color: color, fontWeight: bold ? FontWeight.bold : null)));
    Color? tone(dynamic v) => v == null ? null : (ReturnsHelp.d(v) > 0.005 ? Colors.red : (ReturnsHelp.d(v) < -0.005 ? Colors.green : null));
    return Scaffold(
      appBar: AppBar(
        title: const Text('گزارش خطوط شکست'),
        actions: <Widget>[
          IconButton(tooltip: 'چاپ / PDF', icon: const Icon(Icons.print_outlined), onPressed: _loading || (_items.isEmpty && _lines.isEmpty) ? null : _print),
          IconButton(tooltip: 'به‌روزرسانی', icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
            SizedBox(width: 200, child: JalaliDateField(label: 'از تاریخ', value: _from, onChanged: (DateTime d) => setState(() => _from = d))),
            SizedBox(width: 200, child: JalaliDateField(label: 'تا تاریخ', value: _to, onChanged: (DateTime d) => setState(() => _to = d))),
            FilledButton(onPressed: _load, child: const Text('اعمال')),
          ]),
          const SizedBox(height: 8),
          const Text('فقط عملیات «شکست» بسته‌شده. افت گرم واقعی هر خط با گرم پرتی اعلامی همان خط مقایسه می‌شود (اختلاف مثبت = پرتی بیشتر از اعلامی).'),
          if (_error != null)
            Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(10), child: Text(_error!))),
          if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _error == null && _lines.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('عملیات شکست بسته‌شده‌ای در این بازه نیست'))),
          if (_lines.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text('جمع هر خط', style: Theme.of(context).textTheme.titleMedium),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: <DataColumn>[for (final String h in _lineHeads) DataColumn(label: Text(h))],
                rows: <DataRow>[
                  for (final Map<String, dynamic> l in _lines)
                    DataRow(cells: <DataCell>[
                      for (int i = 0; i < _lineHeads.length; i++)
                        cell(_lineRow(l)[i], color: i == 8 ? tone(l['gram_vs_line']) : null, bold: i == 8),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text('عملیات‌ها', style: Theme.of(context).textTheme.titleMedium),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: <DataColumn>[for (final String h in _opHeads) DataColumn(label: Text(h))],
                rows: <DataRow>[
                  for (final Map<String, dynamic> r in _items)
                    DataRow(cells: <DataCell>[
                      for (int i = 0; i < _opHeads.length; i++) cell(_opRow(r)[i], color: i == 12 ? tone(r['gram_vs_line']) : null, bold: i == 12),
                    ]),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// برگهٔ چاپی یک عملیات کارگاه. [titleOf] عنوان هر ردیف خروجی (دسته/نوع).
Future<void> wsPrintOp(BuildContext context, Map<String, dynamic> d, {required String title, required String Function(Map<String, dynamic>) titleOf, List<List<String>> extra = const <List<String>>[]}) async {
  final List<Map<String, dynamic>> ins = ReturnsHelp.maps(d['inputs']);
  final List<Map<String, dynamic>> outs = ReturnsHelp.maps(d['outputs']);
  final WsBalance t = wsFlowTotals(d);
  final bool cost = wsCanCost();
  final File file = await PdfService.buildTableReport(
    title: 'برگهٔ عملیات کارگاه — $title',
    subtitle: 'شروع ${jalaliDate('${d['started_at'] ?? d['date'] ?? ''}')}${d['closed_at'] == null ? '  •  باز (در کارگاه)' : '  •  پایان ${jalaliDate('${d['closed_at']}')}'}',
    kv: <List<String>>[
      if ('${d['pistachio_type'] ?? ''}'.isNotEmpty) <String>['نوع پسته', '${d['pistachio_type']}'],
      if ('${d['crack_line_name'] ?? ''}'.isNotEmpty) <String>['خط شکست', '${d['crack_line_name']} (گرم پرتی ${_g2(d['crack_loss_gram'])})'],
      if (d['input_gram'] != null) <String>['گرم ارسالی', _g2(d['input_gram'])],
      <String>['ورودی / Σ خروجی / ضایعات', '${_kg(t.inputKg)} / ${_kg(t.inputKg - t.lossKg)} / ${_kg(t.lossKg)} کیلو', 'b'],
      ...extra,
      if (cost && d['buy_per_kg'] != null) <String>['میانگین قیمت هر کیلو ورودی', Fmt.money(ReturnsHelp.d(d['buy_per_kg']), label: false)],
      if (cost && d['kernel_cost_per_kg'] != null) <String>['بهای تمام‌شدهٔ هر کیلو مغز', Fmt.money(ReturnsHelp.d(d['kernel_cost_per_kg']), label: false), 'b'],
      if (cost && d['op_type'] != 'crack' && kWsSingleLotTypes.contains(d['op_type']) && d['cost_per_kg_sound'] != null)
        <String>['بهای تمام‌شدهٔ هر کیلو خروجی', Fmt.money(ReturnsHelp.d(d['cost_per_kg_sound']), label: false), 'b'],
      if ('${d['note'] ?? ''}'.isNotEmpty) <String>['یادداشت', '${d['note']}'],
    ],
    headers: <String>['ردیف', 'شرح', 'لات', 'وزن (کیلو)', 'عدل کوچک/بزرگ', if (cost) 'بهای کل'],
    rows: <List<String>>[
      for (final Map<String, dynamic> r in ins)
        <String>['ورودی', '${r['type_name'] ?? ''}', '${r['code'] ?? ''}', _kg(r['kg']), '${faNum(ReturnsHelp.d(r['small_sacks']), dec: 0)}/${faNum(ReturnsHelp.d(r['large_sacks']), dec: 0)}',
          if (cost) r['cost'] == null ? '—' : Fmt.money(ReturnsHelp.d(r['cost']), label: false)],
      for (final Map<String, dynamic> r in outs)
        <String>['خروجی', titleOf(r) + ('${r['lot_name'] ?? ''}'.isEmpty ? '' : ' (${r['lot_name']})'), '${r['code'] ?? ''}', _kg(r['kg']),
          '${faNum(ReturnsHelp.d(r['small_sacks']), dec: 0)}/${faNum(ReturnsHelp.d(r['large_sacks']), dec: 0)}',
          if (cost) ReturnsHelp.d(r['cost']) == 0 ? '—' : Fmt.money(ReturnsHelp.d(r['cost']), label: false)],
    ],
    filePrefix: 'workshop_op',
    signatures: const <String>['مسئول کارگاه', 'انباردار'],
  );
  if (!context.mounted) return;
  await PdfOutput.show(context, file);
}

/// چاپ فهرست عملیات کارگاه.
Future<void> wsPrintOpsList(BuildContext context, List<Map<String, dynamic>> items, {required String Function(Map<String, dynamic>) titleOf, String subtitle = ''}) async {
  final File file = await PdfService.buildTableReport(
    title: 'فهرست عملیات کارگاه',
    subtitle: subtitle,
    headers: const <String>['شروع', 'پایان', 'عملیات', 'نوع پسته', 'ورودی (کیلو)', 'خروجی (کیلو)', 'افت/ضایعات (کیلو)', 'وضعیت'],
    rows: <List<String>>[
      for (final Map<String, dynamic> o in items)
        <String>[
          jalaliDate('${o['started_at'] ?? o['date'] ?? ''}'), o['closed_at'] == null ? '—' : jalaliDate('${o['closed_at']}'), titleOf(o), '${o['pistachio_type'] ?? ''}',
          _kg(o['input_kg']), _kg(o['output_kg']), _kg(o['loss_kg']), o['status'] == kWsOpen ? 'باز' : 'بسته',
        ],
    ],
    filePrefix: 'workshop_ops',
    pageNumbers: true,
  );
  if (!context.mounted) return;
  await PdfOutput.show(context, file);
}
