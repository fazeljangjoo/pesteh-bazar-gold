import 'dart:io';

import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'ledger_reports_ui.dart' show LedgerTables, kLrExportMax;
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S18.T18.4 — electronic books (دفاتر الکترونیک): journal book + general-ledger (کل) book as paginated PDF (company header, FY, page numbers,
/// signature block) and Excel. Server `reports.ebook` gives header + ledger rows + a check that ledger totals == journal totals == trial balance.
/// Journal rows come from `reports.journal` (same data as the screen). Amounts: integer rial. Official layout must be confirmed by the accountant.

String _em(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 0);
List<Map<String, dynamic>> _el(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

class EBooksScreen extends StatefulWidget {
  const EBooksScreen({super.key});

  @override
  State<EBooksScreen> createState() => _EBooksScreenState();
}

class _EBooksScreenState extends State<EBooksScreen> {
  int? _fy;
  DateTime? _from;
  DateTime? _to;
  bool _finalOnly = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];
  Map<String, dynamic>? _head;

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
        _years = _el(y['items']);
        for (final Map<String, dynamic> f in _years) {
          if (f['is_current'] == true) _fy = (f['id'] as num).toInt();
        }
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
    _check();
  }

  String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> _params() {
    final Map<String, dynamic> p = <String, dynamic>{'final_only': _finalOnly ? 1 : 0};
    if (_fy != null) p['fiscal_year_id'] = _fy;
    if (_from != null) p['from'] = _iso(_from!);
    if (_to != null) p['to'] = _iso(_to!);
    return p;
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('reports.ebook', _params());
      if (!mounted) return;
      setState(() {
        _head = r;
        _busy = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  String get _sub {
    final Map<String, dynamic> h = _head ?? <String, dynamic>{};
    final String fy = '${(h['fiscal_year'] as Map?)?['name'] ?? ''}';
    final String f = h['from'] == null ? '' : jalaliDateFromDt(DateTime.parse('${h['from']}'));
    final String t = h['to'] == null ? '' : jalaliDateFromDt(DateTime.parse('${h['to']}'));
    return 'سال مالی $fy · از $f تا $t · ${_finalOnly ? 'فقط اسناد قطعی' : 'اسناد ثبت‌شده'} · مبالغ به ریال';
  }

  List<List<String>> _ledgerRows(Map<String, dynamic> h) {
    final List<List<String>> rows = <List<String>>[
      for (final Map<String, dynamic> r in _el(h['ledger_rows']))
        <String>['${r['code']}', '${r['name']}', _em(r['open_debit']), _em(r['open_credit']), _em(r['period_debit']), _em(r['period_credit']), _em(r['close_debit']), _em(r['close_credit'])],
    ];
    final Map<String, dynamic> t = Map<String, dynamic>.from((h['ledger_totals'] as Map?) ?? <String, dynamic>{});
    rows.add(<String>['', 'جمع', _em(t['open_debit']), _em(t['open_credit']), _em(t['period_debit']), _em(t['period_credit']), _em(t['close_debit']), _em(t['close_credit'])]);
    return rows;
  }

  static const List<String> _ledgerHeaders = <String>['کد', 'عنوان حساب کل', 'اول دوره بدهکار', 'اول دوره بستانکار', 'گردش بدهکار', 'گردش بستانکار', 'مانده بدهکار', 'مانده بستانکار'];

  Future<void> _export(bool journal, bool pdf) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> h = await StockApi.call('reports.ebook', _params());
      List<String> headers = _ledgerHeaders;
      List<List<String>> rows = _ledgerRows(h);
      if (journal) {
        final Map<String, dynamic> p = _params();
        final Map<String, dynamic> jr = await StockApi.call('reports.journal', <String, dynamic>{
          if (p['fiscal_year_id'] != null) 'fiscal_year_id': p['fiscal_year_id'],
          'from': h['from'],
          'to': h['to'],
          'status': _finalOnly ? 'final' : 'posted',
          'limit': kLrExportMax,
          'offset': 0,
          'csv': 1,
        });
        headers = LedgerTables.journalHeaders;
        rows = LedgerTables.journalRows(jr);
      }
      if (!mounted) return;
      setState(() => _head = h);
      final String title = journal ? 'دفتر روزنامه' : 'دفتر کل';
      final File f;
      if (pdf) {
        f = await PdfService.buildTableReport(
          title: title,
          subtitle: _sub,
          headers: headers,
          rows: rows,
          filePrefix: journal ? 'ebook_journal' : 'ebook_ledger',
          company: '${h['company'] ?? ''}',
          pageNumbers: true,
          signatures: const <String>['تهیه‌کننده', 'حسابدار', 'مدیر'],
        );
        if (!mounted) return;
        await PdfOutput.show(context, f);
      } else {
        f = await ExcelIo.exportTable(columns: headers, rows: rows, sheetName: title, filePrefix: journal ? 'ebook_journal' : 'ebook_ledger');
        if (!mounted) return;
        await ExcelIo.saveOrShare(context, f);
      }
      if (!mounted) return;
      setState(() => _busy = false);
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _pick(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _check();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> chk = Map<String, dynamic>.from((_head?['check'] as Map?) ?? <String, dynamic>{});
    final bool ok = chk['journal_equals_trial'] == true;
    final Map<String, dynamic> jt = Map<String, dynamic>.from((_head?['journal_totals'] as Map?) ?? <String, dynamic>{});
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('دفاتر الکترونیک', style: TextStyle(fontSize: 16))),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
            DropdownButton<int?>(
              value: _fy,
              hint: const Text('سال مالی'),
              items: <DropdownMenuItem<int?>>[for (final Map<String, dynamic> f in _years) DropdownMenuItem<int?>(value: (f['id'] as num).toInt(), child: Text('${f['name']}'))],
              onChanged: (int? v) {
                setState(() => _fy = v);
                _check();
              },
            ),
            OutlinedButton(onPressed: () => _pick(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
            OutlinedButton(onPressed: () => _pick(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('فقط اسناد قطعی'),
            value: _finalOnly,
            onChanged: (bool v) {
              setState(() => _finalOnly = v);
              _check();
            },
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (_head != null)
            Card(
              child: ListTile(
                leading: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, color: ok ? Colors.green : Colors.red),
                title: Text(ok ? 'جمع دفاتر با تراز آزمایشی برابر است' : 'مغایرت بین دفاتر و تراز آزمایشی!'),
                subtitle: Text('${_em(_head!['voucher_count'])} سند · بدهکار ${_em(jt['debit'])} · بستانکار ${_em(jt['credit'])}'),
              ),
            ),
          const SizedBox(height: 8),
          for (final List<Object> b in <List<Object>>[
            <Object>['دفتر روزنامه', true],
            <Object>['دفتر کل', false],
          ])
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: <Widget>[
                  Expanded(child: Text(b[0] as String, style: const TextStyle(fontWeight: FontWeight.bold))),
                  OutlinedButton.icon(onPressed: _busy ? null : () => _export(b[1] as bool, true), icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('PDF')),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(onPressed: _busy ? null : () => _export(b[1] as bool, false), icon: const Icon(Icons.table_chart_outlined), label: const Text('اکسل')),
                ]),
              ),
            ),
          const Padding(padding: EdgeInsets.all(8), child: Text('قالب رسمی دفاتر الکترونیک باید توسط حسابدار تأیید شود.', style: TextStyle(fontSize: 12))),
        ]),
      ),
    );
  }
}
