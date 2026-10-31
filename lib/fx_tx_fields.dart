// S28.T28.2b — foreign-currency fields for receipt / payment / cheque lines (fx plan only).
// The main «amount» controller of the form keeps holding the RIAL EQUIVALENT in the stored unit (toman until S29),
// so overpay checks, totals and reports are unchanged. When a currency is chosen: amount = ccy_amount * rate / 10
// (auto-filled, still editable = the rial actually moved). The line sends ccy, ccy_amount, fx_rate + amount.
// Rial plan / no cached currencies: the widget renders nothing and fields() is empty.
import 'package:flutter/material.dart';

import 'fx_doc_field.dart';
import 'fmt.dart' show MoneyField;
import 'fx_local.dart';
import 'utils.dart';
import 'widgets.dart';

class FxTxController {
  final TextEditingController amount;
  final TextEditingController ccyAmount = TextEditingController();
  final TextEditingController rate = TextEditingController();
  String? ccy;
  List<Map<String, dynamic>> currencies = <Map<String, dynamic>>[];

  FxTxController(this.amount);

  bool get active => ccy != null;
  bool get available => currencies.isNotEmpty;

  Future<void> load(Map<String, dynamic>? existing) async {
    try {
      final List<Map<String, dynamic>> all = await FxLocal.loadCurrencies();
      currencies = all.where((Map<String, dynamic> c) => c['active'] == true && c['is_base'] != true).toList();
    } catch (_) {
      currencies = <Map<String, dynamic>>[];
    }
    if (existing != null) {
      final String? c = existing['ccy'] as String?;
      if (c != null && c.isNotEmpty) {
        ccy = c;
        final num? ca = existing['ccy_amount'] as num?;
        final num? fr = existing['fx_rate'] as num?;
        if (ca != null) ccyAmount.text = plain(ca);
        if (fr != null) rate.text = plain(fr);
      }
    }
  }

  Future<void> resolveRate(String dateIso) async {
    final String? c = ccy;
    if (c == null) return;
    final ({double rate, String date})? r = await FxLocal.rateAt(c, dateIso);
    rate.text = r == null ? '' : plain(r.rate);
    recompute();
  }

  /// amount (stored unit) = ccy_amount * rate / kFxRialPerStoredUnit.
  void recompute() {
    final double? ca = parseNum(ccyAmount.text);
    final double? r = parseNum(rate.text);
    if (!active || ca == null || r == null || ca <= 0 || r <= 0) return;
    final double v = (ca * r / kFxRialPerStoredUnit * 100).roundToDouble() / 100;
    MoneyField.setStored(amount, v);
  }

  String? validate() {
    if (!active) return null;
    final double? ca = parseNum(ccyAmount.text);
    final double? r = parseNum(rate.text);
    if (ca == null || ca <= 0) return 'مبلغ ارزی را وارد کنید';
    if (r == null || r <= 0) return 'نرخ ارز را وارد کنید (یا ابتدا نرخ را در «نرخ ارز» ثبت و همگام کنید)';
    return null;
  }

  Map<String, dynamic> fields() {
    if (!active) return <String, dynamic>{};
    return <String, dynamic>{
      'ccy': ccy,
      'ccy_amount': parseNum(ccyAmount.text),
      'fx_rate': parseNum(rate.text),
    };
  }

  void dispose() {
    ccyAmount.dispose();
    rate.dispose();
  }
}

/// Currency picker + foreign amount + editable rate. Put it just above the rial amount field.
class FxTxFields extends StatelessWidget {
  final FxTxController c;
  final String dateIso;
  final VoidCallback onChanged;
  const FxTxFields({super.key, required this.c, required this.dateIso, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!c.available) return const SizedBox.shrink();
    final List<Widget> w = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String?>(
          value: c.ccy,
          decoration: const InputDecoration(labelText: 'ارز', border: OutlineInputBorder()),
          items: <DropdownMenuItem<String?>>[
            const DropdownMenuItem<String?>(value: null, child: Text('ریال')),
            for (final Map<String, dynamic> cur in c.currencies)
              DropdownMenuItem<String?>(value: cur['code'] as String, child: Text('${cur['name'] ?? ''} (${cur['code']})')),
          ],
          onChanged: (String? v) async {
            c.ccy = v;
            if (v == null) {
              c.ccyAmount.clear();
              c.rate.clear();
            } else {
              await c.resolveRate(dateIso);
            }
            onChanged();
          },
        ),
      ),
    ];
    if (c.active) {
      w.add(numField(c.ccyAmount, 'مبلغ ارزی', required: true, onChanged: () {
        c.recompute();
        onChanged();
      }));
      w.add(numField(c.rate, 'نرخ (ریال به ازای هر واحد)', required: true, thousands: true, onChanged: () {
        c.recompute();
        onChanged();
      }));
      w.add(const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text('مبلغ زیر معادل ریالی (ریال) است و از مبلغ ارزی × نرخ پر می‌شود؛ در صورت نیاز می‌توانید ریال واقعاً دریافتی/پرداختی را اصلاح کنید.',
            style: TextStyle(color: Colors.black54, fontSize: 12)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: w);
  }
}
