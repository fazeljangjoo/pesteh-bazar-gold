import 'dart:io';

import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'pdf_output.dart';
import 'pdf_service.dart';
import 'perms.dart';
import 'utils.dart';
import 'vouchers_links.dart';
import 'warehouse_ui.dart' show StockApi;
import 'widgets.dart';

/// S16.T16.1b — vouchers (gold): list, editor (manual), detail (status/copy/delete/print). Online via StockApi.
/// Server is the authority (balance, FY open, leaf accounts); the client only pre-checks balance for UX.
const Map<String, String> _kStatusFa = <String, String>{
  'draft': 'پیش‌نویس',
  'temporary': 'موقت',
  'final': 'قطعی',
};

List<Map<String, dynamic>> _listOf(dynamic v) {
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  if (v is List) {
    for (final dynamic x in v) {
      if (x is Map) out.add(Map<String, dynamic>.from(x));
    }
  }
  return out;
}

int _asInt(dynamic v) => v is num ? v.toInt() : (int.tryParse(v?.toString() ?? '') ?? 0);

String _isoToJ(String iso) {
  try {
    return jalaliDate(iso);
  } catch (_) {
    return iso;
  }
}

/// Jalali text (yyyy/mm/dd, any digits) -> ISO yyyy-mm-dd, or null when invalid.
String? _jToIso(String text) {
  final List<String> p = toEnDigits(text.trim()).split(RegExp(r'[/\-.]'));
  if (p.length != 3) return null;
  final int? y = int.tryParse(p[0]);
  final int? m = int.tryParse(p[1]);
  final int? d = int.tryParse(p[2]);
  if (y == null || m == null || d == null || m < 1 || m > 12 || d < 1 || d > daysInJalaliMonth(y, m)) return null;
  final DateTime g = jalaliToGregorian(y, m, d);
  return '${g.year.toString().padLeft(4, '0')}-${g.month.toString().padLeft(2, '0')}-${g.day.toString().padLeft(2, '0')}';
}

class VouchersScreen extends StatefulWidget {
  const VouchersScreen({super.key});

  @override
  State<VouchersScreen> createState() => _VouchersScreenState();
}

class _VouchersScreenState extends State<VouchersScreen> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _err;
  String _status = '';
  final TextEditingController _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final Map<String, dynamic> p = <String, dynamic>{'limit': 100};
      if (_status.isNotEmpty) p['status'] = _status;
      if (_q.text.trim().isNotEmpty) p['q'] = toEnDigits(_q.text.trim());
      final Map<String, dynamic> r = await StockApi.call('vouchers.list', p);
      _rows = _listOf(r['items']);
      _err = null;
      await VoucherCache.saveHeads(_rows); // T16.7 offline copy
    } catch (e) {
      final List<Map<String, dynamic>> cached = await VoucherCache.heads(status: _status, q: _q.text); // T16.7
      if (cached.isNotEmpty) {
        _rows = cached;
        _err = null;
        if (mounted) snack(context, 'آفلاین: نمایش آخرین اسناد همگام‌شده');
      } else {
        _err = e.toString();
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(int id) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VoucherDetailScreen(id: id)));
    if (mounted) _load();
  }

  Future<void> _new() async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const VoucherEditorScreen()));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final bool canEdit = StaffPerms.I.can('accounting.edit');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('اسناد حسابداری')),
        floatingActionButton: canEdit ? FloatingActionButton(onPressed: _new, child: const Icon(Icons.add)) : null,
        body: Column(children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _q,
                  decoration: const InputDecoration(labelText: 'جستجو (شماره یا شرح)', prefixIcon: Icon(Icons.search)),
                  onSubmitted: (_) => _load(),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _status,
                items: <DropdownMenuItem<String>>[
                  const DropdownMenuItem<String>(value: '', child: Text('همه')),
                  for (final MapEntry<String, String> e in _kStatusFa.entries) DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                ],
                onChanged: (String? v) {
                  _status = v ?? '';
                  _load();
                },
              ),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _err != null
                    ? Center(child: Text(_err!))
                    : _rows.isEmpty
                        ? const Center(child: Text('سندی یافت نشد'))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _rows.length,
                              separatorBuilder: (BuildContext c, int i) => const Divider(height: 1),
                              itemBuilder: (BuildContext c, int i) {
                                final Map<String, dynamic> r = _rows[i];
                                final String no = r['number'] == null ? 'بدون شماره' : faNum(_asInt(r['number']), dec: 0);
                                final String auto = r['source_type'] == 'manual' ? '' : ' · خودکار';
                                return ListTile(
                                  title: Text('سند $no — ${_isoToJ(r['date'].toString())}'),
                                  subtitle: Text('${r['description'] ?? ''}\n${_kStatusFa[r['status']] ?? r['status']}$auto'),
                                  isThreeLine: true,
                                  trailing: Text('${Fmt.money(_asInt(r['total']))}'),
                                  onTap: () => _open(_asInt(r['id'])),
                                );
                              },
                            ),
                          ),
          ),
        ]),
      ),
    );
  }
}

