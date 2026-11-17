import 'package:flutter/material.dart';

import 'form_settings.dart' show FormSettingsLocal;
import 'utils.dart' show faNum;
import 'warehouse_ui.dart' show StockApi;

/// S35.T35.6f: کارت بلوک مالی داخل فرم خرید/فروش (ارقام از سرور، واحد ریال، Q1).
/// فقط وقتی form.fin_block روشن است و سند شناسهٔ سرور دارد نمایش داده می‌شود؛ آفلاین چیزی نشان نمی‌دهد.
class FinBlockCard extends StatefulWidget {
  final String docType; // 'purchase' | 'sale'
  final int? docId;

  const FinBlockCard({super.key, required this.docType, required this.docId});

  @override
  State<FinBlockCard> createState() => _FinBlockCardState();
}

class _FinBlockCardState extends State<FinBlockCard> {
  late final Future<Map<String, dynamic>?> _future = _load(); // یک‌بار در ساخت ویجت، نه در هر بازسازی فرم

  Future<Map<String, dynamic>?> _load() async {
    final int? id = widget.docId;
    if (id == null || id <= 0 || !await FormSettingsLocal.isOn('fin_block')) return null;
    try {
      return await StockApi.call('fin.block', <String, dynamic>{'doc_type': widget.docType, 'id': id});
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Map<String, dynamic>?> snap) {
        final Map<String, dynamic>? b = snap.data;
        if (b == null) return const SizedBox.shrink();
        final double mult = ((b['unit_mult'] as num?) ?? 1).toDouble();
        String m(Object? v) => '${faNum(((v as num?) ?? 0) * mult, dec: 0)} ریال';
        final Map<String, dynamic> side = (b['side_costs'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
        final TextTheme tt = Theme.of(context).textTheme;
        Widget row(String k, String v, {bool bold = false}) {
          final TextStyle st = bold ? const TextStyle(fontWeight: FontWeight.bold) : const TextStyle();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: <Widget>[
              Expanded(child: Text(k, style: st)),
              Text(v, style: st),
            ]),
          );
        }

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('بلوک مالی', style: tt.titleMedium),
                const SizedBox(height: 6),
                row('ارزش کالا', m(b['goods'])),
                if (((b['discount'] as num?) ?? 0) > 0) row('تخفیف', m(b['discount'])),
                row('مبلغ قبل از مالیات', m(b['before_tax'])),
                row('مالیات بر ارزش افزوده', m(b['tax'])),
                if (((side['labor'] as num?) ?? 0) > 0) row('هزینه کارگر', m(side['labor'])),
                if (((side['transport'] as num?) ?? 0) > 0) row('حمل‌ونقل', m(side['transport'])),
                if (((side['weighbridge'] as num?) ?? 0) > 0) row('هزینهٔ باسکول', m(side['weighbridge'])),
                row('هزینه‌های جانبی بر عهدهٔ', b['side_cost_payer'] == 'party' ? 'طرف حساب' : 'ما'),
                row('مبلغ کل', m(b['grand_total']), bold: true),
                const SizedBox(height: 4),
                Text('${b['words'] ?? ''}', style: tt.bodySmall),
              ],
            ),
          ),
        );
      },
    );
  }
}
