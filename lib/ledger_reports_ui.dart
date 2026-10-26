import 'dart:io';

import 'package:flutter/material.dart';

import 'excel_io.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'vouchers_ui.dart' show VoucherDetailScreen;
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S18.T18.1 — journal (روزنامه), general/subsidiary ledger (کل/معین) and tafsili statement (gold, perm accounting.view).
/// Server actions: reports.journal | reports.ledger | reports.tafsili. Amounts are integer rial, shown as rial.
/// The ledger level is simply the level of the picked account (کل = level 2, معین = level 3); sub-accounts are listed for drill-down.
/// Pagination: ledger/tafsili rows are appended with «بیشتر»; the server returns an exact running balance for every page.
/// PDF/Excel export fetches the whole result (server csv-sized limit) through the same actions.

const Map<String, String> kLrModes = <String, String>{'journal': 'روزنامه', 'ledger': 'دفتر کل/معین', 'tafsili': 'صورت‌حساب تفصیلی'};
const Map<String, String> kLrStatuses = <String, String>{'posted': 'ثبت‌شده (موقت+قطعی)', 'final': 'فقط قطعی', 'all': 'همه (با پیش‌نویس)'};
const Map<String, String> kLrSourceTypes = <String, String>{'manual': 'دستی'};
const int kLrPage = 100;
const int kLrExportMax = 20000;

String _m(dynamic v) => faNum(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), dec: 0);
int _i(dynamic v) => (v is num) ? v.toInt() : (int.tryParse('${v ?? 0}') ?? 0);
String _jd(dynamic iso) => (iso == null || '$iso'.isEmpty) ? '-' : jalaliDate('$iso');
String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _side(dynamic s) => s == 'debit' ? 'بد' : (s == 'credit' ? 'بس' : '-');
List<Map<String, dynamic>> _list(dynamic v) => <Map<String, dynamic>>[
      for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map),
    ];

/// Plain-table forms shared by screen, PDF and Excel.
class LedgerTables {
  static const List<String> lineHeaders = <String>['سند', 'تاریخ', 'حساب', 'تفصیلی', 'شرح', 'بدهکار', 'بستانکار', 'مانده', ''];

  static List<String> _row(Map<String, dynamic> r) => <String>[
        r['number'] == null ? 'پیش‌نویس' : faNum(_i(r['number']), dec: 0),
        _jd(r['date']),
        '${r['account_code'] ?? ''} ${r['account_name'] ?? ''}'.trim(),
        '${r['tafsili_code'] ?? ''} ${r['tafsili_name'] ?? ''}'.trim(),
        '${(r['description'] ?? '') == '' ? (r['voucher_description'] ?? '') : r['description']}',
        _m(r['debit']),
        _m(r['credit']),
        _m(((r['balance'] ?? 0) as num).abs()),
        _side(r['side']),
      ];

  static List<List<String>> lineRows(Map<String, dynamic> rep) {
    final Map<String, dynamic> o = Map<String, dynamic>.from(rep['opening'] as Map? ?? <String, dynamic>{});
    final Map<String, dynamic> p = Map<String, dynamic>.from(rep['period'] as Map? ?? <String, dynamic>{});
    final Map<String, dynamic> c = Map<String, dynamic>.from(rep['closing'] as Map? ?? <String, dynamic>{});
    final List<List<String>> rows = <List<String>>[
      <String>['', '', '', '', 'مانده اول دوره', _m(o['debit']), _m(o['credit']), _m(o['amount']), _side(o['side'])],
      for (final Map<String, dynamic> r in _list(rep['rows'])) _row(r),
      <String>['', '', '', '', 'جمع گردش', _m(p['debit']), _m(p['credit']), _m(p['amount']), _side(p['side'])],
      <String>['', '', '', '', 'مانده پایان', _m(c['debit']), _m(c['credit']), _m(c['amount']), _side(c['side'])],
    ];
    return rows;
  }

