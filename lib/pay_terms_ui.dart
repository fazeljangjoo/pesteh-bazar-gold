import 'package:flutter/material.dart';

import 'utils.dart' show faNum;
import 'warehouse_ui.dart' show StockApi;

/// S35.T35.7h-6: market payment terms UI (online). Server: pay.terms, pay.rate.save, pay.credit_check.
/// Errors are shown as text and never block saving a document; the credit check only WARNS.

Future<Map<String, dynamic>> payTermsCalc(List<Map<String, dynamic>> items, {String? asOf}) {
  return StockApi.call('pay.terms', <String, dynamic>{'items': items, if (asOf != null) 'as_of': asOf});
}

Future<Map<String, dynamic>> payRateSave(String raw) {
  return StockApi.call('pay.rate.save', <String, dynamic>{'rate': raw});
}

Future<Map<String, dynamic>> payCreditCheck(String party, num amount) {
  return StockApi.call('pay.credit_check', <String, dynamic>{'party': party, 'amount': amount});
}

/// Monthly discount rate (percent) for «معادل نقد». Empty = not configured.
class PayRateCard extends StatefulWidget {
  const PayRateCard({super.key});

  @override
  State<PayRateCard> createState() => _PayRateCardState();
}

class _PayRateCardState extends State<PayRateCard> {
  final TextEditingController _rate = TextEditingController();
  bool _busy = false;
  String? _msg;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await payTermsCalc(<Map<String, dynamic>>[]);
      final Object? v = r['rate_monthly_pct'];
      if (mounted) setState(() => _rate.text = v == null ? '' : '$v');
    } catch (e) {
      if (mounted) setState(() => _msg = 'خواندن نرخ ممکن نشد: $e');
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      await payRateSave(_rate.text.trim());
      if (mounted) setState(() => _msg = 'نرخ ذخیره شد');
    } catch (e) {
      if (mounted) setState(() => _msg = 'ذخیره نشد: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('نرخ تنزیل ماهانه (٪) برای معادل نقد', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'خالی = تعریف‌نشده'),
            ),
            const SizedBox(height: 6),
            FilledButton(onPressed: _busy ? null : _save, child: const Text('ذخیرهٔ نرخ')),
            if (_msg != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_msg!)),
          ],
        ),
      ),
    );
  }
}

/// Weighted due date, total and cash equivalent of installments. items: [{amount, due_date: 'YYYY-MM-DD'}].
class PayTermsPreview extends StatefulWidget {
  final List<Map<String, dynamic>> installments;

  const PayTermsPreview({super.key, required this.installments});

  @override
  State<PayTermsPreview> createState() => _PayTermsPreviewState();
}

class _PayTermsPreviewState extends State<PayTermsPreview> {
  late Future<Map<String, dynamic>> _future = payTermsCalc(widget.installments);

  @override
  void didUpdateWidget(covariant PayTermsPreview old) {
    super.didUpdateWidget(old);
    if (old.installments != widget.installments) _future = payTermsCalc(widget.installments);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Map<String, dynamic>> snap) {
        if (snap.hasError) return Text('محاسبهٔ شرایط پرداخت ممکن نشد', style: Theme.of(context).textTheme.bodySmall);
        final Map<String, dynamic>? r = snap.data;
        if (r == null) return const SizedBox(height: 16, child: LinearProgressIndicator());
        final num total = (r['total'] as num?) ?? 0;
        final Object? cash = r['cash_equiv'];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('جمع اقساط/چک‌ها: ${faNum(total, dec: 0)} ریال'),
            Text('سررسید میانگین: ${r['avg_due'] ?? '-'}'),
            Text(cash == null ? 'معادل نقد: نرخ ماهانه تنظیم نشده' : 'معادل نقد: ${faNum(cash as num, dec: 0)} ریال'),
          ],
        );
      },
    );
  }
}

/// Warn-only credit-limit notice for a party after this document. Shows nothing when there is no problem.
class PayCreditWarning extends StatelessWidget {
  final String party;
  final num amount;

  const PayCreditWarning({super.key, required this.party, required this.amount});

  @override
  Widget build(BuildContext context) {
    if (party.trim().isEmpty || amount <= 0) return const SizedBox.shrink();
    return FutureBuilder<Map<String, dynamic>>(
      future: payCreditCheck(party, amount),
      builder: (BuildContext context, AsyncSnapshot<Map<String, dynamic>> snap) {
        final Map<String, dynamic>? r = snap.data;
        if (r == null || r['over_limit'] != true) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'هشدار: مانده با این سند از سقف اعتبار طرف حساب (${faNum((r['credit_limit'] as num?) ?? 0, dec: 0)}) بیشتر می‌شود. (فقط هشدار است)',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
      },
    );
  }
}
