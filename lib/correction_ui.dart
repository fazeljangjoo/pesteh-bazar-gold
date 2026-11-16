import 'package:flutter/material.dart';

import 'sync_service.dart';
import 'fmt.dart' show MoneyField;
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi, StockApiException;
import 'widgets.dart';

/// S35.T35.9c — سند اصلاحی فی و وزن برای خرید/فروش نهایی‌شده (آنلاین؛ سرور اعتبارسنجی و اعمال می‌کند).
/// docType: 'purchase' | 'sale'. پس از موفقیت، تغییرات سرور به برنامه همگام می‌شود.
Future<void> showCorrectionDialog(
  BuildContext context, {
  required String docType,
  required int id,
  required num price,
  required num netWeight,
}) async {
  if (id <= 0) {
    snack(context, 'این سند هنوز به سرور همگام نشده است؛ ابتدا همگام‌سازی کنید.');
    return;
  }
  final TextEditingController priceC = MoneyField.controllerFor(price);
  final TextEditingController netC = TextEditingController(text: plain(netWeight));
  final TextEditingController reasonC = TextEditingController();
  String? err;
  bool busy = false;
  final bool? done = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => StatefulBuilder(
      builder: (BuildContext ctx, void Function(void Function()) setS) => AlertDialog(
        title: const Text('سند اصلاحی (فی و وزن)'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('انبار و سند حسابداری با مقدارهای جدید بازسازی می‌شوند. پرداخت/دریافت‌ها تغییر نمی‌کنند.'),
            const SizedBox(height: 12),
            MoneyField(controller: priceC, label: 'فی جدید (هر کیلو)'),
            numField(netC, 'وزن خالص جدید (کیلو)'),
            TextField(
              controller: reasonC,
              maxLength: 300,
              maxLines: 2,
              decoration: InputDecoration(labelText: 'دلیل اصلاح (حداقل ۵ نویسه)', errorText: err, border: const OutlineInputBorder()),
            ),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final double? p = MoneyField.stored(priceC)?.toDouble();
                    final double? n = parseNum(netC.text);
                    final String r = reasonC.text.trim();
                    if (p == null || p <= 0 || n == null || n <= 0) {
                      setS(() => err = 'فی و وزن معتبر وارد کنید');
                      return;
                    }
                    if (r.length < 5) {
                      setS(() => err = 'دلیل باید حداقل ۵ نویسه باشد');
                      return;
                    }
                    setS(() {
                      busy = true;
                      err = null;
                    });
                    try {
                      await StockApi.call('docs.correct', <String, dynamic>{'doc_type': docType, 'id': id, 'price': p, 'net_weight': n, 'reason': r});
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } on StockApiException catch (e) {
                      setS(() {
                        busy = false;
                        err = e.message;
                      });
                    }
                  },
            child: const Text('ثبت اصلاحیه'),
          ),
        ],
      ),
    ),
  );
  priceC.dispose();
  netC.dispose();
  reasonC.dispose();
  if (done == true) {
    if (context.mounted) snack(context, 'سند اصلاحی ثبت شد');
    await SyncService.I.syncNow(pull: true);
  }
}
