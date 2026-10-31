import 'package:flutter/material.dart';

import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S19.T19.2 — year-end screen (gold, perm accounting.close): per fiscal year preview → close (closing voucher) → lock / reopen.
/// Server: `fiscal_years.list`, `fy.close_preview|close|lock|reopen`. `fy.open_next|open_undo` = opening entry of the next year (T19.2b).

List<Map<String, dynamic>> _fl(dynamic v) => <Map<String, dynamic>>[for (final dynamic e in (v as List<dynamic>? ?? <dynamic>[])) Map<String, dynamic>.from(e as Map)];

class FyCloseScreen extends StatefulWidget {
  const FyCloseScreen({super.key});

  @override
  State<FyCloseScreen> createState() => _FyCloseScreenState();
}

class _FyCloseScreenState extends State<FyCloseScreen> {
  bool _busy = true;
  String? _error;
  List<Map<String, dynamic>> _years = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('fiscal_years.list');
      if (!mounted) return;
      setState(() {
        _years = _fl(r['items']);
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

  Future<bool> _confirm(String msg) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text(msg),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ادامه'))],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _act(String action, int id) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await StockApi.call(action, <String, dynamic>{'id': id});
      if (!mounted) return;
      setState(() {
        _years = _fl(r['items']);
        _busy = false;
      });
      snack(context, 'انجام شد');
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      snack(context, e.message);
    }
  }

  Future<void> _preview(int id) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await StockApi.call('fy.close_preview', <String, dynamic>{'id': id});
      if (!mounted) return;
      setState(() => _busy = false);
      final List<Map<String, dynamic>> b = _fl(r['blocking']);
      final List<Map<String, dynamic>> w = _fl(r['warnings']);
      final Map<String, dynamic> res = Map<String, dynamic>.from((r['result'] as Map?) ?? <String, dynamic>{});
      final String body = <String>[
        'سود/زیان سال (ریال): ${faNum(((res['net_profit'] as num?) ?? 0).toDouble(), dec: 0)}',
        if (b.isEmpty && w.isEmpty) 'مشکلی یافت نشد.',
        for (final Map<String, dynamic> x in b) '⛔ ${x['message']}',
        for (final Map<String, dynamic> x in w) '⚠ ${x['message']}',
      ].join('\n');
      await showDialog<void>(
        context: context,
        builder: (BuildContext c) => Directionality(textDirection: TextDirection.rtl, child: AlertDialog(title: const Text('پیش‌نمایش بستن سال'), content: Text(body), actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c), child: const Text('بستن'))])),
      );
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('پایان سال مالی', style: TextStyle(fontSize: 16)), actions: <Widget>[IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
        body: Column(children: <Widget>[
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
          Expanded(
            child: ListView(children: <Widget>[
              for (final Map<String, dynamic> y in _years)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text('${y['name']}  ·  ${y['status'] == 'open' ? 'باز' : (y['status'] == 'closed' ? 'بسته' : 'قفل‌شده')}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, children: <Widget>[
                        OutlinedButton(onPressed: _busy ? null : () => _preview((y['id'] as num).toInt()), child: const Text('پیش‌نمایش')),
                        if (y['status'] == 'open')
                          FilledButton(
                            onPressed: _busy ? null : () async {
                              if (await _confirm('سند اختتامیه صادر و سال بسته می‌شود. ادامه می‌دهید؟')) _act('fy.close', (y['id'] as num).toInt());
                            },
                            child: const Text('بستن سال'),
                          ),
                        if (y['status'] == 'closed')
                          OutlinedButton(
                            onPressed: _busy ? null : () async {
                              if (await _confirm('سال قفل می‌شود.')) _act('fy.lock', (y['id'] as num).toInt());
                            },
                            child: const Text('قفل'),
                          ),
                        if (y['status'] != 'open')
                          OutlinedButton(
                            onPressed: _busy ? null : () async {
                              if (await _confirm('سند افتتاحیهٔ سال بعد از مانده‌های پایان این سال صادر (یا بازنویسی) می‌شود.')) _act('fy.open_next', (y['id'] as num).toInt());
                            },
                            child: const Text('افتتاحیه سال بعد'),
                          ),
                        if (y['status'] != 'open')
                          OutlinedButton(
                            onPressed: _busy ? null : () async {
                              if (await _confirm('سند افتتاحیهٔ سال بعد حذف می‌شود (لازم قبل از بازگشایی).')) _act('fy.open_undo', (y['id'] as num).toInt());
                            },
                            child: const Text('حذف افتتاحیه'),
                          ),
                        if (y['status'] != 'open')
                          OutlinedButton(
                            onPressed: _busy ? null : () async {
                              if (await _confirm('سند اختتامیه حذف و سال بازگشایی می‌شود (فقط آخرین سال).')) _act('fy.reopen', (y['id'] as num).toInt());
                            },
                            child: const Text('بازگشایی'),
                          ),
                      ]),
                    ]),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
