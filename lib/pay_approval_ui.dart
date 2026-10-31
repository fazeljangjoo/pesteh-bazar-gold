// S31.T31.3b — owner screen for the second approval of staff payments above a limit (server: pay_approval.*),
// plus a global «pending approval» notice raised by the sync queue when payments.save was diverted.
import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt, MoneyField;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// Raised by SyncService when the server answers payments.save with pending_approval.
class PayApprovalNotice {
  PayApprovalNotice._();
  static final PayApprovalNotice I = PayApprovalNotice._();
  final ValueNotifier<int> count = ValueNotifier<int>(0);
  num amountRial = 0;

  void report(num amount) {
    amountRial = amount;
    count.value++;
  }
}

/// Wrap near the app root (below MaterialApp): shows the «در انتظار تأیید» snack bar.
class PayApprovalNoticeHost extends StatefulWidget {
  final Widget child;
  const PayApprovalNoticeHost({super.key, required this.child});

  @override
  State<PayApprovalNoticeHost> createState() => _PayApprovalNoticeHostState();
}

class _PayApprovalNoticeHostState extends State<PayApprovalNoticeHost> {
  @override
  void initState() {
    super.initState();
    PayApprovalNotice.I.count.addListener(_show);
  }

  @override
  void dispose() {
    PayApprovalNotice.I.count.removeListener(_show);
    super.dispose();
  }

  void _show() {
    if (!mounted) return;
    final String amt = Fmt.money(PayApprovalNotice.I.amountRial, from: 'rial');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('پرداخت $amt بالاتر از سقف است و در انتظار تأیید مالک ماند؛ تا تأیید، در حساب اعمال نمی‌شود.'),
    ));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class PayApprovalScreen extends StatefulWidget {
  const PayApprovalScreen({super.key});

  @override
  State<PayApprovalScreen> createState() => _PayApprovalScreenState();
}

class _PayApprovalScreenState extends State<PayApprovalScreen> {
  bool _loading = true;
  String? _error;
  bool _enabled = true;
  List<Map<String, dynamic>> _pending = <Map<String, dynamic>>[];
  final TextEditingController _limitC = TextEditingController();

  @override
  void initState() {
    super.initState();
    _run('pay_approval.list');
  }

  @override
  void dispose() {
    _limitC.dispose();
    super.dispose();
  }

  Future<void> _run(String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    try {
      final Map<String, dynamic> r = await StockApi.call(action, payload);
      if (!mounted) return;
      final int limitRial = (r['limit'] as num?)?.toInt() ?? 0;
      setState(() {
        _enabled = r['enabled'] != false;
        MoneyField.setStored(_limitC, limitRial == 0 ? null : Fmt.toDisplay(limitRial, from: 'rial', to: Fmt.storedUnit));
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
    final int rial = v == null ? 0 : Fmt.toDisplay(v, from: Fmt.storedUnit, to: 'rial');
    await _run('pay_approval.set_limit', <String, dynamic>{'limit': rial});
    if (mounted && _error == null) snack(context, 'سقف ذخیره شد');
  }

  Future<void> _approve(Map<String, dynamic> d) async {
    if (!await confirm(context, 'این پرداخت تأیید و در حساب اعمال شود؟')) return;
    await _run('pay_approval.approve', <String, dynamic>{'id': d['id']});
    if (mounted && _error == null) snack(context, 'پرداخت تأیید و ثبت شد');
  }

  Future<void> _reject(Map<String, dynamic> d) async {
    if (!await confirm(context, 'این درخواست پرداخت رد شود؟')) return;
    await _run('pay_approval.reject', <String, dynamic>{'id': d['id']});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تأیید پرداخت‌های بالای سقف')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: <Widget>[
              if (_error != null)
                Card(color: Theme.of(context).colorScheme.errorContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!))),
              if (!_enabled)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('کلید «تأیید دوم» در تنظیمات فرم‌ها خاموش است؛ تا روشن نشود سقف اعمال نمی‌شود.'),
                ),
              const Text('پرداخت خریدی که کارمند ثبت کند و مبلغ پرداخت‌شدهٔ جدید آن به این سقف یا بیشتر برسد، تا تأیید مالک اعمال نمی‌شود. خالی یا ۰ = غیرفعال. دریافت‌ها مشمول نیستند.'),
              const SizedBox(height: 8),
              Row(children: <Widget>[
                Expanded(child: MoneyField(controller: _limitC, label: 'سقف مبلغ پرداخت')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _saveLimit, child: const Text('ذخیره')),
              ]),
              const SizedBox(height: 16),
              Text('در انتظار تأیید (${faNum(_pending.length, dec: 0)})', style: Theme.of(context).textTheme.titleMedium),
              if (_pending.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('پرداختی در انتظار تأیید نیست')),
              for (final Map<String, dynamic> d in _pending)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                      Text('پرداخت ${Fmt.money((d['amount_rial'] as num?) ?? 0, from: 'rial')}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('خرید ${d['code'] ?? ''} ${d['title'] ?? ''}  •  ${d['party'] ?? '-'}'),
                      Text('درخواست‌دهنده: ${d['requested_by'] ?? '-'}  •  ${d['created_at'] ?? ''}', style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      Row(children: <Widget>[
                        Expanded(child: OutlinedButton(onPressed: () => _reject(d), child: const Text('رد'))),
                        const SizedBox(width: 8),
                        Expanded(child: FilledButton(onPressed: () => _approve(d), child: const Text('تأیید'))),
                      ]),
                    ]),
                  ),
                ),
            ]),
    );
  }
}
