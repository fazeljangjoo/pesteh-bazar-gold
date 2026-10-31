import 'package:flutter/material.dart';

/// S35.T35.13 — «خلاصهٔ تأیید» قبل از ثبت نهایی خرید/فروش (فقط وقتی تنظیم confirm_summary روشن است).
/// ردیف‌ها را فرم از همان دادهٔ ذخیره‌شونده می‌سازد، پس عددها دقیقاً با آنچه ثبت می‌شود یکی‌اند.
/// بازگشت: true = ادامهٔ ثبت، false = انصراف.
Future<bool> confirmDocSummary(
  BuildContext context, {
  required String title,
  required List<MapEntry<String, String>> rows,
}) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final MapEntry<String, String> r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text(r.key, style: const TextStyle(color: Colors.black54))),
                    Text(r.value, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ویرایش')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأیید و ثبت')),
      ],
    ),
  );
  return ok ?? false;
}
