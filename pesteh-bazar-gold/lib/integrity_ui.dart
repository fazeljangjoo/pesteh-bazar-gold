import 'package:flutter/material.dart';

import 'warehouse_ui.dart' show StockApi, StockApiException;

/// S16.T16.6b — «کنترل صحت حسابداری» (gold). Calls accounting.integrity (read-only) and accounting.rebuild (re-post all documents).
class IntegrityScreen extends StatefulWidget {
  const IntegrityScreen({super.key});

  @override
  State<IntegrityScreen> createState() => _IntegrityScreenState();
}

class _IntegrityScreenState extends State<IntegrityScreen> {
  Map<String, dynamic>? _report;
  bool _busy = false;
  String? _err;
  String? _info;

  static const Map<String, String> _titles = <String, String>{
    'voucher_unbalanced': 'سند نامتوازن',
    'global_unbalanced': 'جمع کل بدهکار و بستانکار برابر نیست',
    'voucher_missing': 'سند خودکار ثبت نشده',
    'voucher_mismatch': 'مبلغ سند با سند مبدأ نمی‌خواند',
    'voucher_orphan': 'سند خودکار بدون سند مبدأ',
    'loader_error': 'خطا در خواندن سند مبدأ',
    'inventory_valuation': 'موجودی دفتری با ارزش انبار نمی‌خواند',
    'cheque_register': 'حساب چک با دفتر چک نمی‌خواند',
    'ar_ap_no_tafsili': 'ردیف بدون تفصیلی طرف‌حساب',
  };

  @override
  void initState() {
    super.initState();
    _run();
  }

  String _msg(Object e) => e is StockApiException ? e.message : 'خطا در ارتباط با سرور';

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('accounting.integrity');
      if (!mounted) return;
      setState(() {
        _report = r;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = _msg(e);
        _busy = false;
      });
    }
  }

  Future<void> _rebuild() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('بازسازی اسناد خودکار'),
        content: const Text('همهٔ اسناد خودکار از روی اسناد مبدأ دوباره ساخته می‌شوند (شمارهٔ اسناد تغییر نمی‌کند). ادامه می‌دهید؟'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('بازسازی')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _busy = true;
      _err = null;
      _info = null;
    });
    try {
      final Map<String, dynamic> r = await StockApi.call('accounting.rebuild');
      final dynamic sk = r['skipped'];
      final int skipped = sk is List ? sk.length : 0;
      _info = 'بازسازی انجام شد: ${r['posted']} سند، ${r['orphans_removed']} سند یتیم حذف شد' + (skipped > 0 ? '، $skipped مورد رد شد (سال مالی قفل یا خطا)' : '');
    } catch (e) {
      _err = _msg(e);
    }
    if (!mounted) return;
    await _run();
  }

  List<Map<String, dynamic>> _issues() {
    final dynamic raw = _report == null ? null : _report!['issues'];
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (raw is List) {
      for (final dynamic x in raw) {
        if (x is Map) out.add(Map<String, dynamic>.from(x));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? r = _report;
    final List<Map<String, dynamic>> issues = _issues();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('کنترل صحت حسابداری'),
          actions: <Widget>[
            IconButton(tooltip: 'کنترل دوباره', icon: const Icon(Icons.refresh), onPressed: _busy ? null : _run),
          ],
        ),
        body: _busy
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: <Widget>[
                  if (_err != null) Card(color: Colors.red.shade50, child: Padding(padding: const EdgeInsets.all(12), child: Text(_err!))),
                  if (_info != null) Card(color: Colors.green.shade50, child: Padding(padding: const EdgeInsets.all(12), child: Text(_info!))),
                  if (r != null) ...<Widget>[
                    Card(
                      child: ListTile(
                        leading: Icon(r['clean'] == true ? Icons.verified : Icons.error_outline, color: r['clean'] == true ? Colors.green : Colors.red),
                        title: Text(r['clean'] == true ? 'حسابداری سالم است' : 'مشکل در حسابداری پیدا شد'),
                        subtitle: Text('${r['documents']} سند مبدأ · ${r['vouchers']} سند حسابداری · ${r['errors']} خطا · ${r['warnings']} هشدار'),
                      ),
                    ),
                    for (final Map<String, dynamic> i in issues)
                      Card(
                        child: ListTile(
                          leading: Icon(i['level'] == 'error' ? Icons.error : Icons.warning_amber, color: i['level'] == 'error' ? Colors.red : Colors.orange),
                          title: Text(_titles[i['code']] ?? (i['code'] ?? '').toString()),
                          subtitle: Text(((i['source'] ?? '').toString().isEmpty ? '' : '${i['source']}\n') + (i['detail'] ?? '').toString()),
                          isThreeLine: (i['source'] ?? '').toString().isNotEmpty,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text('بررسی‌نشده: ${(r['not_checked'] is List) ? (r['not_checked'] as List).join('، ') : ''}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(onPressed: _busy ? null : _rebuild, icon: const Icon(Icons.build_circle_outlined), label: const Text('بازسازی اسناد خودکار')),
                ],
              ),
      ),
    );
  }
}
