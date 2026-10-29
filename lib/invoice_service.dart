import 'package:flutter/material.dart';

import 'db.dart';
import 'form_settings.dart' show FormSettingsLocal;
import 'grade_lines_ui.dart' show GradeLinesLocal;
import 'fx_local.dart';
import 'license_service.dart';
import 'pdf_output.dart';
import 'pdf_service.dart';
import 'warehouse_ui.dart' show StockApi; // S35.T35.6e: online fin.block
import 'utils.dart';
import 'widgets.dart';

/// ساخت فاکتور خرید/فروش (PDF).
///  * فاکتور «ریالی»: برای همهٔ کاربران.
///  * فاکتور «ریالی/ارزی»: فقط پلن ارزی؛ فی و مبلغ دلاری و نرخ دلار را هم درج می‌کند.
class InvoiceService {
  InvoiceService._();

  /// پلن ارزی بین دو نوع فاکتور انتخاب می‌کند؛ پلن ریالی مستقیم فاکتور ریالی می‌گیرد.
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
            title: const Text('فاکتور ریالی'),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            leading: const Icon(Icons.currency_exchange),
            title: const Text('فاکتور ریالی / ارزی'),
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

  /// S27c: اطلاعات ارز سند (null = سند ریالی یا قدیمیِ دلاری).
  static Future<({String code, String symbol, int dec, double rate})?> _ccyOf(Map<String, dynamic> d) async {
    final String code = ((d['ccy'] as String?) ?? '').trim();
    final double rate = ((d['fx_rate'] as num?) ?? 0).toDouble();
    if (code.isEmpty || code == 'IRT' || rate <= 0) return null;
    String sym = code;
    int dec = 2;
    for (final Map<String, dynamic> c in await FxLocal.loadCurrencies()) {
      if (c['code'] == code) {
        final String sy = (c['symbol'] ?? '').toString();
        if (sy.isNotEmpty) sym = sy;
        dec = (c['decimals'] as num?)?.toInt() ?? 2;
      }
    }
    return (code: code, symbol: sym, dec: dec, rate: rate);
  }

  static Future<void> forPurchase(BuildContext context, Map<String, dynamic> p) async {
    final withUsd = await _askType(context);
    if (withUsd == null) return;
    final fxc = await _ccyOf(p);
    final rate = (p['usd_rate'] as num?)?.toDouble();
    if (withUsd && fxc == null && (rate == null || rate <= 0)) {
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
        weighRows: <List<String>>[...await _weighRows(p), ...await _gradeRows('purchase', p), ...await _finRows('purchase', p)],
        unitPrice: (p['price'] as num).toDouble(),
        specs: specsOf(p),
        usdRate: rate,
        ccy: fxc?.code,
        ccySymbol: fxc?.symbol,
        ccyDec: fxc?.dec ?? 2,
        fxRate: fxc?.rate,
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
    final fxc = await _ccyOf(sale);
    final rate = (sale['usd_rate'] as num?)?.toDouble();
    if (withUsd && fxc == null && (rate == null || rate <= 0)) {
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
        weighRows: <List<String>>[...await _weighRows(sale), ...await _gradeRows('sale', sale), ...await _finRows('sale', sale)],
        unitPrice: (sale['price'] as num).toDouble(),
        specs: p == null ? const [] : specsOf(p),
        usdRate: rate,
        ccy: fxc?.code,
        ccySymbol: fxc?.symbol,
        ccyDec: fxc?.dec ?? 2,
        fxRate: fxc?.rate,
        note: sale['note'] as String?,
      );
      await PdfOutput.show(context, file);
    } catch (e) {
      if (context.mounted) snack(context, 'خطا در ساخت فاکتور: $e');
    }
  }

