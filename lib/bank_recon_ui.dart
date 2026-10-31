import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fmt.dart' show Fmt;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S31.T31.1b — bank reconciliation screen (online only, gold). Server actions: bank_recon.list|report|import|auto|match|unmatch|ignore.
/// Sign convention: amount > 0 = deposit, amount < 0 = withdrawal (integer rial). CSV is pasted as text (no file picker package).

String _m(dynamic v) => Fmt.money(((v is num) ? v : num.tryParse('${v ?? 0}') ?? 0).toDouble(), label: false);

String _n(num v) => faNum(v, dec: 0);

const Map<String, String> kBrStatus = <String, String>{'open': 'باز', 'matched': 'تطبیق‌شده', 'diff': 'اختلاف', 'ignored': 'نادیده'};

class BankReconScreen extends StatefulWidget {
  const BankReconScreen({super.key});

  @override
  State<BankReconScreen> createState() => _BankReconScreenState();
}

class _BankReconScreenState extends State<BankReconScreen> {
  List<Map<String, dynamic>> _banks = <Map<String, dynamic>>[];
  String? _uid;
  String _status = 'open';
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _rep;
  List<Map<String, dynamic>> _lines = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() => _loading = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('entity.list', <String, dynamic>{'entity': 'bank_accounts', 'limit': 200});
      if (!mounted) return;
      _banks = <Map<String, dynamic>>[for (final dynamic e in (r['items'] as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];
      if (_banks.isNotEmpty) _uid = '${_banks.first['uid']}';
    } on StockApiException catch (e) {
      if (!mounted) return;
      _error = e.message;
    }
    if (_uid != null) {
      await _load();
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    if (_uid == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> rep = await StockApi.call('bank_recon.report', <String, dynamic>{'bank_uid': _uid});
      final Map<String, dynamic> l = await StockApi.call('bank_recon.list', <String, dynamic>{'bank_uid': _uid, 'status': _status, 'limit': 300});
      if (!mounted) return;
      setState(() {
        _rep = rep;
        _lines = <Map<String, dynamic>>[for (final dynamic e in (l['lines'] as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];
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

  Future<Map<String, dynamic>?> _act(String action, Map<String, dynamic> p) async {
    try {
      final Map<String, dynamic> r = await StockApi.call(action, <String, dynamic>{'bank_uid': _uid, ...p});
      return r;
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
      return null;
    }
  }

  Future<void> _import() async {
    final TextEditingController c = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('ورود صورت‌حساب (CSV)'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            const Text('سطر اول عنوان ستون‌ها: تاریخ، شرح، واریز، برداشت (یا مبلغ)، مرجع. مبالغ به ریال.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: c, maxLines: 8, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'متن CSV را اینجا بچسبانید')),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text != null) c.text = d!.text!;
                },
                icon: const Icon(Icons.paste),
                label: const Text('چسباندن از کلیپ‌بورد'),
              ),
            ),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ورود')),
        ],
      ),
    );
    if (go != true || c.text.trim().isEmpty) return;
    final Map<String, dynamic>? r = await _act('bank_recon.import', <String, dynamic>{'csv': c.text});
    if (r == null || !mounted) return;
    final int errs = (r['errors'] as List<dynamic>? ?? <dynamic>[]).length;
    snack(context, 'اضافه شد: ${_n((r['added'] as num?) ?? 0)} · تکراری: ${_n((r['duplicates'] as num?) ?? 0)}${errs > 0 ? ' · ردیف خطادار: ${_n(errs)}' : ''}');
    _load();
  }

  Future<void> _auto() async {
    final Map<String, dynamic>? r = await _act('bank_recon.auto', <String, dynamic>{});
    if (r == null || !mounted) return;
    snack(context, 'تطبیق شد: ${_n((r['matched'] as num?) ?? 0)} · مبهم: ${_n((r['ambiguous'] as num?) ?? 0)}');
    _load();
  }

  Future<void> _manual(Map<String, dynamic> line) async {
    final List<dynamic> book = (_rep?['unmatched_book'] as List<dynamic>? ?? <dynamic>[]);
    if (book.isEmpty) {
      snack(context, 'ردیف سند تطبیق‌نشده‌ای وجود ندارد');
      return;
    }
    final int? vl = await showModalBottomSheet<int>(
      context: context,
      builder: (BuildContext ctx) => ListView(
        children: <Widget>[
          for (final dynamic e in book)
            ListTile(
              title: Text('${_m((e as Map)['net'])}  ·  ${e['date'] ?? ''}'),
              subtitle: Text('سند ${e['number'] ?? '—'}  ${e['description'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, (e['id'] as num).toInt()),
            ),
        ],
      ),
    );
    if (vl == null) return;
    final Map<String, dynamic>? r = await _act('bank_recon.match', <String, dynamic>{'id': line['id'], 'voucher_line_id': vl});
    if (r == null || !mounted) return;
    if (r['status'] == 'diff') snack(context, 'تطبیق شد با اختلاف ${_m(r['diff'])}');
    _load();
  }

  Future<void> _lineMenu(Map<String, dynamic> line) async {
    final String st = '${line['status']}';
    final String? pick = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          if (st == 'open') ListTile(leading: const Icon(Icons.link), title: const Text('تطبیق دستی با ردیف سند'), onTap: () => Navigator.pop(ctx, 'match')),
          if (st == 'open') ListTile(leading: const Icon(Icons.visibility_off_outlined), title: const Text('نادیده گرفتن'), onTap: () => Navigator.pop(ctx, 'ignore')),
          if (st != 'open') ListTile(leading: const Icon(Icons.link_off), title: const Text('لغو تطبیق / بازگردانی'), onTap: () => Navigator.pop(ctx, 'unmatch')),
        ]),
      ),
    );
    if (pick == 'match') {
      await _manual(line);
    } else if (pick == 'ignore') {
      if (await _act('bank_recon.ignore', <String, dynamic>{'id': line['id']}) != null) _load();
    } else if (pick == 'unmatch') {
      if (await _act('bank_recon.unmatch', <String, dynamic>{'id': line['id']}) != null) _load();
    }
  }

