// S26.T26.2 — نرخ روزانه ارز: انتخاب ارز، فهرست نرخ‌ها، ثبت نرخ با تاریخ میلادی/شمسی نمایشی، حذف.
// فقط پلن ارزی (FeatureGate 'fx.rates' در main.dart).
import 'package:flutter/material.dart';

import 'fx_local.dart';
import 'utils.dart';
import 'warehouse_ui.dart'; // StockApi و StockApiException
import 'widgets.dart';

class FxRatesScreen extends StatefulWidget {
  const FxRatesScreen({super.key});

  @override
  State<FxRatesScreen> createState() => _FxRatesScreenState();
}

class _FxRatesScreenState extends State<FxRatesScreen> {
  List<Map<String, dynamic>> _currencies = <Map<String, dynamic>>[]; // فعال و غیرپایه
  List<Map<String, dynamic>> _rates = <Map<String, dynamic>>[];
  String? _ccy;
  bool _loading = true;
  bool _offline = false;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    setState(() {
      _loading = true;
      _notice = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('fx.currencies.list');
      final List<Map<String, dynamic>> all = fxAsList(r['currencies']);
      await FxLocal.saveCurrencies(all);
      _currencies = all.where((Map<String, dynamic> c) => c['active'] == true && c['is_base'] != true).toList();
      _offline = false;
    } on StockApiException catch (e) {
      final List<Map<String, dynamic>> cached = await FxLocal.loadCurrencies();
      _currencies = cached.where((Map<String, dynamic> c) => c['active'] == true && c['is_base'] != true).toList();
      _offline = e.network;
      _notice = e.message;
    }
    if (!mounted) return;
    _ccy ??= _currencies.isEmpty ? null : '${_currencies.first['code']}';
    setState(() => _loading = false);
    await _loadRates();
  }

  Future<void> _loadRates() async {
    final String? ccy = _ccy;
    if (ccy == null) {
      if (mounted) setState(() => _rates = <Map<String, dynamic>>[]);
      return;
    }
    try {
      final Map<String, dynamic> r = await StockApi.call('fx.rates.list', <String, dynamic>{'ccy': ccy});
      final List<Map<String, dynamic>> rows = fxAsList(r['rates']);
      await FxLocal.saveRates(rows, ccy: ccy);
      if (!mounted) return;
      setState(() {
        _rates = rows;
        _offline = false;
      });
    } on StockApiException catch (e) {
      final List<Map<String, dynamic>> cached = await FxLocal.loadRatesCached(ccy);
      if (!mounted) return;
      setState(() {
        _rates = cached;
        _offline = e.network;
        _notice = e.message;
      });
    }
  }

  Future<void> _addRate() async {
    final String? ccy = _ccy;
    if (ccy == null) return;
    final TextEditingController rate = TextEditingController();
    final TextEditingController source = TextEditingController();
    DateTime date = DateTime.now();

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx2, void Function(void Function()) setDlg) => AlertDialog(
          title: Text('نرخ $ccy'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                dateField(ctx2, 'تاریخ نرخ', date, (DateTime d) => setDlg(() => date = d)),
                numField(rate, 'نرخ (ریال به‌ازای یک $ccy)', required: true),
                textField(source, 'منبع (اختیاری، مثل بانک یا بازار آزاد)'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ثبت')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final double? value = parseNum(rate.text);
    if (value == null || value <= 0) {
      if (mounted) snack(context, 'نرخ باید عدد مثبت باشد');
      return;
    }
    try {
      await StockApi.call('fx.rates.save', <String, dynamic>{
        'ccy': ccy,
        'rate': value,
        'rate_date': fxIsoDate(date),
        'source': source.text.trim(),
      });
      if (!mounted) return;
      snack(context, 'نرخ ثبت شد');
      await _loadRates();
    } on StockApiException catch (e) {
      if (!mounted) return;
      snack(context, e.message);
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    try {
      await StockApi.call('fx.rates.delete', <String, dynamic>{'id': row['id']});
      if (!mounted) return;
      snack(context, 'نرخ حذف شد');
      await _loadRates();
    } on StockApiException catch (e) {
      if (!mounted) return;
      snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('نرخ روزانه ارز')),
      floatingActionButton: (_ccy == null || _offline)
          ? null
          : FloatingActionButton.extended(
              onPressed: _addRate,
              icon: const Icon(Icons.add),
              label: const Text('ثبت نرخ'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _currencies.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('ابتدا از «ارزها» یک ارز فعال تعریف کنید')))
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
                    DropdownButtonFormField<String>(
                      value: _ccy,
                      decoration: const InputDecoration(labelText: 'ارز', border: OutlineInputBorder()),
                      items: <DropdownMenuItem<String>>[
                        for (final Map<String, dynamic> c in _currencies)
                          DropdownMenuItem<String>(value: '${c['code']}', child: Text('${c['name']} (${c['code']})')),
                      ],
                      onChanged: (String? v) {
                        setState(() => _ccy = v);
                        _loadRates();
                      },
                    ),
                    const SizedBox(height: 12),
                    if (_rates.isEmpty)
                      const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('نرخی برای این ارز ثبت نشده است'))),
                    for (final Map<String, dynamic> r in _rates) _tile(r),
                  ],
                ),
    );
  }

  Widget _tile(Map<String, dynamic> r) {
    final double value = double.tryParse('${r['rate']}') ?? 0;
    final String source = '${r['source'] ?? ''}';
    return Card(
      child: ListTile(
        title: Text('${faNum(value, dec: 0)} ریال'),
        subtitle: Text('${jalaliDate('${r['rate_date']}')}${source.isEmpty ? '' : ' · $source'}'),
        trailing: _offline
            ? null
            : IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'حذف', onPressed: () => _delete(r)),
      ),
    );
  }
}