  static const List<String> journalHeaders = <String>['سند', 'تاریخ', 'وضعیت', 'مبدأ', 'ردیف', 'حساب', 'تفصیلی', 'شرح', 'بدهکار', 'بستانکار'];

  static List<List<String>> journalRows(Map<String, dynamic> rep) {
    final List<List<String>> rows = <List<String>>[];
    for (final Map<String, dynamic> h in _list(rep['items'])) {
      for (final Map<String, dynamic> l in _list(h['lines'])) {
        rows.add(<String>[
          h['number'] == null ? 'پیش‌نویس' : faNum(_i(h['number']), dec: 0),
          _jd(h['date']),
          '${h['status'] ?? ''}',
          '${h['source_type'] ?? ''}',
          faNum(_i(l['line_no']), dec: 0),
          '${l['account_code'] ?? ''} ${l['account_name'] ?? ''}'.trim(),
          '${l['tafsili_code'] ?? ''} ${l['tafsili_name'] ?? ''}'.trim(),
          '${(l['description'] ?? '') == '' ? (h['description'] ?? '') : l['description']}',
          _m(l['debit']),
          _m(l['credit']),
        ]);
      }
    }
    final Map<String, dynamic> t = Map<String, dynamic>.from(rep['totals'] as Map? ?? <String, dynamic>{});
    rows.add(<String>['', '', '', '', '', '', '', 'جمع کل', _m(t['debit']), _m(t['credit'])]);
    return rows;
  }
}

class LedgerReportsScreen extends StatefulWidget {
  const LedgerReportsScreen({super.key, this.initialMode = 'journal'});
  final String initialMode;

  @override
  State<LedgerReportsScreen> createState() => _LedgerReportsScreenState();
}