  Widget _summary() {
    final Map<String, dynamic>? r = _rep;
    if (r == null) return const SizedBox.shrink();
    final Map<String, dynamic> c = Map<String, dynamic>.from(r['counts'] as Map? ?? <String, dynamic>{});
    final num diff = (r['difference'] as num?) ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('مانده دفتر: ${_m(r['book_balance'])}'),
          Text('مانده صورت‌حساب: ${_m(r['statement_balance'])}'),
          Text('اختلاف: ${_m(diff)}', style: TextStyle(fontWeight: FontWeight.bold, color: diff == 0 ? Colors.green : Colors.red)),
          const SizedBox(height: 4),
          Text('باز ${_n((c['open'] as num?) ?? 0)} · تطبیق ${_n((c['matched'] as num?) ?? 0)} · اختلاف ${_n((c['diff'] as num?) ?? 0)} · نادیده ${_n((c['ignored'] as num?) ?? 0)}', style: const TextStyle(fontSize: 12)),
          Text('ردیف سند تطبیق‌نشده: ${_m(r['unmatched_book_total'])}', style: const TextStyle(fontSize: 12)),
          if (r['bank'] is Map && (r['bank'] as Map)['has_tafsili'] == false) const Text('این حساب هنوز تفصیلی ندارد؛ ابتدا همگام‌سازی تفصیلی‌ها را بزنید.', style: TextStyle(fontSize: 12, color: Colors.red)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('مغایرت‌گیری بانکی'), actions: <Widget>[
          IconButton(tooltip: 'ورود صورت‌حساب', onPressed: _uid == null ? null : _import, icon: const Icon(Icons.upload_file)),
          IconButton(tooltip: 'تطبیق خودکار', onPressed: _uid == null ? null : _auto, icon: const Icon(Icons.auto_fix_high)),
        ]),
        body: _error != null && _banks.isEmpty
            ? Center(child: Text(_error!))
            : _banks.isEmpty && !_loading
                ? const Center(child: Text('حساب بانکی تعریف نشده است'))
                : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                    DropdownButtonFormField<String>(
                      value: _uid,
                      decoration: const InputDecoration(labelText: 'حساب بانکی', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<String>>[for (final Map<String, dynamic> b in _banks) DropdownMenuItem<String>(value: '${b['uid']}', child: Text('${b['name']}'))],
                      onChanged: (String? v) {
                        setState(() => _uid = v);
                        _load();
                      },
                    ),
                    const SizedBox(height: 8),
                    if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
                    _summary(),
                    Wrap(spacing: 6, children: <Widget>[
                      for (final MapEntry<String, String> e in kBrStatus.entries)
                        ChoiceChip(
                          label: Text(e.value),
                          selected: _status == e.key,
                          onSelected: (_) {
                            setState(() => _status = e.key);
                            _load();
                          },
                        ),
                    ]),
                    if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                    for (final Map<String, dynamic> l in _lines)
                      ListTile(
                        dense: true,
                        title: Text(_m(l['amount']), style: TextStyle(color: ((l['amount'] as num?) ?? 0) < 0 ? Colors.red : Colors.green)),
                        subtitle: Text('${l['date'] ?? ''}  ${l['description'] ?? ''}${(l['diff'] as num? ?? 0) != 0 ? '  · اختلاف ${_m(l['diff'])}' : ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        trailing: Text(kBrStatus['${l['status']}'] ?? '${l['status']}', style: const TextStyle(fontSize: 12)),
                        onTap: () => _lineMenu(l),
                      ),
                    if (!_loading && _lines.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('ردیفی نیست'))),
                  ]),
      ),
    );
  }
}
