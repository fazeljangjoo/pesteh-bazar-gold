import 'dart:convert';

import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;
import 'package:shared_preferences/shared_preferences.dart';

import 'cheque_report_ui.dart';
import 'returns_ui.dart' show ReturnsHelp;
import 'utils.dart';
import 'vouchers_links.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S06.T06.2 — cheque management over the server register (cheques.list/get/transition).
/// Reading is cached in SharedPreferences; status changes made offline are queued (in order) and replayed when
/// the server is reachable. No local SQLite tables / schemaVersion bump (the register lives on the server).
const Map<String, String> kChequeLabels = <String, String>{
  'in_hand': 'نزد ما',
  'deposited': 'در جریان وصول',
  'cleared': 'پاس‌شده',
  'bounced': 'برگشتی',
  'endorsed': 'خرج‌شده',
  'returned_to_payer': 'عودت به صادرکننده',
  'pending': 'صادرشده (در انتظار)',
  'cancelled': 'ابطال‌شده',
};
const Map<String, String> kChequeActionLabels = <String, String>{
  'deposited': 'واگذاری به بانک (وصول)',
  'cleared': 'پاس شد',
  'bounced': 'برگشت خورد',
  'endorsed': 'خرج کردن به طرف حساب',
  'returned_to_payer': 'عودت به صادرکننده',
  'cancelled': 'ابطال',
};
const Map<String, Color> _kStatusColors = <String, Color>{
  'cleared': Color(0xFF2E7D32),
  'bounced': Color(0xFFC62828),
  'deposited': Color(0xFF1565C0),
  'endorsed': Color(0xFF6A1B9A),
};

double _d(dynamic v) => ReturnsHelp.d(v);

/// Persistent op queue + list cache. Ops are replayed strictly in order; a server rejection (4xx) drops that op and is reported.
class ChequeStore {
  ChequeStore._();
  static const String _kCache = 'cheque_cache_v1';
  static const String _kOps = 'cheque_ops_v1';

  static Future<List<Map<String, dynamic>>> cached() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kCache);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> saveCache(List<Map<String, dynamic>> items) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kCache, jsonEncode(items));
  }

  static Future<List<Map<String, dynamic>>> pendingOps() async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? raw = sp.getString(_kOps);
    if (raw == null) return <Map<String, dynamic>>[];
    try {
      return ReturnsHelp.maps(jsonDecode(raw));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _saveOps(List<Map<String, dynamic>> ops) async {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(_kOps, jsonEncode(ops));
  }

  static Future<void> enqueue(Map<String, dynamic> op) async {
    final List<Map<String, dynamic>> ops = await pendingOps();
    ops.add(op);
    await _saveOps(ops);
  }

  /// Replays queued transitions in order. Stops at the first network failure (keeps order). Returns error messages of rejected ops.
  static Future<List<String>> flush() async {
    final List<String> errors = <String>[];
    List<Map<String, dynamic>> ops = await pendingOps();
    while (ops.isNotEmpty) {
      final Map<String, dynamic> op = ops.first;
      try {
        await StockApi.call('cheques.transition', Map<String, dynamic>.from(op));
      } on StockApiException catch (e) {
        if (isNetworkError(e.message) || e.message.contains('ورود مجدد')) break; // keep the queue, retry later
        errors.add('چک ${op['label'] ?? op['id']}: ${e.message}'); // server rejected (illegal transition etc.)
      }
      ops = ops.sublist(1);
      await _saveOps(ops);
    }
    return errors;
  }

  static bool isNetworkError(String m) => m.contains('اتصال به سرور') || m.contains('خطای سرور');

  /// Applies queued ops on top of cached/fetched items so the UI shows the pending state immediately.
  static List<Map<String, dynamic>> overlay(List<Map<String, dynamic>> items, List<Map<String, dynamic>> ops) {
    final List<Map<String, dynamic>> out = items.map((Map<String, dynamic> e) => Map<String, dynamic>.from(e)).toList();
    for (final Map<String, dynamic> op in ops) {
      for (final Map<String, dynamic> c in out) {
        if (_d(c['id']).toInt() == _d(op['id']).toInt()) {
          c['status'] = op['to'];
          c['status_label'] = kChequeLabels['${op['to']}'] ?? '${op['to']}';
          c['next'] = <String>[];
          c['pending_sync'] = true;
          if (op['endorsed_to'] != null) c['endorsed_to'] = op['endorsed_to'];
        }
      }
    }
    return out;
  }
}