  /// S35.T35.2b: weighing block rows for the invoice; empty unless the «توزین» switch is on and the document has a block.
  static Future<List<List<String>>> _weighRows(Map<String, dynamic> d) async {
    if (d['gross_kg'] == null || !await FormSettingsLocal.isOn('weigh')) return <List<String>>[];
    String t(Object? v) => (v == null || '$v'.trim().isEmpty) ? '' : '$v'.trim();
    return <List<String>>[
      <String>['تارا', '${faNum(((d['tare_kg'] as num?) ?? 0).toDouble())} کیلو'],
      if (((d['quality_deduct_kg'] as num?) ?? 0) > 0) <String>['کسر کیفیت', '${faNum((d['quality_deduct_kg'] as num).toDouble())} کیلو'],
      if (t(d['weigh_ticket_no']).isNotEmpty) <String>['شمارهٔ قبض باسکول', t(d['weigh_ticket_no'])],
      if (t(d['vehicle_plate']).isNotEmpty) <String>['پلاک', t(d['vehicle_plate'])],
      if (t(d['driver_name']).isNotEmpty) <String>['راننده', t(d['driver_name'])],
    ];
  }

  /// S35.T35.6e: financial block rows taken from the SERVER (fin.block), so the printed numbers equal the saved ones.
  /// Empty unless form.fin_block is on, the document has a server id (> 0) and the server answers (offline = no block).
  static Future<List<List<String>>> _finRows(String docType, Map<String, dynamic> d) async {
    final Object? id = d['id'];
    if (id is! num || id <= 0 || !await FormSettingsLocal.isOn('fin_block')) return <List<String>>[];
    try {
      final Map<String, dynamic> b = await StockApi.call('fin.block', <String, dynamic>{'doc_type': docType, 'id': id.toInt()});
      final Map<String, dynamic> side = (b['side_costs'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final double mult = ((b['unit_mult'] as num?) ?? 1).toDouble(); // Q1: ریال = ذخیره × ضریب واحد (سرور)
      String m(Object? v) => faNum((((v as num?) ?? 0) * mult), dec: 0);
      num n(Object? v) => (v as num?) ?? 0;
      return <List<String>>[
        <String>['ارزش کالا', m(b['goods'])],
        if (n(b['discount']) > 0) <String>['تخفیف', m(b['discount'])],
        <String>['مبلغ قبل از مالیات', m(b['before_tax'])],
        <String>['مالیات بر ارزش افزوده', m(b['tax'])],
        if (n(side['labor']) > 0) <String>['هزینه کارگر', m(side['labor'])],
        if (n(side['transport']) > 0) <String>['حمل‌ونقل', m(side['transport'])],
        if (n(side['weighbridge']) > 0) <String>['هزینهٔ باسکول', m(side['weighbridge'])],
        <String>['هزینه‌های جانبی بر عهدهٔ', b['side_cost_payer'] == 'party' ? 'طرف حساب' : 'ما'],
        <String>['مبلغ کل', m(b['grand_total'])],
        <String>['مبلغ به حروف', '${b['words'] ?? ''}'],
      ];
    } catch (_) {
      return <List<String>>[]; // آفلاین یا خطای سرور: بلوک چاپ نمی‌شود (عدد حدسی چاپ نمی‌کنیم)
    }
  }

  /// S35.T35.3b: one row per grade line («خندان» → «۱۰ کیلو × فی = جمع»); empty unless the «ردیف درجه‌ها» switch is on.
  static Future<List<List<String>>> _gradeRows(String docType, Map<String, dynamic> d) async {
    final Object? id = d['id'];
    if (id is! int || !await FormSettingsLocal.isOn('grades')) return <List<String>>[];
    final List<Map<String, dynamic>> lines = await GradeLinesLocal.load(docType, id);
    if (lines.isEmpty) return <List<String>>[];
    final Map<String, String> lab = <String, String>{for (final Map<String, String> g in await GradeLinesLocal.grades()) g['key']!: g['label']!};
    return <List<String>>[
      for (final Map<String, dynamic> l in lines)
        <String>[
          'درجه ${lab['${l['grade_key']}'] ?? l['grade_key']}',
          '${faNum((l['kg'] as num).toDouble())} کیلو × ${faNum((l['unit_price'] as num).toDouble(), dec: 0)} = ${faNum((l['kg'] as num).toDouble() * (l['unit_price'] as num).toDouble(), dec: 0)}',
        ],
    ];
  }
}
