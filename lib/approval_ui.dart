import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt, MoneyField;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S35.T35.9e — تأیید دوم مالک برای اسناد کارمندان بالاتر از سقف مبلغ (آنلاین؛ سرور تصمیم می‌گیرد).
/// سند «در انتظار تأیید» اثر انباری/مالی عادی دارد؛ این فقط علامت تأیید مالک است.
class ApprovalScreen extends StatefulWidget {
  const ApprovalScreen({super.key});

  @override
  State<ApprovalScreen> createState() => _ApprovalScreenState();
}

class _ApprovalScreenState extends State<ApprovalScreen> {
  bool _loading = true;
  String? _error;
  int _limit = 0;
  List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  final TextEditingController _limitC = TextEditingController();

  @override
  void initState() {
    super.initState();
    _run(() => StockApi.call('approval.get'));
  }

  @override
  void dispose() {
    _limitC.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() req) async {
    try {
      final Map<String, dynamic> r = await req();
      if (!mounted) return;
      setState(() {
        _limit = (r['limit'] as num?)?.toInt() ?? 0;
        MoneyField.setStored(_limitC, _limit == 0 ? null : _limit);
        _pending = (r['pending'] as List<dynamic>? ?? <dynamic>[])
            .map((dynamic e) => Map<String, dynamic>.from(e as Map<dynamic, dynamic>))
            .toList();
        _error = null;
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

  Future<void> _saveLimit() async {
    final num? v = MoneyField.stored(_limitC);
    if (_limitC.text.trim().isNotEmpty && (v == null || v < 0)) {
      snack(context, 'سقف مبلغ نامعتبر است');
      return;
    }
    await _run(() => StockApi.call('approval.set_limit', <String, dynamic>{'limit': v ?? 0}));
    if (mounted && _error == null) snack(context, 'سقف ذخیره شد');
  }

  Future<void> _approve(Map<String, dynamic> d) async {
    if (!await confirm(context, 'این سند تأیید شود؟')) return;
    await _run(() => StockApi.call('approval.approve', <String, dynamic>{'doc_type': d['doc_type'], 'id': d['id']}));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تأیید دوم اسناد')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
              if (_error != null)
                Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
              const Text('سند خرید یا فروشی که کارمند ثبت کند و مبلغ آن به این سقف یا بیشتر برسد، «در انتظار تأیید مالک» می‌شود. خالی یا ۰ = غیرفعال.'),
              const SizedBox(height: 8),
              Row(children: <Widget>[
                Expanded(child: MoneyField(controller: _limitC, label: 'سقف مبلغ سند')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _saveLimit, child: const Text('ذخیره')),
              ]),
              const SizedBox(height: 16),
              Text('در انتظار تأیید (${faNum(_pending.length, dec: 0)})', style: Theme.of(context).textTheme.titleMedium),
              if (_pending.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('سندی در انتظار تأیید نیست')),
              for (final Map<String, dynamic> d in _pending)
                Card(
                  child: ListTile(
                    title: Text('${d['doc_type'] == 'sale' ? 'فروش' : 'خرید'} ${d['title'] ?? ''} — ${Fmt.money((d['total_rial'] as num?) ?? 0)}'),
                    subtitle: Text('${faNum((d['net_weight'] as num?) ?? 0)} کیلو  •  ${d['party'] ?? '-'}  •  ${jalaliDate('${d['date']}')}'),
                    trailing: FilledButton(onPressed: () => _approve(d), child: const Text('تأیید')),
                  ),
                ),
            ]),
    );
  }
}