class _LedgerReportsScreenState extends State<LedgerReportsScreen> {
  late String _mode;
  String _status = 'posted';
  int? _fy;
  int? _accountId;
  int? _tafsiliId;
  DateTime? _from;
  DateTime? _to;
  final TextEditingController _noFrom = TextEditingController();
  final TextEditingController _noTo = TextEditingController();
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _tafsilis = <Map<String, dynamic>>[];
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _rep; // ledger/tafsili: merged pages; journal: merged items
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _bootstrap();
  }

  @override
  void dispose() {
    _noFrom.dispose();
    _noTo.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final Map<String, dynamic> y = await StockApi.call('fiscal_years.list');
      final Map<String, dynamic> a = await StockApi.call('accounts.list');
      final Map<String, dynamic> t = await StockApi.call('tafsili.list');
      if (!mounted) return;
      setState(() {
        _years = _list(y['items']);
        _accounts = _list(a['items']);
        _tafsilis = _list(t['items']);
        for (final Map<String, dynamic> f in _years) {
          if (f['is_current'] == true) _fy = _i(f['id']);
        }
      });
      _load();
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Map<String, dynamic> _params({int offset = 0, int limit = kLrPage}) {
    final Map<String, dynamic> p = <String, dynamic>{'status': _status, 'limit': limit, 'offset': offset};
    if (_fy != null) p['fiscal_year_id'] = _fy;
    if (_from != null) p['from'] = _iso(_from!);
    if (_to != null) p['to'] = _iso(_to!);
    if (_noFrom.text.trim().isNotEmpty) p['no_from'] = int.tryParse(toEnDigits(_noFrom.text.trim())) ?? 0;
    if (_noTo.text.trim().isNotEmpty) p['no_to'] = int.tryParse(toEnDigits(_noTo.text.trim())) ?? 0;
    if (_accountId != null) p['account_id'] = _accountId;
    if (_tafsiliId != null) p['tafsili_id'] = _tafsiliId;
    return p;
  }

  String get _action => _mode == 'journal' ? 'reports.journal' : (_mode == 'ledger' ? 'reports.ledger' : 'reports.tafsili');

  bool get _ready => _mode == 'journal' || (_mode == 'ledger' && _accountId != null) || (_mode == 'tafsili' && _tafsiliId != null);

  Future<void> _load({bool more = false}) async {
    if (!_ready) {
      setState(() {
        _rep = null;
        _rows = <Map<String, dynamic>>[];
        _items = <Map<String, dynamic>>[];
        _error = null;
      });
      return;
    }
    final int offset = more ? (_mode == 'journal' ? _items.length : _rows.length) : 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call(_action, _params(offset: offset, limit: _mode == 'journal' ? 30 : kLrPage));
      if (!mounted) return;
      setState(() {
        _rep = r;
        if (_mode == 'journal') {
          _items = more ? <Map<String, dynamic>>[..._items, ..._list(r['items'])] : _list(r['items']);
        } else {
          _rows = more ? <Map<String, dynamic>>[..._rows, ..._list(r['rows'])] : _list(r['rows']);
        }
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

  Future<Map<String, dynamic>?> _fetchAll() async {
    try {
      return await StockApi.call(_action, <String, dynamic>{..._params(limit: kLrExportMax), 'csv': 1});
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
      return null;
    }
  }

  String get _title {
    if (_mode == 'journal') return 'دفتر روزنامه';
    if (_mode == 'ledger') {
      final Map<String, dynamic>? a = _rep?['account'] == null ? null : Map<String, dynamic>.from(_rep!['account'] as Map);
      final int lvl = a == null ? 0 : _i(a['level']);
      return 'دفتر ${lvl >= 3 ? 'معین' : 'کل'}${a == null ? '' : ' · ${a['code']} ${a['name']}'}';
    }
    final Map<String, dynamic>? t = _rep?['tafsili'] == null ? null : Map<String, dynamic>.from(_rep!['tafsili'] as Map);
    return 'صورت‌حساب تفصیلی${t == null ? '' : ' · ${t['code']} ${t['name']}'}';
  }

  String get _subtitle {
    final List<String> s = <String>[];
    if (_from != null || _to != null) s.add('از ${_from == null ? '-' : jalaliDateFromDt(_from!)} تا ${_to == null ? '-' : jalaliDateFromDt(_to!)}');
    s.add(kLrStatuses[_status] ?? '');
    return s.join(' · ');
  }

  Future<void> _pdf() async {
    final Map<String, dynamic>? all = await _fetchAll();
    if (all == null || !mounted) return;
    final bool j = _mode == 'journal';
    final File f = await PdfService.buildTableReport(
      title: _title,
      subtitle: _subtitle,
      headers: j ? LedgerTables.journalHeaders : LedgerTables.lineHeaders,
      rows: j ? LedgerTables.journalRows(all) : LedgerTables.lineRows(all),
      filePrefix: 'ledger',
    );
    if (!mounted) return;
    await PdfOutput.show(context, f);
  }

  Future<void> _excel() async {
    final Map<String, dynamic>? all = await _fetchAll();
    if (all == null || !mounted) return;
    final bool j = _mode == 'journal';
    final File f = await ExcelIo.exportTable(
      columns: j ? LedgerTables.journalHeaders : LedgerTables.lineHeaders,
      rows: j ? LedgerTables.journalRows(all) : LedgerTables.lineRows(all),
      sheetName: _mode == 'journal' ? 'روزنامه' : 'دفتر',
      filePrefix: 'ledger',
    );
    if (!mounted) return;
    await ExcelIo.saveOrShare(context, f);
  }

  Future<void> _pickDate(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d == null) return;
    setState(() => from ? _from = d : _to = d);
    _load();
  }

  Future<void> _pickAccount() async {
    final Map<String, dynamic>? a = await _pickFrom(_accounts.where((Map<String, dynamic> x) => _i(x['level']) >= 2).toList(), 'انتخاب حساب (کل/معین)');
    if (a == null) return;
    setState(() => _accountId = _i(a['id']));
    _load();
  }

  Future<void> _pickTafsili() async {
    final Map<String, dynamic>? t = await _pickFrom(_tafsilis, 'انتخاب تفصیلی');
    if (t == null) return;
    setState(() => _tafsiliId = _i(t['id']));
    _load();
  }

  Future<Map<String, dynamic>?> _pickFrom(List<Map<String, dynamic>> items, String title) {
    String q = '';
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => StatefulBuilder(builder: (BuildContext ctx, StateSetter set) {
        final List<Map<String, dynamic>> shown = <Map<String, dynamic>>[
          for (final Map<String, dynamic> x in items)
            if (q.isEmpty || '${x['code']} ${x['name']}'.contains(q)) x,
        ];
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: Column(children: <Widget>[
            Padding(padding: const EdgeInsets.all(12), child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(decoration: const InputDecoration(hintText: 'جست‌وجو', prefixIcon: Icon(Icons.search)), onChanged: (String v) => set(() => q = v.trim())),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (BuildContext c, int i) => ListTile(
                  dense: true,
                  title: Text('${shown[i]['code']} · ${shown[i]['name']}'),
                  subtitle: shown[i]['level'] == null ? null : Text('سطح ${toFaDigits('${shown[i]['level']}')}'),
                  onTap: () => Navigator.pop(ctx, shown[i]),
                ),
              ),
            ),
          ]),
        );
      }),
    );
  }

  void _openVoucher(dynamic id) {
    final int vid = _i(id);
    if (vid <= 0) return;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VoucherDetailScreen(id: vid)));
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
        DropdownButton<int?>(
          value: _fy,
          hint: const Text('سال مالی'),
          items: <DropdownMenuItem<int?>>[
            const DropdownMenuItem<int?>(value: null, child: Text('همه سال‌ها')),
            for (final Map<String, dynamic> f in _years) DropdownMenuItem<int?>(value: _i(f['id']), child: Text('${f['name']}')),
          ],
          onChanged: (int? v) {
            setState(() => _fy = v);
            _load();
          },
        ),
        DropdownButton<String>(
          value: _status,
          items: <DropdownMenuItem<String>>[for (final MapEntry<String, String> e in kLrStatuses.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value))],
          onChanged: (String? v) {
            if (v == null) return;
            setState(() => _status = v);
            _load();
          },
        ),
        OutlinedButton(onPressed: () => _pickDate(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!))),
        OutlinedButton(onPressed: () => _pickDate(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!))),
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
        SizedBox(width: 90, child: TextField(controller: _noFrom, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'از شماره سند'), onSubmitted: (_) => _load())),
        SizedBox(width: 90, child: TextField(controller: _noTo, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'تا شماره سند'), onSubmitted: (_) => _load())),
        OutlinedButton.icon(
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: Text(_accountId == null ? (_mode == 'journal' ? 'فیلتر حساب' : 'انتخاب حساب') : _accName(_accountId!)),
            onPressed: _pickAccount,
          ),
        if (_accountId != null && _mode != 'ledger')
          IconButton(
            tooltip: 'حذف فیلتر حساب',
            icon: const Icon(Icons.clear),
            onPressed: () {
              setState(() => _accountId = null);
              _load();
            },
          ),
        if (_mode != 'ledger')
          OutlinedButton.icon(
            icon: const Icon(Icons.person_search_outlined, size: 18),
            label: Text(_tafsiliId == null ? (_mode == 'journal' ? 'فیلتر تفصیلی' : 'انتخاب تفصیلی') : _tafName(_tafsiliId!)),
            onPressed: _pickTafsili,
          ),
        if (_tafsiliId != null && _mode == 'journal')
          IconButton(
            tooltip: 'حذف فیلتر تفصیلی',
            icon: const Icon(Icons.clear),
            onPressed: () {
              setState(() => _tafsiliId = null);
              _load();
            },
          ),
      ]),
    );
  }

  String _accName(int id) {
    for (final Map<String, dynamic> a in _accounts) {
      if (_i(a['id']) == id) return '${a['code']} ${a['name']}';
    }
    return '#$id';
  }

  String _tafName(int id) {
    for (final Map<String, dynamic> t in _tafsilis) {
      if (_i(t['id']) == id) return '${t['code']} ${t['name']}';
    }
    return '#$id';
  }

  Widget _balanceCard(String label, dynamic b) {
    final Map<String, dynamic> m = Map<String, dynamic>.from(b as Map? ?? <String, dynamic>{});
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: <Widget>[
            Text(label, style: const TextStyle(fontSize: 12)),
            Text('${_m(m['amount'])} ${_side(m['side'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('بد ${_m(m['debit'])} · بس ${_m(m['credit'])}', style: const TextStyle(fontSize: 11)),
          ]),
        ),
      ),
    );
  }

  Widget _childrenList() {
    final List<Map<String, dynamic>> ch = _list(_rep?['children']);
    if (ch.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        title: Text('زیرحساب‌ها (${toFaDigits('${ch.length}')})'),
        children: <Widget>[
          for (final Map<String, dynamic> c in ch)
            ListTile(
              dense: true,
              title: Text('${c['code']} · ${c['name']}'),
              subtitle: Text('گردش: بد ${_m((c['period'] as Map)['debit'])} · بس ${_m((c['period'] as Map)['credit'])}'),
              trailing: Text('${_m((c['closing'] as Map)['amount'])} ${_side((c['closing'] as Map)['side'])}'),
              onTap: () {
                setState(() => _accountId = _i(c['id']));
                _load();
              },
            ),
        ],
      ),
    );
  }

  Widget _lineList() {
    if (_rep == null) return const SizedBox.shrink();
    final int count = _i(_rep!['count']);
    return ListView(padding: const EdgeInsets.all(8), children: <Widget>[
      Row(children: <Widget>[_balanceCard('مانده اول دوره', _rep!['opening']), _balanceCard('گردش', _rep!['period']), _balanceCard('مانده پایان', _rep!['closing'])]),
      _childrenList(),
      if (_mode == 'tafsili' && _list(_rep!['by_account']).isNotEmpty)
        Card(
          child: ExpansionTile(
            title: const Text('تفکیک به تفکیک حساب'),
            children: <Widget>[
              for (final Map<String, dynamic> b in _list(_rep!['by_account']))
                ListTile(
                  dense: true,
                  title: Text('${b['code']} · ${b['name']}'),
                  trailing: Text('${_m((b['period'] as Map)['amount'])} ${_side((b['period'] as Map)['side'])}'),
                ),
            ],
          ),
        ),
      for (final Map<String, dynamic> r in _rows)
        Card(
          child: ListTile(
            dense: true,
            onTap: () => _openVoucher(r['voucher_id']),
            title: Text('${r['number'] == null ? 'پیش‌نویس' : 'سند ${faNum(_i(r['number']), dec: 0)}'} · ${_jd(r['date'])} · ${r['account_code']} ${r['account_name']}'),
            subtitle: Text(<String>[
              if ('${r['tafsili_name'] ?? ''}'.isNotEmpty) '${r['tafsili_name']}',
              if ('${r['description'] ?? ''}'.isNotEmpty) '${r['description']}' else '${r['voucher_description'] ?? ''}',
              if (r['source_type'] != 'manual') 'مبدأ: ${r['source_type']} ${r['source_id'] ?? ''}',
            ].where((String s) => s.trim().isNotEmpty).join(' · ')),
            trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
              if (_i(r['debit']) != 0) Text('بد ${_m(r['debit'])}', style: const TextStyle(fontSize: 12)),
              if (_i(r['credit']) != 0) Text('بس ${_m(r['credit'])}', style: const TextStyle(fontSize: 12)),
              Text('${_m(((r['balance'] ?? 0) as num).abs())} ${_side(r['side'])}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ]),
          ),
        ),
      if (_rows.length < count)
        Center(child: TextButton(onPressed: _loading ? null : () => _load(more: true), child: Text('بیشتر (${toFaDigits('${_rows.length}')} از ${toFaDigits('$count')})'))),
      if (_rows.isEmpty && !_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی یافت نشد'))),
    ]);
  }

  Widget _journalList() {
    if (_rep == null) return const SizedBox.shrink();
    final int count = _i(_rep!['count']);
    final Map<String, dynamic> t = Map<String, dynamic>.from(_rep!['totals'] as Map? ?? <String, dynamic>{});
    return ListView(padding: const EdgeInsets.all(8), children: <Widget>[
      Card(
        child: ListTile(
          dense: true,
          title: Text('جمع کل: بد ${_m(t['debit'])} · بس ${_m(t['credit'])}'),
          trailing: Icon(t['balanced'] == true ? Icons.check_circle_outline : Icons.error_outline, color: t['balanced'] == true ? Colors.green : Colors.red),
        ),
      ),
      for (final Map<String, dynamic> h in _items)
        Card(
          child: ExpansionTile(
            title: Text('${h['number'] == null ? 'پیش‌نویس' : 'سند ${faNum(_i(h['number']), dec: 0)}'} · ${_jd(h['date'])}'),
            subtitle: Text('${h['description'] ?? ''}  (${h['status']}${h['source_type'] == 'manual' ? '' : ' · ${h['source_type']}'})'),
            trailing: Text(_m(h['debit'])),
            children: <Widget>[
              for (final Map<String, dynamic> l in _list(h['lines']))
                ListTile(
                  dense: true,
                  title: Text('${l['account_code']} ${l['account_name']}${'${l['tafsili_name'] ?? ''}'.isEmpty ? '' : ' · ${l['tafsili_name']}'}'),
                  subtitle: '${l['description'] ?? ''}'.isEmpty ? null : Text('${l['description']}'),
                  trailing: Text(_i(l['debit']) != 0 ? 'بد ${_m(l['debit'])}' : 'بس ${_m(l['credit'])}'),
                ),
              Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => _openVoucher(h['id']), child: const Text('مشاهدهٔ سند و سند مبدأ'))),
            ],
          ),
        ),
      if (_items.length < count)
        Center(child: TextButton(onPressed: _loading ? null : () => _load(more: true), child: Text('بیشتر (${toFaDigits('${_items.length}')} از ${toFaDigits('$count')})'))),
      if (_items.isEmpty && !_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('موردی یافت نشد'))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasData = _rep != null && _ready;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title, style: const TextStyle(fontSize: 15)),
          actions: <Widget>[
            IconButton(tooltip: 'خروجی PDF', onPressed: !hasData || _loading ? null : _pdf, icon: const Icon(Icons.picture_as_pdf_outlined)),
            IconButton(tooltip: 'خروجی اکسل', onPressed: !hasData || _loading ? null : _excel, icon: const Icon(Icons.table_chart_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: Column(children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: <Widget>[
              for (final MapEntry<String, String> e in kLrModes.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: _mode == e.key,
                    onSelected: (_) {
                      setState(() {
                        _mode = e.key;
                        _rep = null;
                        _rows = <Map<String, dynamic>>[];
                        _items = <Map<String, dynamic>>[];
                      });
                      _load();
                    },
                  ),
                ),
            ]),
          ),
          _filters(),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          if (!_ready) Padding(padding: const EdgeInsets.all(24), child: Text(_mode == 'ledger' ? 'یک حساب کل یا معین را انتخاب کنید' : 'یک تفصیلی را انتخاب کنید')),
          Expanded(child: _mode == 'journal' ? _journalList() : _lineList()),
        ]),
      ),
    );
  }
}
