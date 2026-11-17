// S26.T26.2 — ارزها: فهرست، افزودن ارز جدید، ویرایش نام/نماد/اعشار، غیرفعال‌سازی.
// فقط پلن ارزی (منو در main.dart با FeatureGate 'fx.rates').
import 'package:flutter/material.dart';

import 'fx_local.dart';
import 'utils.dart';
import 'warehouse_ui.dart'; // StockApi و StockApiException (کانال ارتباط مشترک با سرور)
import 'widgets.dart';

class FxCurrenciesScreen extends StatefulWidget {
  const FxCurrenciesScreen({super.key});

  @override
  State<FxCurrenciesScreen> createState() => _FxCurrenciesScreenState();
}

class _FxCurrenciesScreenState extends State<FxCurrenciesScreen> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _offline = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _notice = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('fx.currencies.list');
      final List<Map<String, dynamic>> list = fxAsList(r['currencies']);
      await FxLocal.saveCurrencies(list);
      if (!mounted) return;
      setState(() {
        _items = list;
        _offline = false;
        _loading = false;
      });
    } on StockApiException catch (e) {
      final List<Map<String, dynamic>> cached = await FxLocal.loadCurrencies();
      if (!mounted) return;
      setState(() {
        _items = cached;
        _offline = e.network;
        _notice = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _edit({Map<String, dynamic>? current}) async {
    final bool isNew = current == null;
    final Map<String, dynamic> cur = current ?? <String, dynamic>{};
    final TextEditingController code = TextEditingController();
    final TextEditingController name = TextEditingController(text: isNew ? '' : '${cur['name']}');
    final TextEditingController symbol = TextEditingController(text: isNew ? '' : '${cur['symbol'] ?? ''}');
    final TextEditingController dec = TextEditingController(text: isNew ? '2' : '${cur['decimals']}');

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(isNew ? 'ارز جدید' : 'ویرایش ${cur['code']}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (isNew) textField(code, 'کد ارز (۲ تا ۸ حرف لاتین، مثل CAD)', required: true),
              textField(name, 'نام ارز', required: true),
              textField(symbol, 'نماد (اختیاری)'),
              numField(dec, 'تعداد اعشار (۰ تا ۴)', required: true, max: 4),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ذخیره')),
        ],
      ),
    );
    if (ok != true) return;

    final Map<String, dynamic> payload = <String, dynamic>{
      if (!isNew) 'id': cur['id'],
      if (isNew) 'code': code.text.trim().toUpperCase(),
      'name': name.text.trim(),
      'symbol': symbol.text.trim(),
      'decimals': int.tryParse(dec.text.trim()) ?? 2,
    };
    try {
      await StockApi.call('fx.currencies.save', payload);
      if (!mounted) return;
      snack(context, 'ذخیره شد');
      await _load();
    } on StockApiException catch (e) {
      if (!mounted) return;
      snack(context, e.message);
    }
  }

  Future<void> _deactivate(Map<String, dynamic> c) async {
    try {
      await StockApi.call('fx.currencies.deactivate', <String, dynamic>{'id': c['id']});
      if (!mounted) return;
      snack(context, '${c['code']} غیرفعال شد');
      await _load();
    } on StockApiException catch (e) {
      if (!mounted) return;
      snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ارزها')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _offline ? null : () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('ارز جدید'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
              children: <Widget>[
                if (_notice != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_offline ? 'آفلاین: نمایش آخرین داده ذخیره‌شده (فقط خواندنی)' : _notice!),
                  ),
                if (_items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('ارزی ثبت نشده است'))),
                for (final Map<String, dynamic> c in _items) _tile(c),
              ],
            ),
    );
  }

  Widget _tile(Map<String, dynamic> c) {
    final bool isBase = c['is_base'] == true;
    final bool active = c['active'] == true;
    final String symbol = '${c['symbol'] ?? ''}';
    final String decimals = faNum(int.tryParse('${c['decimals']}') ?? 2, dec: 0);
    return Card(
      child: ListTile(
        title: Text('${c['name']} (${c['code']})'),
        subtitle: Text(
          'نماد: ${symbol.isEmpty ? '—' : symbol} · اعشار: $decimals'
          '${isBase ? ' · ارز پایه' : ''}${active ? '' : ' · غیرفعال'}',
        ),
        trailing: (isBase || _offline)
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(icon: const Icon(Icons.edit_outlined), tooltip: 'ویرایش', onPressed: () => _edit(current: c)),
                  if (active)
                    IconButton(icon: const Icon(Icons.block_outlined), tooltip: 'غیرفعال‌سازی', onPressed: () => _deactivate(c)),
                ],
              ),
      ),
    );
  }
}