/// Transition flow shared by list and detail screens. Returns true when something was done (sent or queued).
Future<bool> runChequeTransition(BuildContext context, Map<String, dynamic> cheque, String to) async {
  String? endorsed;
  String? note;
  final TextEditingController noteC = TextEditingController();
  final TextEditingController partyC = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext c) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(kChequeActionLabels[to] ?? to),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text('چک ${cheque['number'] ?? ''} — ${Fmt.money(_d(cheque['amount']))}'),
          const SizedBox(height: 8),
          if (to == 'endorsed') textField(partyC, 'خرج به چه کسی؟ (نام طرف حساب)', required: true),
          textField(noteC, 'توضیح (اختیاری)'),
          if (to == 'bounced')
            const Text('با ثبت برگشت، مبلغ دوباره به‌عنوان مطالبه/بدهی باز می‌شود.', style: TextStyle(fontSize: 12)),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ثبت')),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  endorsed = partyC.text.trim().isEmpty ? null : partyC.text.trim();
  note = noteC.text.trim().isEmpty ? null : noteC.text.trim();
  if (to == 'endorsed' && endorsed == null) {
    if (context.mounted) snack(context, 'نام طرف حساب را وارد کنید');
    return false;
  }
  final Map<String, dynamic> op = <String, dynamic>{
    'id': _d(cheque['id']).toInt(),
    'to': to,
    'date': ReturnsHelp.iso(DateTime.now()),
    'label': '${cheque['number'] ?? cheque['id']}',
    if (note != null) 'note': note,
    if (endorsed != null) 'endorsed_to': endorsed,
  };
  await ChequeStore.enqueue(op);
  final List<String> errs = await ChequeStore.flush();
  final bool stillQueued = (await ChequeStore.pendingOps()).isNotEmpty;
  if (context.mounted) {
    if (errs.isNotEmpty) {
      snack(context, errs.first);
    } else if (stillQueued) {
      snack(context, 'آفلاین هستید؛ تغییر وضعیت در صف ماند و پس از اتصال ارسال می‌شود');
    } else {
      snack(context, 'وضعیت چک ثبت شد');
    }
  }
  return true;
}

class ChequeListScreen extends StatefulWidget {
  const ChequeListScreen({super.key});
  @override
  State<ChequeListScreen> createState() => _ChequeListScreenState();
}

