import 'package:flutter/material.dart';

import 'backup_screen.dart';
import 'cheque_ui.dart';
import 'stock_count_ui.dart';
import 'utils.dart';
import 'vouchers_ui.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S19.T19.3 — year-end wizard (gold, perm accounting.close). Steps: 1 checks (red/green, one-tap fixes) → 2 backup → 3 close → 4 opening entry of next year → 5 lock.
/// Server: `fiscal_years.list`, `fy.close_preview|close|open_next|lock`. The server refuses closing with blocking issues; the UI also keeps the button disabled.

List<Map<String, dynamic>> _wl(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

class FyWizardScreen extends StatefulWidget {
  const FyWizardScreen({super.key});

  @override
  State<FyWizardScreen> createState() => _FyWizardScreenState();
}

class _FyWizardScreenState extends State<FyWizardScreen> {
  bool _busy = true;
  String? _error;
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];
  int? _sel;
  Map<String, dynamic>? _pv;
  bool _backupOk = false;
  bool _openDone = false;

  Map<String, dynamic>? get _year {
    for (final Map<String, dynamic> y in _years) {
      if ((y['id'] as num).toInt() == _sel) return y;
    }
    return null;
  }

  String get _status => '${_year?['status'] ?? ''}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool keepSel = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('fiscal_years.list');
      _years = _wl(r['items']);
      if (!keepSel || _sel == null || _year == null) {
        // default: the earliest year that is not locked yet
        final List<Map<String, dynamic>> open = <Map<String, dynamic>>[for (final Map<String, dynamic> y in _years) if (y['status'] != 'locked') y];
        open.sort((Map<String, dynamic> a, Map<String, dynamic> b) => '${a['start_date']}'.compareTo('${b['start_date']}'));
        _sel = open.isNotEmpty ? (open.first['id'] as num).toInt() : (_years.isNotEmpty ? (_years.first['id'] as num).toInt() : null);
      }
      await _loadPreview();
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

  Future<void> _loadPreview() async {
    if (_sel == null) return;
    _pv = await StockApi.call('fy.close_preview', <String, dynamic>{'id': _sel});
  }

  Future<bool> _confirm(String title, String msg) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: Text(msg),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأیید و انجام'))],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _run(String action, {String? done}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call(action, <String, dynamic>{'id': _sel});
      if (action == 'fy.open_next') _openDone = true;
      _years = _wl(r['items']);
      await _loadPreview();
      if (!mounted) return;
      setState(() => _busy = false);
      if (done != null) snack(context, done);
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  void _go(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    if (mounted) _load();
  }

  Widget? _fixButton(String code) {
    switch (code) {
      case 'draft_vouchers':
      case 'unbalanced':
      case 'sales_unposted':
        return TextButton.icon(onPressed: () => _go(const VouchersScreen()), icon: const Icon(Icons.open_in_new, size: 16), label: const Text('رفتن به اسناد'));
      case 'stock_mismatch':
        return TextButton.icon(onPressed: () => _go(const StockCountListScreen()), icon: const Icon(Icons.open_in_new, size: 16), label: const Text('انبارگردانی'));
      case 'cheques_due':
      case 'cheque_register':
        return TextButton.icon(onPressed: () => _go(const ChequeListScreen()), icon: const Icon(Icons.open_in_new, size: 16), label: const Text('چک‌ها'));
      default:
        return null; // e.g. role_retained: fix in Accounting settings (account roles)
    }
  }

  Widget _step(int n, String title, String explain, {required bool done, required List<Widget> body, bool active = true}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? Colors.green : (active ? Colors.orange : Colors.grey)),
            const SizedBox(width: 8),
            Expanded(child: Text('$n. $title', style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 6),
          Text(explain, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 8),
          ...body,
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> block = _wl(_pv?['blocking']);
    final List<Map<String, dynamic>> warn = _wl(_pv?['warnings']);
    final Map<String, dynamic> res = Map<String, dynamic>.from((_pv?['result'] as Map?) ?? <String, dynamic>{});
    final bool open = _status == 'open';
    final bool closed = _status == 'closed' || _status == 'locked';
    final bool canClose = open && block.isEmpty && _backupOk && !_busy;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('ویزارد پایان سال', style: TextStyle(fontSize: 16)), actions: <Widget>[IconButton(tooltip: 'بازبینی', onPressed: _busy ? null : () => _load(), icon: const Icon(Icons.refresh))]),
        body: Column(children: <Widget>[
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(10), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(8), children: <Widget>[
              Row(children: <Widget>[
                const Text('سال مالی: '),
                DropdownButton<int>(
                  value: _sel,
                  items: <DropdownMenuItem<int>>[for (final Map<String, dynamic> y in _years) DropdownMenuItem<int>(value: (y['id'] as num).toInt(), child: Text('${y['name']}'))],
                  onChanged: _busy ? null : (int? v) {
                    _sel = v;
                    _backupOk = false;
                    _openDone = false;
                    _load();
                  },
                ),
                const SizedBox(width: 8),
                Text(open ? 'باز' : (_status == 'closed' ? 'بسته' : (_status == 'locked' ? 'قفل‌شده' : '')), style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              _step(1, 'بررسی مشکلات', 'پیش از بستن سال، سیستم اسناد پیش‌نویس، اسناد نامتوازن، مغایرت انبار و چک‌ها را بررسی می‌کند. موارد قرمز مانع بستن سال هستند؛ موارد نارنجی فقط هشدارند.',
                  done: closed || (_pv != null && block.isEmpty),
                  body: <Widget>[
                    if (_pv == null) const Text('در حال بررسی…'),
                    if (_pv != null && block.isEmpty && warn.isEmpty) const Row(children: <Widget>[Icon(Icons.check, color: Colors.green, size: 18), SizedBox(width: 6), Text('مشکلی یافت نشد')]),
                    for (final Map<String, dynamic> x in block) _issue(x, Colors.red, Icons.block),
                    for (final Map<String, dynamic> x in warn) _issue(x, Colors.orange, Icons.warning_amber),
                    if (_pv != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('سود/زیان سال (ریال): ${faNum(((res['net_profit'] as num?) ?? 0).toDouble(), dec: 0)}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  ]),
              _step(2, 'پشتیبان‌گیری', 'بستن سال یک سند اختتامیه می‌سازد و ثبت سند در این سال را می‌بندد. پیش از آن حتماً از اطلاعات پشتیبان بگیرید.',
                  done: closed || _backupOk,
                  body: <Widget>[
                    if (open) Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
                      OutlinedButton.icon(onPressed: () => _go(const BackupScreen()), icon: const Icon(Icons.backup_outlined), label: const Text('رفتن به پشتیبان‌گیری')),
                      FilterChip(label: const Text('پشتیبان گرفتم'), selected: _backupOk, onSelected: (bool v) => setState(() => _backupOk = v)),
                    ]),
                  ]),
              _step(3, 'بستن سال مالی', 'چه اتفاقی می‌افتد: همهٔ حساب‌های درآمد و هزینه صفر می‌شوند و سود یا زیان سال به حساب سود (زیان) انباشته منتقل می‌شود. پس از آن در این سال سندی ثبت یا ویرایش نمی‌شود. فقط آخرین سال را می‌توان دوباره باز کرد.',
                  done: closed, active: open,
                  body: <Widget>[
                    if (open) FilledButton(
                      onPressed: canClose ? () async {
                        if (await _confirm('بستن سال مالی', 'سند اختتامیه صادر و سال بسته می‌شود. ادامه می‌دهید؟')) _run('fy.close', done: 'سال بسته شد');
                      } : null,
                      child: const Text('بستن سال'),
                    ),
                    if (open && !canClose) Text(block.isNotEmpty ? 'ابتدا موارد قرمز را برطرف کنید.' : (!_backupOk ? 'ابتدا پشتیبان‌گیری را تأیید کنید.' : ''), style: const TextStyle(fontSize: 12, color: Colors.red)),
                  ]),
              _step(4, 'سند افتتاحیهٔ سال بعد', 'چه اتفاقی می‌افتد: مانده‌های ترازنامه (دارایی، بدهی، سرمایه، حساب طرف‌ها، چک‌های باز و حساب موجودی) به اول سال بعد منتقل می‌شوند و با مانده‌های پایان این سال تطبیق داده می‌شوند. اجرای دوباره، همان سند را بازنویسی می‌کند.',
                  done: _openDone, active: closed,
                  body: <Widget>[
                    if (closed) FilledButton(
                      onPressed: _busy ? null : () async {
                        if (await _confirm('سند افتتاحیه', 'سند افتتاحیهٔ سال بعد از مانده‌های پایان این سال صادر (یا بازنویسی) می‌شود.')) _run('fy.open_next', done: 'سند افتتاحیه صادر شد');
                      },
                      child: const Text('صدور سند افتتاحیه'),
                    ),
                  ]),
              _step(5, 'قفل سال (اختیاری)', 'قفل‌کردن، سال بسته‌شده را در برابر هرگونه تغییر محافظت می‌کند. بازگشایی بعداً فقط با مجوز ویژه و برای آخرین سال ممکن است.',
                  done: _status == 'locked', active: _status == 'closed',
                  body: <Widget>[
                    if (_status == 'closed') OutlinedButton(
                      onPressed: _busy ? null : () async {
                        if (await _confirm('قفل سال', 'سال مالی قفل می‌شود.')) _run('fy.lock', done: 'سال قفل شد');
                      },
                      child: const Text('قفل سال'),
                    ),
                  ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _issue(Map<String, dynamic> x, Color c, IconData icon) {
    final Widget? fix = _fixButton('${x['code']}');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Icon(icon, color: c, size: 18),
        const SizedBox(width: 6),
        Expanded(child: Text('${x['message']}', style: TextStyle(color: c))),
        if (fix != null) fix,
      ]),
    );
  }
}