/// Manual voucher editor. `initial` = server payload {voucher, lines} when editing.
class VoucherEditorScreen extends StatefulWidget {
  const VoucherEditorScreen({super.key, this.initial});
  final Map<String, dynamic>? initial;

  @override
  State<VoucherEditorScreen> createState() => _VoucherEditorScreenState();
}

class _LineCtl {
  _LineCtl({this.accountId = 0, String debit = '', String credit = '', String desc = '', this.tafsiliId = 0, this.costCenterId = 0})
      : debit = TextEditingController(text: debit),
        credit = TextEditingController(text: credit),
        desc = TextEditingController(text: desc);
  int accountId;
  int tafsiliId;
  int costCenterId;
  final TextEditingController debit;
  final TextEditingController credit;
  final TextEditingController desc;
  void dispose() {
    debit.dispose();
    credit.dispose();
    desc.dispose();
  }
}

class _VoucherEditorScreenState extends State<VoucherEditorScreen> {
  final TextEditingController _date = TextEditingController();
  final TextEditingController _desc = TextEditingController();
  final List<_LineCtl> _lines = <_LineCtl>[];
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _saving = false;
  int _id = 0;
  String _status = 'draft';

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? ini = widget.initial;
    if (ini != null && ini['voucher'] is Map) {
      final Map<String, dynamic> v = Map<String, dynamic>.from(ini['voucher'] as Map);
      _id = _asInt(v['id']);
      _status = v['status'].toString();
      _date.text = _isoToJ(v['date'].toString());
      _desc.text = (v['description'] ?? '').toString();
      for (final Map<String, dynamic> l in _listOf(ini['lines'])) {
        final int d = _asInt(l['debit']);
        final int c = _asInt(l['credit']);
        _lines.add(_LineCtl(
          accountId: _asInt(l['account_id']),
          debit: d > 0 ? d.toString() : '',
          credit: c > 0 ? c.toString() : '',
          desc: (l['description'] ?? '').toString(),
          tafsiliId: _asInt(l['tafsili_id']),
          costCenterId: _asInt(l['cost_center_id']),
        ));
      }
    } else {
      _date.text = jalaliDateFromDt(DateTime.now());
      _lines.add(_LineCtl());
      _lines.add(_LineCtl());
    }
    _loadAccounts();
  }

  @override
  void dispose() {
    _date.dispose();
    _desc.dispose();
    for (final _LineCtl l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    try {
      final Map<String, dynamic> r = await StockApi.call('accounts.list');
      final List<Map<String, dynamic>> all = _listOf(r['items']);
      final Set<int> parents = <int>{};
      for (final Map<String, dynamic> a in all) {
        if (a['parent_id'] != null) parents.add(_asInt(a['parent_id']));
      }
      _accounts = all.where((Map<String, dynamic> a) => a['active'] == true && _asInt(a['level']) >= 2 && !parents.contains(_asInt(a['id']))).toList();
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
    if (mounted) setState(() => _loading = false);
  }

  int _sum(bool debit) {
    int s = 0;
    for (final _LineCtl l in _lines) {
      s += int.tryParse(toEnDigits((debit ? l.debit : l.credit).text.replaceAll(',', '').trim())) ?? 0;
    }
    return s;
  }

  String _accName(int id) {
    for (final Map<String, dynamic> a in _accounts) {
      if (_asInt(a['id']) == id) return '${a['code']} — ${a['name']}';
    }
    return 'انتخاب حساب';
  }

  Future<void> _pickAccount(_LineCtl l) async {
    final TextEditingController q = TextEditingController();
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) {
          final String f = toEnDigits(q.text.trim());
          final List<Map<String, dynamic>> shown = _accounts.where((Map<String, dynamic> a) => f.isEmpty || a['code'].toString().contains(f) || a['name'].toString().contains(f)).toList();
          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('انتخاب حساب'),
              content: SizedBox(
                width: double.maxFinite,
                height: 380,
                child: Column(children: <Widget>[
                  TextField(controller: q, decoration: const InputDecoration(labelText: 'جستجوی کد یا نام'), onChanged: (String _) => set(() {})),
                  Expanded(
                    child: ListView(children: <Widget>[
                      for (final Map<String, dynamic> a in shown)
                        ListTile(dense: true, title: Text('${a['code']} — ${a['name']}'), onTap: () => Navigator.pop(ctx, _asInt(a['id']))),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        },
      ),
    );
    q.dispose();
    if (picked != null) setState(() => l.accountId = picked);
  }

  Future<void> _save(String status) async {
    final String? iso = _jToIso(_date.text);
    if (iso == null) {
      snack(context, 'تاریخ سند نامعتبر است (مثال: ۱۴۰۵/۰۱/۱۵)');
      return;
    }
    final List<Map<String, dynamic>> lines = <Map<String, dynamic>>[];
    for (final _LineCtl l in _lines) {
      final int d = int.tryParse(toEnDigits(l.debit.text.replaceAll(',', '').trim())) ?? 0;
      final int c = int.tryParse(toEnDigits(l.credit.text.replaceAll(',', '').trim())) ?? 0;
      if (l.accountId == 0 && d == 0 && c == 0) continue; // empty row
      lines.add(<String, dynamic>{
        'account_id': l.accountId,
        'debit': d,
        'credit': c,
        'description': l.desc.text.trim(),
        if (l.tafsiliId > 0) 'tafsili_id': l.tafsiliId,
        if (l.costCenterId > 0) 'cost_center_id': l.costCenterId,
      });
    }
    if (_sum(true) != _sum(false)) {
      snack(context, 'سند تراز نیست');
      return;
    }
    setState(() => _saving = true);
    try {
      await StockApi.call('vouchers.save', <String, dynamic>{
        if (_id > 0) 'id': _id,
        'date': iso,
        'description': _desc.text.trim(),
        'status': status,
        'lines': lines,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final int d = _sum(true);
    final int c = _sum(false);
    final bool balanced = d == c && d > 0;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(_id > 0 ? 'ویرایش سند' : 'سند جدید')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                TextField(controller: _date, decoration: const InputDecoration(labelText: 'تاریخ (شمسی)')),
                TextField(controller: _desc, decoration: const InputDecoration(labelText: 'شرح سند')),
                const SizedBox(height: 8),
                for (int i = 0; i < _lines.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(children: <Widget>[
                        Row(children: <Widget>[
                          Expanded(child: OutlinedButton(onPressed: () => _pickAccount(_lines[i]), child: Text(_accName(_lines[i].accountId), overflow: TextOverflow.ellipsis))),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _lines.length <= 2
                                ? null
                                : () => setState(() {
                                      _lines[i].dispose();
                                      _lines.removeAt(i);
                                    }),
                          ),
                        ]),
                        Row(children: <Widget>[
                          Expanded(child: TextField(controller: _lines[i].debit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'بدهکار'), onChanged: (String _) => setState(() {}))),
                          const SizedBox(width: 8),
                          Expanded(child: TextField(controller: _lines[i].credit, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'بستانکار'), onChanged: (String _) => setState(() {}))),
                        ]),
                        TextField(controller: _lines[i].desc, decoration: const InputDecoration(labelText: 'شرح ردیف')),
                      ]),
                    ),
                  ),
                TextButton.icon(onPressed: () => setState(() => _lines.add(_LineCtl())), icon: const Icon(Icons.add), label: const Text('افزودن ردیف')),
                const Divider(),
                Text('جمع بدهکار: ${Fmt.money(d, label: false)}   جمع بستانکار: ${Fmt.money(c, label: false)}'),
                Text(balanced ? 'تراز است' : 'تراز نیست (اختلاف ${Fmt.money((d - c).abs(), label: false)})', style: TextStyle(color: balanced ? Colors.green : Colors.red)),
                const SizedBox(height: 8),
                Row(children: <Widget>[
                  Expanded(child: OutlinedButton(onPressed: _saving || !balanced || _status != 'draft' ? null : () => _save('draft'), child: const Text('ذخیره پیش‌نویس'))),
                  const SizedBox(width: 8),
                  Expanded(child: FilledButton(onPressed: _saving || !balanced ? null : () => _save(_status == 'final' ? 'final' : 'temporary'), child: Text(_status == 'final' ? 'ذخیره' : 'ثبت موقت'))),
                ]),
              ]),
      ),
    );
  }
}

