// S27c.T27b.8-UI — «مغایرت نرخ» اسناد ارزی آفلاین + ثبت سند تعدیل.
// سند اصلی دست‌نخورده می‌ماند؛ تعدیل فقط با دلیل، پیش‌نمایش اختلاف ریالی و ثبت در audit_log (سمت سرور).
// فقط پلن ارزی (FeatureGate 'fx.documents' در main.dart). همه‌چیز آنلاین است.
import 'package:flutter/material.dart';
import 'fmt.dart' show Fmt;

import 'fx_local.dart';
import 'utils.dart';
import 'warehouse_ui.dart'; // StockApi و StockApiException
import 'widgets.dart';

class FxMismatchScreen extends StatefulWidget {
  const FxMismatchScreen({super.key});

  @override
  State<FxMismatchScreen> createState() => _FxMismatchScreenState();
}

class _FxMismatchScreenState extends State<FxMismatchScreen> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
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
      final Map<String, dynamic> r = await StockApi.call('fx.rate_mismatch.list');
      if (!mounted) return;
      setState(() {
        _rows = fxAsList(r['mismatches']);
        _loading = false;
      });
    } on StockApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.network ? 'اتصال برقرار نیست؛ این فهرست فقط آنلاین دیده می‌شود' : e.message;
        _loading = false;
      });
    }
  }

  String _typeLabel(String t) => t == 'sales' ? 'فروش' : 'خرید';

  Future<void> _adjust(Map<String, dynamic> row) async {
    final TextEditingController reason = TextEditingController();
    final String docType = row['doc_type'].toString();
    final int docId = (row['doc_id'] as num).toInt();
    final double serverRate = double.tryParse(row['server_rate'].toString()) ?? 0;
    final Map<String, dynamic> pv;
    try {
      pv = await StockApi.call('fx.adjust.preview',
          <String, dynamic>{'doc_type': docType, 'doc_id': docId, 'new_rate': serverRate});
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
      reason.dispose();
      return;
    }
    if (!mounted) {
      reason.dispose();
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('سند تعدیل نرخ'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          infoRow('سند', '${_typeLabel(docType)} شماره $docId'),
          infoRow('نرخ فعلی سند', faNum(double.tryParse(pv['old_rate'].toString()) ?? 0, dec: 0)),
          infoRow('نرخ جدید (سرور)', faNum(serverRate, dec: 0)),
          infoRow('اختلاف (ریال)', faNum(double.tryParse(pv['diff_rial'].toString()) ?? 0, dec: 0)),
          const SizedBox(height: 8),
          TextField(
            controller: reason,
            decoration: const InputDecoration(labelText: 'دلیل تعدیل (حداقل ۵ نویسه)', border: OutlineInputBorder()),
            maxLength: 300,
          ),
          const Text('سند اصلی تغییر نمی‌کند؛ یک سند تعدیل ثبت می‌شود.', style: TextStyle(fontSize: 12)),
        ]),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ثبت تعدیل')),
        ],
      ),
    );
    final String why = reason.text.trim();
    reason.dispose();
    if (ok != true || !mounted) return;
    try {
      await StockApi.call('fx.adjust.apply', <String, dynamic>{
        'doc_type': docType,
        'doc_id': docId,
        'new_rate': serverRate,
        'reason': why,
      });
      if (!mounted) return;
      snack(context, 'سند تعدیل ثبت شد');
      await _load();
    } on StockApiException catch (e) {
      if (mounted) snack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مغایرت نرخ اسناد ارزی')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center)))
              : _rows.isEmpty
                  ? const Center(child: Text('مغایرتی وجود ندارد'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _rows.length,
                      separatorBuilder: (BuildContext _, int __) => const Divider(height: 1),
                      itemBuilder: (BuildContext ctx, int i) {
                        final Map<String, dynamic> r = _rows[i];
                        return ListTile(
                          title: Text('${_typeLabel(r['doc_type'].toString())} ${r['doc_id']} • ${r['ccy']} • ${jalaliDate(r['date'].toString())}'),
                          subtitle: Text(
                              'نرخ سند: ${faNum(double.tryParse(r['kept_rate'].toString()) ?? 0, dec: 0)}  •  '
                              'نرخ سرور: ${faNum(double.tryParse(r['server_rate'].toString()) ?? 0, dec: 0)}'),
                          trailing: TextButton(onPressed: () => _adjust(r), child: const Text('تعدیل')),
                        );
                      },
                    ),
    );
  }
}
