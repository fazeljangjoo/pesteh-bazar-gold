// S30.T30.6b — currency selector for the stock (inventory) charts. Stock value = server `value` (lot cost, stored money unit)
// divided by the registered rate on the report date (latest rate on/before `to`, else today). No rate => no chart, a warning.
import 'package:flutter/material.dart';

import 'fx_profit.dart' show FxRateBook;
import 'license_service.dart';

/// Loads the rate book (fx plan only). [codes] empty => plain rial charts, selector hidden.
class StockCcy {
  FxRateBook? book;
  String? ccy; // null = kg view (default)

  bool get available => book != null && book!.codes.isNotEmpty;

  Future<void> load(VoidCallback onLoaded) async {
    if (!LicenseService.I.isFx.value) return;
    try {
      book = await FxRateBook.load();
      onLoaded();
    } catch (_) {
      book = null;
    }
  }

  /// Value of [valueStored] in [ccy] on [iso] (yyyy-mm-dd); null when no rate is registered.
  double? convert(double valueStored, String iso) {
    if (ccy == null || book == null) return null;
    final double? r = book!.rateOf(ccy!, iso);
    if (r == null || r <= 0) return null;
    return valueStored / r;
  }

  static String isoOf(DateTime? d) {
    final DateTime x = d ?? DateTime.now();
    String two(int n) => n < 10 ? '0$n' : '$n';
    return '${x.year}-${two(x.month)}-${two(x.day)}';
  }
}

/// «کیلو | USD | EUR …» switch placed above a stock chart.
class StockCcySwitch extends StatelessWidget {
  final StockCcy st;
  final ValueChanged<String?> onChanged;
  const StockCcySwitch({super.key, required this.st, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (!st.available) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SegmentedButton<String>(
        segments: <ButtonSegment<String>>[
          const ButtonSegment<String>(value: '', label: Text('کیلو')),
          for (final String c in st.book!.codes) ButtonSegment<String>(value: c, label: Text(c)),
        ],
        selected: <String>{st.ccy ?? ''},
        showSelectedIcon: false,
        onSelectionChanged: (Set<String> v) => onChanged(v.first.isEmpty ? null : v.first),
      ),
    );
  }
}
