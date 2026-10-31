import 'package:flutter/material.dart';

import 'edition.dart';
import 'utils.dart';
import 'widgets.dart';

/// S17.T17.1b — document tax choice (GOLD only; renders nothing in green).
/// status: null = not specified (server uses the fiscal-year VAT as before), 'taxable' | 'exempt' | 'zero'.
/// Rate is typed in percent (9 = 9%) and sent as milli-percent (9000); empty = fiscal-year rate (server).
bool taxChoiceAvailable() => EditionService.I.current.value.has('gold.vouchers');

const Map<String, String> kTaxStatusFa = <String, String>{
  'taxable': 'مشمول مالیات',
  'exempt': 'معاف',
  'zero': 'نرخ صفر',
};

/// Percent text -> milli-percent (9 -> 9000); null when empty.
double? taxRateMilliFromText(String text) {
  final double? v = parseNum(text);
  return v == null ? null : (v * 1000).roundToDouble();
}

/// Stored milli-percent -> percent text for the field.
String taxRateTextFromMilli(dynamic milli) {
  if (milli is! num) return '';
  return plain(milli / 1000);
}

class TaxChoiceField extends StatelessWidget {
  const TaxChoiceField({super.key, required this.status, required this.rate, required this.onChanged});
  final String? status;
  final TextEditingController rate;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!taxChoiceAvailable()) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: DropdownButtonFormField<String?>(
          value: status,
          decoration: const InputDecoration(labelText: 'وضعیت مالیات (ارزش افزوده)', border: OutlineInputBorder()),
          items: <DropdownMenuItem<String?>>[
            const DropdownMenuItem<String?>(value: null, child: Text('تعیین نشده (طبق سال مالی)')),
            for (final MapEntry<String, String> e in kTaxStatusFa.entries) DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
          ],
          onChanged: onChanged,
        ),
      ),
      if (status == 'taxable') numField(rate, 'نرخ مالیات (درصد) — خالی = نرخ سال مالی', hint: 'مثلاً ۹'),
    ]);
  }
}
