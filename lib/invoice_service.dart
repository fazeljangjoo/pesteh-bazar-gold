import 'package:flutter/material.dart';

import 'db.dart';
import 'license_service.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'utils.dart';
import 'widgets.dart';

/// ساخت فاکتور خرید/فروش (PDF).
///  * فاکتور «تومانی»: برای همهٔ کاربران.
///  * فاکتور «تومانی/ارزی»: فقط پلن ارزی؛ فی و مبلغ دلاری و نرخ دلار را هم درج می‌کند.
class InvoiceService {
  InvoiceService._();

  /// پلن ارزی بین دو نوع فاکتور انتخاب می‌کند؛ پلن ریالی مستقیم فاکتور تومانی می‌گیرد.
  /// null = کاربر انصراف داد.
  static Future<bool?> _askType(BuildContext context) async {
    if (!LicenseService.I.isFx.value) return false;
    return showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(children: [
          const ListTile(title: Text('نوع فاکتور را انتخاب کنید')),
          ListTile(
            leading: const Icon(Icons.receipt_long_outlined),
            title: const Text('فاکتور تومانی'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            leading: const Icon(Icons.currency_exchange),
            title: const Text('فاکتور تومانی / ارزی'),
            subtitle: const Text('فی، مبلغ کل و نرخ دلار هم درج می‌شود'),
            onTap: () => Navigator.pop(ctx, true),
          ),
        ]),
      ),
    );
  }

  /// مشخصات کیفی یک خرید برای درج در فاکتور (همان منطق صفحهٔ جزئیات خرید)
  static List<List<String>> specsOf(Map<String, dynamic> p) {
    String? pct(String k) => p[k] == null ? null : '${faNum(p[k] as num)}٪';
    final preset = p['category_preset'] as String?;
    return [
      if (p['ounce'] != null) ['انس', faNum(p['ounce'] as num)],
      if (preset == 'dombest' && p['gram'] != null) ['گرم', faNum(p['gram'] as num)],
      if (preset == 'dombest' && pct('pct_khandan') != null) ['درصد خندان در دنبست', pct('pct_khandan')!],
      if (preset == 'khandan' && pct('pct_dombest') != null) ['درصد دنبست در خندان', pct('pct_dombest')!],
      if (preset == 'khandan' && pct('pct_tuchin') != null) ['درصد توچین', pct('pct_tuchin')!],
      if ((preset == 'dombest' || preset == 'khandan') && pct('pct_crooked') != null)
        ['درصد کج / ناخالص', pct('pct_crooked')!],
      for (final s in AppDb.decodeCustomSpecs(p['custom_specs'] as String?)) [s['label'] ?? '', s['value'] ?? ''],
    ];
  }

  static Future<void> forPurchase(BuildContext context, Map<String, dynamic> p) async {
    final withUsd = await _askType(context);
    if (withUsd == null) return;
    final rate = (p['usd_rate'] as num?)?.toDouble();
    if (withUsd && (rate == null || rate <= 0)) {
      if (context.mounted) snack(context, 'قیمت دلار این خرید ثبت نشده؛ ابتدا خرید را ویرایش کنید و قیمت دلار را وارد کنید');
      return;
    }
    try {
      final me = await LicenseService.I.savedName() ?? '';
      final file = await PdfService.buildInvoice(
        isSale: false,
        withUsd: withUsd,
        number: '${p['code'] ?? '-'}',
        dateLabel: jalaliDate(p['date'] as String),
        sellerName: ((p['seller'] as String?) ?? '').trim(),
        buyerName: me,
        category: '${p['category_name']}',
        type: '${p['type_name']}',
        code: '${p['code'] ?? '-'}',
        totalWeight: (p['total_weight'] as num).toDouble(),
        smallSacks: (p['small_sack_count'] as num).toDouble(),
        largeSacks: (p['large_sack_count'] as num).toDouble(),
        netWeight: (p['net_weight'] as num).toDouble(),
        unitPrice: (p['price'] as num).toDouble(),
        specs: specsOf(p),
        usdRate: rate,
        note: p['note'] as String?,
      );
      await PdfOutput.show(context, file);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در ساخت فاکتور: $e');
    }
  }

  static Future<void> forSale(BuildContext context, Map<String, dynamic> sale) async {
    final withUsd = await _askType(context);
    if (withUsd == null) return;
    final rate = (sale['usd_rate'] as num?)?.toDouble();
    if (withUsd && (rate == null || rate <= 0)) {
      if (context.mounted) snack(context, 'قیمت دلار این فروش ثبت نشده؛ ابتدا فروش را ویرایش کنید و قیمت دلار را وارد کنید');
      return;
    }
    try {
      final items = sale['items'] as List;
      final pid = items.isEmpty ? null : (items.first['purchase_id'] as num).toInt();
      final p = pid == null ? null : await AppDb.I.purchaseById(pid);
      final me = await LicenseService.I.savedName() ?? '';
      final id = (sale['id'] as num).toInt();
      final file = await PdfService.buildInvoice(
        isSale: true,
        withUsd: withUsd,
        number: 'S${id.abs().toString().padLeft(5, '0')}',
        dateLabel: jalaliDate(sale['date'] as String),
        sellerName: me,
        buyerName: ((sale['buyer'] as String?) ?? '').trim(),
        category: '${p?['category_name'] ?? items.firstOrNull?['category_name'] ?? '-'}',
        type: '${p?['type_name'] ?? items.firstOrNull?['type_name'] ?? '-'}',
        code: '${p?['code'] ?? items.firstOrNull?['code'] ?? '-'}',
        totalWeight: (sale['total_weight'] as num).toDouble(),
        smallSacks: (sale['small_sack_count'] as num).toDouble(),
        largeSacks: (sale['large_sack_count'] as num).toDouble(),
        netWeight: (sale['net_weight'] as num).toDouble(),
        unitPrice: (sale['price'] as num).toDouble(),
        specs: p == null ? const [] : specsOf(p),
        usdRate: rate,
        note: sale['note'] as String?,
      );
      await PdfOutput.show(context, file);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در ساخت فاکتور: $e');
    }
  }
}
