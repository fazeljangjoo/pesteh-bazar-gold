import 'dart:io';

import 'package:flutter/material.dart';

import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'warehouse_ui.dart';

/// T03.2 — صورت‌حساب طرف‌حساب و سن بدهی/مطالبات. آنلاین از طریق StockApi
/// (parties.statement / parties.aging). مانده > 0 یعنی طرف‌حساب به ما بدهکار است.

double _num(dynamic v) => v is num ? v.toDouble() : (double.tryParse('${v ?? 0}') ?? 0.0);

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String _balText(double v) {
  if (v.abs() < 0.5) return 'تسویه';
  return '${faNum(v.abs(), dec: 0)} ${v > 0 ? 'بدهکار' : 'بستانکار'}';
}

class PartyStatementScreen extends StatefulWidget {
  final String partyName;
  const PartyStatementScreen({super.key, required this.partyName});

  @override
  State<PartyStatementScreen> createState() => _PartyStatementScreenState();
}

class _PartyStatementScreenState extends State<PartyStatementScreen> {
  DateTime? _from;
  DateTime? _to;
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = <String, dynamic>{};

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
      final Map<String, dynamic> payload = <String, dynamic>{'party': widget.partyName};
      if (_from != null) payload['from'] = _iso(_from!);
      if (_to != null) payload['to'] = _iso(_to!);
      final Map<String, dynamic> r = await StockApi.call('parties.statement', payload);
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pick(bool isFrom) async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : _to) ?? now,
      firstDate: DateTime(now.year - 15),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _to = d;
      }
    });
    _load();
  }

  String _periodText() {
    final String a = _from == null ? 'ابتدا' : jalaliDate(_iso(_from!));
    final String b = _to == null ? 'امروز' : jalaliDate(_iso(_to!));
    return 'بازه: از $a تا $b';
  }

  List<Map<String, dynamic>> _rows() {
    final dynamic raw = _data['rows'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> _pdf() async {
    try {
      final List<List<String>> rows = <List<String>>[
        <String>['تاریخ', 'شرح', 'بدهکار', 'بستانکار', 'مانده'],
      ];
      for (final Map<String, dynamic> r in _rows()) {
        final double d = _num(r['debit']);
        final double c = _num(r['credit']);
        rows.add(<String>[
          jalaliDate('${r['date']}'),
          '${r['label'] ?? ''}${r['ref'] != null ? ' (${r['ref']})' : ''}',
          d > 0 ? faNum(d, dec: 0) : '',
          c > 0 ? faNum(c, dec: 0) : '',
          _balText(_num(r['balance'])),
        ]);
      }
      final File f = await PdfService.buildPartyStatement(
        party: widget.partyName,
        period: _periodText(),
        summary: <(String, String)>[
          ('مانده افتتاحیه ثبت‌شده', _balText(_num(_data['opening']))),
          ('مانده ابتدای بازه', _balText(_num(_data['brought_forward']))),
          ('جمع بدهکار', faNum(_num(_data['total_debit']), dec: 0)),
          ('جمع بستانکار', faNum(_num(_data['total_credit']), dec: 0)),
          ('مانده پایان بازه', _balText(_num(_data['closing']))),
        ],
        rows: rows,
      );
      if (!mounted) return;
      await PdfOutput.show(context, f);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> rows = _rows();
    return Scaffold(
      appBar: AppBar(
        title: Text('صورت‌حساب ${widget.partyName}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'خروجی PDF',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _loading || _error != null ? null : _pdf,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('تلاش دوباره')),
                    ]),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: <Widget>[
                    Row(children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pick(true),
                          child: Text(_from == null ? 'از تاریخ' : 'از ${jalaliDate(_iso(_from!))}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _pick(false),
                          child: Text(_to == null ? 'تا تاریخ' : 'تا ${jalaliDate(_iso(_to!))}'),
                        ),
                      ),
                      if (_from != null || _to != null)
                        IconButton(
                          tooltip: 'حذف فیلتر',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _from = null;
                              _to = null;
                            });
                            _load();
                          },
                        ),
                    ]),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text('مانده افتتاحیه ثبت‌شده: ${_balText(_num(_data['opening']))}'),
                          Text('مانده ابتدای بازه: ${_balText(_num(_data['brought_forward']))}'),
                          Text('جمع بدهکار: ${faNum(_num(_data['total_debit']), dec: 0)}'),
                          Text('جمع بستانکار: ${faNum(_num(_data['total_credit']), dec: 0)}'),
                          const Divider(),
                          Text('مانده پایان بازه: ${_balText(_num(_data['closing']))}',
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                    if (rows.isEmpty)
                      const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('تراکنشی در این بازه نیست'))),
                    for (final Map<String, dynamic> r in rows)
                      Card(
                        child: ListTile(
                          title: Text('${r['label'] ?? ''}'),
                          subtitle: Text('${jalaliDate('${r['date']}')}${r['ref'] != null ? '  •  ${r['ref']}' : ''}'),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              if (_num(r['debit']) > 0)
                                Text('+${faNum(_num(r['debit']), dec: 0)}', style: TextStyle(color: Colors.green.shade800)),
                              if (_num(r['credit']) > 0)
                                Text('−${faNum(_num(r['credit']), dec: 0)}', style: TextStyle(color: Colors.red.shade800)),
                              Text(_balText(_num(r['balance'])), style: const TextStyle(fontSize: 11)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// سن بدهی/مطالبات: مانده‌های باز بر اساس سررسید (۰–۳۰، ۳۱–۶۰، ۶۱–۹۰، بیش از ۹۰ روز). مانده افتتاحیه در ستون «بیش از ۹۰» می‌آید.
class PartyAgingScreen extends StatefulWidget {
  const PartyAgingScreen({super.key});

  @override
  State<PartyAgingScreen> createState() => _PartyAgingScreenState();
}

class _PartyAgingScreenState extends State<PartyAgingScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = <String, dynamic>{};

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
      final Map<String, dynamic> r = await StockApi.call('parties.aging');
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _list(String k) {
    final dynamic raw = _data[k];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw.whereType<Map<String, dynamic>>().toList();
  }

  Widget _section(String title, String key, Color color) {
    final List<Map<String, dynamic>> rows = _list(key);
    final dynamic totals = (_data['totals'] is Map) ? (_data['totals'] as Map)[key] : null;
    final Map<String, dynamic> t = totals is Map<String, dynamic> ? totals : <String, dynamic>{};
    DataRow row(String name, Map<String, dynamic> r, {bool bold = false}) {
      final TextStyle st = TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400);
      return DataRow(cells: <DataCell>[
        DataCell(Text(name, style: st)),
        DataCell(Text(faNum(_num(r['b0_30']), dec: 0), style: st)),
        DataCell(Text(faNum(_num(r['b31_60']), dec: 0), style: st)),
        DataCell(Text(faNum(_num(r['b61_90']), dec: 0), style: st)),
        DataCell(Text(faNum(_num(r['b90p']), dec: 0), style: st)),
        DataCell(Text(faNum(_num(r['total']), dec: 0), style: st)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
        child: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
      ),
      if (rows.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('موردی نیست'))
      else
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 18,
            columns: const <DataColumn>[
              DataColumn(label: Text('طرف‌حساب')),
              DataColumn(label: Text('۰–۳۰')),
              DataColumn(label: Text('۳۱–۶۰')),
              DataColumn(label: Text('۶۱–۹۰')),
              DataColumn(label: Text('بیش از ۹۰')),
              DataColumn(label: Text('جمع')),
            ],
            rows: <DataRow>[
              for (final Map<String, dynamic> r in rows) row('${r['party']}', r),
              row('جمع کل', t, bold: true),
            ],
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('سن بدهی و مطالبات')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('تلاش دوباره')),
                    ]),
                  ),
                )
              : ListView(children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Text('تا تاریخ ${jalaliDate('${_data['as_of']}')} — مبالغ هنوز نرسیده در ستون ۰–۳۰ است.',
                        style: const TextStyle(fontSize: 12)),
                  ),
                  _section('مطالبات از مشتریان (بدهکاران)', 'debtors', Colors.green.shade800),
                  _section('بدهی‌های ما (بستانکاران)', 'creditors', Colors.red.shade800),
                  const SizedBox(height: 24),
                ]),
    );
  }
}
