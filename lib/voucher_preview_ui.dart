import 'package:flutter/material.dart';

import 'edition.dart';
import 'utils.dart';
import 'warehouse_ui.dart' show StockApi;

/// S35.T35.9d — «پیش‌نمایش سند حسابداری» (طلایی، فقط نمایشی) قبل از ثبت نهایی خرید/فروش.
/// سرور همان قانون‌های سندزنی را روی سند ذخیره‌نشده اجرا می‌کند و چیزی نمی‌نویسد.
/// بازگشت: true = ادامهٔ ثبت، false = کاربر انصراف داد.
/// پیش‌نمایش هرگز مانع ثبت نمی‌شود: سبز، آفلاین یا هر خطا => بدون دیالوگ true برمی‌گردد.
Future<bool> confirmVoucherPreview(
  BuildContext context, {
  required String docType, // 'purchase' | 'sale'
  required Map<String, dynamic> doc,
  List<Map<String, dynamic>> items = const <Map<String, dynamic>>[],
}) async {
  if (!EditionService.I.current.value.has('gold.vouchers')) return true;
  final Map<String, dynamic> d = <String, dynamic>{};
  doc.forEach((String k, dynamic v) {
    if (v is num || v is String || v == null) d[k] = v;
  });
  final String dt = (d['date'] ?? DateTime.now().toIso8601String()).toString();
  d['date'] = dt.length >= 10 ? dt.substring(0, 10) : dt;
  Map<String, dynamic> r;
  try {
    r = await StockApi.call('posting.preview', <String, dynamic>{
      'type': docType,
      'doc': d,
      if (docType == 'sale') 'items': items,
      'settle': <String, dynamic>{'cash': 0, 'bank': 0, 'cheque': 0}, // payments are separate documents
    }).timeout(const Duration(seconds: 6));
  } catch (_) {
    return true; // offline / not permitted / server error: preview is optional
  }
  final List<dynamic> lines = (r['lines'] as List<dynamic>?) ?? <dynamic>[];
  final String note = (r['note'] ?? '').toString();
  if (!context.mounted) return true;
  if (lines.isEmpty && note.isEmpty) return true;
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('پیش‌نمایش سند حسابداری'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('فقط نمایش است؛ تا «ثبت» نزنید هیچ سندی ساخته نمی‌شود. مبالغ به ریال و مالیات تقریبی است (مقدار نهایی را سرور محاسبه می‌کند). پرداخت/دریافت‌ها جداگانه سند می‌شوند.',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            if (lines.isEmpty) Text(note),
            for (final dynamic raw in lines) _lineTile(raw as Map<String, dynamic>),
            if (lines.isNotEmpty) ...<Widget>[
              const Divider(),
              Text('جمع بدهکار: ${faNum((r['total_debit'] as num?) ?? 0)}   |   جمع بستانکار: ${faNum((r['total_credit'] as num?) ?? 0)}'),
              if (r['balanced'] == false) const Text('هشدار: سند تراز نیست', style: TextStyle(color: Colors.red)),
            ],
          ]),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('بازگشت به فرم')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ثبت نهایی')),
      ],
    ),
  );
  return go == true;
}

Widget _lineTile(Map<String, dynamic> l) {
  final num dr = (l['debit'] as num?) ?? 0;
  final num cr = (l['credit'] as num?) ?? 0;
  final String taf = (l['tafsili_name'] ?? '').toString();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Expanded(
        child: Text('${l['account_code'] ?? ''} ${l['account_name'] ?? ''}${taf.isEmpty ? '' : ' — $taf'}', style: const TextStyle(fontSize: 13)),
      ),
      const SizedBox(width: 8),
      Text(dr > 0 ? 'بد ${faNum(dr)}' : 'بس ${faNum(cr)}',
          style: TextStyle(fontSize: 13, color: dr > 0 ? Colors.indigo : Colors.teal)),
    ]),
  );
}
