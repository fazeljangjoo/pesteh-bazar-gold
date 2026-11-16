// S28.T28.1 — موجودی صندوق‌ها و حساب‌های بانکی به تفکیک ارز (فقط‌خواندنی، آنلاین).
// منبع: اکشن سرور treasury.balances (طلایی، دسترسی accounting.view).
import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'fx_local.dart';
import 'utils.dart';
import 'warehouse_ui.dart'; // StockApi و StockApiException

class TreasuryBalancesScreen extends StatefulWidget {
  const TreasuryBalancesScreen({super.key});

  @override
  State<TreasuryBalancesScreen> createState() => _TreasuryBalancesScreenState();
}

class _TreasuryBalancesScreenState extends State<TreasuryBalancesScreen> {
  List<Map<String, dynamic>> _accounts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _byCcy = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

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
      final Map<String, dynamic> r = await StockApi.call('treasury.balances');
      if (!mounted) return;
      setState(() {
        _accounts = fxAsList(r['accounts']);
        _byCcy = fxAsList(r['by_ccy']);
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.network ? 'اتصال برقرار نیست؛ این گزارش فقط آنلاین دیده می‌شود' : e.message;
        _loading = false;
      });
    }
  }

  double _d(dynamic v) => (v is num) ? v.toDouble() : (double.tryParse('$v') ?? 0);

  /// Amount text: rial accounts show the integer rial amount; foreign accounts show the foreign amount + code.
  String _amount(String ccy, double v) => ccy == 'IRR' ? '${Fmt.money(v)}' : faCcy(ccy, v, dec: 2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('موجودی صندوق و بانک'), actions: <Widget>[
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
              : _accounts.isEmpty
                  ? const Center(child: Text('صندوق یا حساب بانکی تعریف نشده است'))
                  : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
                      const Text('جمع هر ارز', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      for (final Map<String, dynamic> t in _byCcy)
                        Card(
                          child: ListTile(
                            title: Text(_amount(t['ccy'].toString(), _d(t['ccy_balance']))),
                            subtitle: t['ccy'].toString() == 'IRR'
                                ? Text('${faNum(_d(t['accounts']), dec: 0)} حساب')
                                : Text('معادل دفتری: ${Fmt.money(_d(t['rial_balance']))}  •  ${faNum(_d(t['accounts']), dec: 0)} حساب'),
                          ),
                        ),
                      const SizedBox(height: 12),
                      const Text('هر حساب', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      for (final Map<String, dynamic> a in _accounts)
                        Card(
                          child: ListTile(
                            leading: Icon(a['kind'] == 'bank' ? Icons.account_balance_outlined : Icons.payments_outlined),
                            title: Text(a['name'].toString()),
                            subtitle: Text(
                              (a['ccy'].toString() == 'IRR' ? '' : 'معادل دفتری: ${Fmt.money(_d(a['rial_balance']))}') +
                                  (((a['other_ccy_lines'] as num?) ?? 0) > 0
                                      ? '\n⚠️ ${faNum(_d(a['other_ccy_lines']), dec: 0)} ردیف سند با ارز دیگر روی این حساب ثبت شده است'
                                      : ''),
                            ),
                            trailing: Text(_amount(a['ccy'].toString(), _d(a['ccy_balance'])), textDirection: TextDirection.rtl),
                          ),
                        ),
                    ]),
    );
  }
}