class VoucherDetailScreen extends StatefulWidget {
  const VoucherDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<VoucherDetailScreen> createState() => _VoucherDetailScreenState();
}

class _VoucherDetailScreenState extends State<VoucherDetailScreen> {
  Map<String, dynamic>? _data;
  String? _err;
  bool _busy = false;
  bool _offline = false; // T16.7: showing cached copy, actions disabled

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _data = await StockApi.call('vouchers.get', <String, dynamic>{'id': widget.id});
      _err = null;
      _offline = false;
      await VoucherCache.saveDetail(widget.id, _data!); // T16.7 offline copy
    } catch (e) {
      final Map<String, dynamic>? c = await VoucherCache.detail(widget.id); // T16.7
      if (c != null) {
        _data = c;
        _err = null;
        _offline = true;
      } else {
        _err = e.toString();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _act(String action, Map<String, dynamic> p, {bool pop = false}) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await StockApi.call(action, p);
      if (pop && mounted) {
        Navigator.pop(context);
        return;
      }
      if (action == 'vouchers.copy' && mounted) {
        final int nid = _asInt((r['voucher'] as Map)['id']);
        await Navigator.pushReplacement(context, MaterialPageRoute<void>(builder: (_) => VoucherDetailScreen(id: nid)));
        return;
      }
      _data = r;
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _confirmDelete() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف سند'),
          content: const Text('این سند حذف شود؟'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
          ],
        ),
      ),
    );
    if (ok == true) await _act('vouchers.delete', <String, dynamic>{'id': widget.id}, pop: true);
  }

  Future<void> _print() async {
    final Map<String, dynamic>? d = _data;
    if (d == null) return;
    try {
      final Map<String, dynamic> v = Map<String, dynamic>.from(d['voucher'] as Map);
      final List<Map<String, dynamic>> lines = _listOf(d['lines']);
      final List<List<String>> rows = <List<String>>[
        for (final Map<String, dynamic> l in lines)
          <String>[
            faNum(_asInt(l['line_no']), dec: 0),
            '${l['account_code']} ${l['account_name']}',
            (l['tafsili_name'] ?? '').toString(),
            (l['description'] ?? '').toString(),
            _asInt(l['debit']) > 0 ? Fmt.money(_asInt(l['debit']), label: false) : '',
            _asInt(l['credit']) > 0 ? Fmt.money(_asInt(l['credit']), label: false) : '',
          ],
      ];
      final String no = v['number'] == null ? 'بدون شماره' : faNum(_asInt(v['number']), dec: 0);
      final File f = await PdfService.buildTableReport(
        title: 'سند حسابداری شمارهٔ $no',
        subtitle: 'تاریخ: ${_isoToJ(v['date'].toString())} — ${_kStatusFa[v['status']] ?? v['status']}',
        kv: <List<String>>[
          <String>['شرح', (v['description'] ?? '').toString()],
          <String>['جمع (ریال)', Fmt.money(_asInt(v['total']), label: false)],
        ],
        headers: <String>['ردیف', 'حساب', 'تفصیلی', 'شرح', 'بدهکار', 'بستانکار'],
        rows: rows,
        filePrefix: 'voucher',
      );
      if (mounted) await PdfOutput.show(context, f);
    } catch (e) {
      if (mounted) snack(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _data;
    final Map<String, dynamic>? v = d == null ? null : Map<String, dynamic>.from(d['voucher'] as Map);
    final bool manual = v != null && v['source_type'] == 'manual';
    final String st = v == null ? '' : v['status'].toString();
    final bool canEdit = StaffPerms.I.can('accounting.edit');
    final bool canPost = StaffPerms.I.can('accounting.post');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: Text(v == null ? 'سند' : (v['number'] == null ? 'سند (پیش‌نویس)' : 'سند ${faNum(_asInt(v['number']), dec: 0)}')), actions: <Widget>[
          IconButton(icon: const Icon(Icons.print_outlined), onPressed: d == null ? null : _print),
        ]),
        body: _err != null
            ? Center(child: Text(_err!))
            : d == null || v == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                    Text('تاریخ: ${_isoToJ(v['date'].toString())}   وضعیت: ${_kStatusFa[st] ?? st}${manual ? '' : '   (خودکار)'}'),
                    Text('شرح: ${v['description'] ?? ''}'),
                    Text('جمع: ${Fmt.money(_asInt(v['total']))}'),
                    if (_offline) const Text('آفلاین: نسخهٔ همگام‌شده (فقط مشاهده)', style: TextStyle(color: Colors.orange)),
                    const Divider(),
                    for (final Map<String, dynamic> l in _listOf(d['lines']))
                      ListTile(
                        dense: true,
                        title: Text('${l['account_code']} — ${l['account_name']}'),
                        subtitle: Text(<String>[if (l['tafsili_name'] != null) l['tafsili_name'].toString(), (l['description'] ?? '').toString()].where((String s) => s.isNotEmpty).join(' · ')),
                        trailing: Text(_asInt(l['debit']) > 0 ? 'بد ${Fmt.money(_asInt(l['debit']), label: false)}' : 'بس ${Fmt.money(_asInt(l['credit']), label: false)}'),
                      ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: _offline ? <Widget>[] : <Widget>[
                      if (canEdit)
                        OutlinedButton.icon(onPressed: _busy ? null : () => _act('vouchers.copy', <String, dynamic>{'id': widget.id}), icon: const Icon(Icons.copy), label: const Text('رونوشت سند')),
                      if (canEdit && manual && (st != 'final' || canPost))
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => VoucherEditorScreen(initial: d)));
                                  if (mounted) _load();
                                },
                          icon: const Icon(Icons.edit),
                          label: const Text('ویرایش'),
                        ),
                      if (canPost && st == 'draft')
                        FilledButton(onPressed: _busy ? null : () => _act('vouchers.set_status', <String, dynamic>{'id': widget.id, 'status': 'temporary'}), child: const Text('ثبت موقت')),
                      if (canPost && st != 'final')
                        FilledButton(onPressed: _busy ? null : () => _act('vouchers.set_status', <String, dynamic>{'id': widget.id, 'status': 'final'}), child: const Text('قطعی‌کردن')),
                      if (canPost && st == 'final')
                        OutlinedButton(onPressed: _busy ? null : () => _act('vouchers.set_status', <String, dynamic>{'id': widget.id, 'status': 'temporary'}), child: const Text('بازگشت به موقت')),
                      if (canEdit && manual && st != 'final')
                        TextButton(onPressed: _busy ? null : _confirmDelete, child: const Text('حذف')),
                    ]),
                  ]),
      ),
    );
  }
}