class _ChequeListScreenState extends State<ChequeListScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;
  int _pending = 0;
  String _status = '';
  bool _calendar = false;
  final TextEditingController _q = TextEditingController();
  DateTime? _from;
  DateTime? _to;
  final TextEditingController _minAmt = TextEditingController();
  final TextEditingController _maxAmt = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (!_tab.indexIsChanging) setState(() => _status = '');
    });
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    _q.dispose();
    _minAmt.dispose();
    _maxAmt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final List<String> errs = await ChequeStore.flush();
    List<Map<String, dynamic>> items;
    bool offline = false;
    try {
      final Map<String, dynamic> r = await StockApi.call('cheques.list');
      items = ReturnsHelp.maps(r['items']);
      await ChequeStore.saveCache(items);
    } on StockApiException {
      items = await ChequeStore.cached();
      offline = true;
    }
    final List<Map<String, dynamic>> ops = await ChequeStore.pendingOps();
    if (!mounted) return;
    setState(() {
      _items = ChequeStore.overlay(items, ops);
      _offline = offline;
      _pending = ops.length;
      _loading = false;
    });
    if (errs.isNotEmpty) snack(context, errs.first);
  }

  List<Map<String, dynamic>> get _filtered {
    final String dir = _tab.index == 0 ? 'received' : 'issued';
    final String q = _q.text.trim();
    final double? minA = parseNum(_minAmt.text);
    final double? maxA = parseNum(_maxAmt.text);
    return _items.where((Map<String, dynamic> c) {
      if ('${c['direction']}' != dir) return false;
      if (_status.isNotEmpty && '${c['status']}' != _status) return false;
      if (q.isNotEmpty && !('${c['number'] ?? ''} ${c['bank'] ?? ''} ${c['party'] ?? ''}').contains(q)) return false;
      final DateTime? due = DateTime.tryParse('${c['due_date']}');
      if (_from != null && (due == null || due.isBefore(_from!))) return false;
      if (_to != null && (due == null || due.isAfter(_to!))) return false;
      final double a = _d(c['amount']);
      if (minA != null && a < minA) return false;
      if (maxA != null && a > maxA) return false;
      return true;
    }).toList();
  }

  Future<void> _range(bool from) async {
    final DateTime? d = await pickDate(context, initial: (from ? _from : _to) ?? DateTime.now());
    if (d != null) setState(() => from ? _from = d : _to = d);
  }

  Widget _tile(Map<String, dynamic> c) {
    final String st = '${c['status']}';
    final Color? col = _kStatusColors[st];
    final bool pend = c['pending_sync'] == true;
    return Card(
      child: ListTile(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChequeDetailScreen(cheque: c)));
          _load();
        },
        title: Text('${c['party'] ?? '—'} · ${Fmt.money(_d(c['amount']))}${(c['ccy'] ?? '').toString().isEmpty ? '' : ' (${faNum(_d(c['ccy_amount']), dec: 2)} ${c['ccy']})'}'),
        subtitle: Text('چک ${c['number'] ?? '—'} · ${c['bank'] ?? '—'}\nسررسید: ${jalaliDate('${c['due_date']}')}'
            '${(c['endorsed_to'] ?? '') != '' ? '\nخرج به: ${c['endorsed_to']}' : ''}'),
        isThreeLine: true,
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Text(kChequeLabels[st] ?? '${c['status_label'] ?? st}', style: TextStyle(color: col, fontWeight: FontWeight.bold, fontSize: 12)),
          if (pend) const Icon(Icons.sync, size: 16),
        ]),
      ),
    );
  }

  Widget _body(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const Center(child: Text('چکی یافت نشد'));
    if (!_calendar) {
      return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 80), children: rows.map(_tile).toList());
    }
    // due calendar: grouped by Jalali due date (agenda style)
    final Map<String, List<Map<String, dynamic>>> byDay = <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> c in rows) {
      byDay.putIfAbsent('${c['due_date']}', () => <Map<String, dynamic>>[]).add(c);
    }
    final List<String> days = byDay.keys.toList()..sort();
    final List<Widget> out = <Widget>[];
    for (final String d in days) {
      final double sum = byDay[d]!.fold<double>(0, (double a, Map<String, dynamic> c) => a + _d(c['amount']));
      final DateTime? dt = DateTime.tryParse(d);
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Text('${jalaliDate(d)}${dt == null ? '' : ' · ${_when(dt)}'} — جمع ${Fmt.money(sum)}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
      ));
      out.addAll(byDay[d]!.map(_tile));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 80), children: out);
  }

  String _when(DateTime d) {
    final DateTime a = DateTime(d.year, d.month, d.day);
    final DateTime n = DateTime.now();
    final int diff = a.difference(DateTime(n.year, n.month, n.day)).inDays;
    if (diff == 0) return 'امروز';
    return diff > 0 ? '${faNum(diff, dec: 0)} روز دیگر' : '${faNum(-diff, dec: 0)} روز گذشته';
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> rows = _filtered;
    final double total = rows.fold<double>(0, (double a, Map<String, dynamic> c) => a + _d(c['amount']));
    final List<String> statuses = _tab.index == 0
        ? <String>['in_hand', 'deposited', 'cleared', 'bounced', 'endorsed', 'returned_to_payer']
        : <String>['pending', 'cleared', 'bounced', 'cancelled'];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مدیریت چک'),
          bottom: TabBar(controller: _tab, tabs: const <Tab>[Tab(text: 'دریافتی'), Tab(text: 'پرداختی')]),
          actions: <Widget>[
            IconButton(
                tooltip: _calendar ? 'نمایش فهرست' : 'تقویم سررسید',
                onPressed: () => setState(() => _calendar = !_calendar),
                icon: Icon(_calendar ? Icons.list : Icons.calendar_month_outlined)),
            IconButton(
                tooltip: 'گزارش‌ها و PDF',
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const ChequeReportScreen())),
                icon: const Icon(Icons.assessment_outlined)),
            IconButton(tooltip: 'تازه‌سازی', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(children: <Widget>[
                if (_offline || _pending > 0)
                  Container(
                    width: double.infinity,
                    color: Colors.amber.shade100,
                    padding: const EdgeInsets.all(8),
                    child: Text('${_offline ? 'آفلاین — داده‌های ذخیره‌شده نمایش داده می‌شود. ' : ''}'
                        '${_pending > 0 ? '${faNum(_pending, dec: 0)} تغییر وضعیت در صف ارسال' : ''}'),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: TextField(
                    controller: _q,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'شماره چک، بانک یا طرف حساب', isDense: true),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(
                  height: 48,
                  child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), children: <Widget>[
                    Padding(
                        padding: const EdgeInsets.all(4),
                        child: ChoiceChip(label: const Text('همه'), selected: _status.isEmpty, onSelected: (_) => setState(() => _status = ''))),
                    for (final String s in statuses)
                      Padding(
                          padding: const EdgeInsets.all(4),
                          child: ChoiceChip(
                              label: Text(kChequeLabels[s] ?? s), selected: _status == s, onSelected: (_) => setState(() => _status = _status == s ? '' : s))),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: <Widget>[
                    Expanded(child: OutlinedButton(onPressed: () => _range(true), child: Text(_from == null ? 'از تاریخ' : jalaliDateFromDt(_from!)))),
                    const SizedBox(width: 6),
                    Expanded(child: OutlinedButton(onPressed: () => _range(false), child: Text(_to == null ? 'تا تاریخ' : jalaliDateFromDt(_to!)))),
                    if (_from != null || _to != null)
                      IconButton(
                          onPressed: () => setState(() {
                                _from = null;
                                _to = null;
                              }),
                          icon: const Icon(Icons.clear)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                  child: Row(children: <Widget>[
                    Expanded(child: TextField(controller: _minAmt, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'حداقل مبلغ', isDense: true), onChanged: (_) => setState(() {}))),
                    const SizedBox(width: 6),
                    Expanded(child: TextField(controller: _maxAmt, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'حداکثر مبلغ', isDense: true), onChanged: (_) => setState(() {}))),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('${faNum(rows.length, dec: 0)} چک · جمع ${Fmt.money(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                Expanded(child: RefreshIndicator(onRefresh: _load, child: _body(rows))),
              ]),
      ),
    );
  }
}

class ChequeDetailScreen extends StatefulWidget {
  final Map<String, dynamic> cheque;
  const ChequeDetailScreen({super.key, required this.cheque});
  @override
  State<ChequeDetailScreen> createState() => _ChequeDetailScreenState();
}

class _ChequeDetailScreenState extends State<ChequeDetailScreen> {
  late Map<String, dynamic> _c = widget.cheque;
  List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  bool _offline = false;
  bool _pending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await ChequeStore.flush();
    try {
      final Map<String, dynamic> r = await StockApi.call('cheques.get', <String, dynamic>{'id': _d(widget.cheque['id']).toInt()});
      if (r['cheque'] is Map) _c = Map<String, dynamic>.from(r['cheque'] as Map);
      _events = ReturnsHelp.maps(r['events']);
      _offline = false;
    } on StockApiException {
      _offline = true;
    }
    final List<Map<String, dynamic>> ops = await ChequeStore.pendingOps();
    final List<Map<String, dynamic>> ov = ChequeStore.overlay(<Map<String, dynamic>>[_c], ops);
    _c = ov.first;
    _pending = ops.any((Map<String, dynamic> o) => _d(o['id']).toInt() == _d(_c['id']).toInt());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<String> next = (_c['next'] is List) ? List<String>.from((_c['next'] as List).map((dynamic e) => '$e')) : <String>[];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text('چک ${_c['number'] ?? ''}')),
        body: ListView(padding: const EdgeInsets.all(12), children: <Widget>[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: <Widget>[
                infoRow('نوع', _c['direction'] == 'received' ? 'دریافتی' : 'پرداختی'),
                infoRow('طرف حساب', '${_c['party'] ?? '—'}'),
                infoRow('مبلغ', '${Fmt.money(_d(_c['amount']))}'),
                if ((_c['ccy'] ?? '').toString().isNotEmpty) infoRow('مبلغ ارزی / نرخ', '${faNum(_d(_c['ccy_amount']), dec: 2)} ${_c['ccy']} × ${Fmt.money(_d(_c['fx_rate']))}'),
                infoRow('بانک', '${_c['bank'] ?? '—'}'),
                infoRow('سررسید', jalaliDate('${_c['due_date']}')),
                infoRow('وضعیت', kChequeLabels['${_c['status']}'] ?? '${_c['status_label'] ?? _c['status']}', valueColor: _kStatusColors['${_c['status']}']),
                if ((_c['endorsed_to'] ?? '') != '') infoRow('خرج‌شده به', '${_c['endorsed_to']}'),
                if (_c['reinstated'] == true) infoRow('برگشت', 'مبلغ دوباره به‌عنوان مطالبه/بدهی باز شده است'),
              ]),
            ),
          ),
          if (_offline || _pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(_pending ? 'تغییر وضعیت این چک در صف ارسال است.' : 'آفلاین — تاریخچه در دسترس نیست.', style: const TextStyle(color: Colors.orange)),
            ),
          if (next.isNotEmpty && !_pending)
            Wrap(spacing: 8, children: <Widget>[
              for (final String t in next)
                FilledButton.tonal(
                  onPressed: () async {
                    if (await runChequeTransition(context, _c, t)) _load();
                  },
                  child: Text(kChequeActionLabels[t] ?? t),
                ),
            ]),
          sectionTitle(context, 'تاریخچهٔ وضعیت'),
          if (_events.isEmpty) const Text('—'),
          for (final Map<String, dynamic> e in _events)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              ListTile(
                dense: true,
                leading: const Icon(Icons.history, size: 18),
                title: Text('${kChequeLabels['${e['to_status']}'] ?? e['to_label'] ?? e['to_status']}'),
                subtitle: Text('${jalaliDate('${e['event_date']}')}${(e['note'] ?? '') != '' ? ' · ${e['note']}' : ''}'),
              ),
              if (_d(e['id']).toInt() > 0)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 48),
                  child: VoucherLinkButton(sourceType: 'cheque_ev', sourceId: '${_d(e['id']).toInt()}'),
                ),
            ]),
        ]),
      ),
    );
  }
}
