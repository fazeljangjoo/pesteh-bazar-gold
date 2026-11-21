import 'package:flutter/material.dart';

import 'db.dart';
import 'entity_store.dart' show EntityStore;
import 'fmt.dart' show Fmt, MoneyField;
import 'perms.dart';
import 'pricing_engine.dart';
import 'warehouse_ui.dart' show StockApi;

/// v84 — درصدهای فرم خرید دقیقاً مثل اتاق انس (فایل مشترک اندروید و ویندوز):
///   ثبت: ردیف‌های پویا «نوع درصد (pct_defs) + درصد + گرم مغز در ۱۰۰ گرم»؛ جمع ≤ ۱۰۰.
///   قیمت (فقط مالک و حسابدار = مجوز price.view): مثل «قطعی‌سازی پذیرش» — قیمت پایه + «خرید گرمی» پستهٔ اصلی،
///   برای هر درصد «قیمت جدا» + «خرید گرمی»؛ میانگین هر کیلو و مبلغ کل با همان موتور (pricing_engine = آینهٔ pb_price_blend).
///   ذخیره: چهار درصد اصلی ⇒ ستون‌های pct_*؛ بقیه و گرم‌های مغز ⇒ custom_specs (برچسب «…» با مقدار «x%» و «گرم مغز …»).
///   فی خرید = میانگین هر کیلوی محاسبه‌شده (اگر قیمت جدا دارد)، وگرنه قیمت پایه.

const Map<String, String> kPctCoreCols = <String, String>{'tuchin': 'pct_tuchin', 'dombest': 'pct_dombest', 'crooked': 'pct_crooked', 'khandan': 'pct_khandan'};
const List<Map<String, dynamic>> _kFallbackDefs = <Map<String, dynamic>>[
  <String, dynamic>{'key': 'tuchin', 'label': 'توچین'},
  <String, dynamic>{'key': 'dombest', 'label': 'دهن‌بست'},
  <String, dynamic>{'key': 'crooked', 'label': 'کج'},
  <String, dynamic>{'key': 'khandan', 'label': 'خندان'},
];
const String _kKernelPrefix = 'گرم مغز ';

double? _num(String s) {
  final String t = s.trim().replaceAll('٫', '.').replaceAll(',', '');
  const String fa = '۰۱۲۳۴۵۶۷۸۹';
  final StringBuffer b = StringBuffer();
  for (final int r in t.runes) {
    final String ch = String.fromCharCode(r);
    final int i = fa.indexOf(ch);
    b.write(i >= 0 ? '$i' : ch);
  }
  return double.tryParse(b.toString().replaceAll('%', ''));
}

String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

class PurchasePctRow {
  PurchasePctRow({this.defKey, String pct = '', String kernel = ''})
      : pct = TextEditingController(text: pct),
        kernel = TextEditingController(text: kernel);
  String? defKey;
  final TextEditingController pct;
  final TextEditingController kernel;
  bool separate = false; // «قیمت جدا»
  bool gram = false; // «خرید گرمی»
  final TextEditingController q = TextEditingController();
  final TextEditingController g = TextEditingController();
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[pct, kernel, q, g]) {
      c.dispose();
    }
  }
}

class PurchasePctCtl {
  final List<PurchasePctRow> rows = <PurchasePctRow>[];
  List<Map<String, dynamic>> defs = _kFallbackDefs;
  bool baseGram = false;
  final TextEditingController baseG = TextEditingController();
  double refGram = 50;
  static double? _cachedRef;

  static bool get canPrice => StaffPerms.I.can('price.view');

  /// تعریف درصدها (اتاق انس) + گرم مرجع R (سرور؛ آفلاین ⇒ آخرین مقدار یا ۵۰).
  Future<void> init() async {
    try {
      final List<Map<String, dynamic>> d = (await EntityStore.I.list('pct_defs')).where((Map<String, dynamic> x) => x['active'] != false && x['active'] != 0).toList()
        ..sort((Map<String, dynamic> a, Map<String, dynamic> b) => ((a['sort'] as num?) ?? 0).compareTo((b['sort'] as num?) ?? 0));
      if (d.isNotEmpty) defs = d;
    } catch (_) {}
    refGram = _cachedRef ?? 50;
    if (canPrice) {
      try {
        final Map<String, dynamic> r = await StockApi.call('intake.price_settings');
        final double? v = (r['ref_gram'] as num?)?.toDouble();
        if (v != null && v > 0) refGram = _cachedRef = v;
      } catch (_) {}
    }
  }

  String labelOf(String? key) {
    for (final Map<String, dynamic> d in defs) {
      if (d['key'] == key) return '${d['label'] ?? key}';
    }
    return key ?? '';
  }

  String? keyOfLabel(String label) {
    for (final Map<String, dynamic> d in defs) {
      if ('${d['label']}' == label) return '${d['key']}';
    }
    return null;
  }

  /// آیا این مشخصهٔ ذخیره‌شده مال همین بخش است (درصد یا گرم مغز)؟ ⇒ در فهرست «مشخصات دلخواه» نشان داده نشود.
  bool ownsSpec(String label, String value) =>
      label.startsWith(_kKernelPrefix) || (value.trim().endsWith('%') && keyOfLabel(label) != null);

  /// بارگذاری از خرید ذخیره‌شده (ستون‌های pct_* + custom_specs).
  void loadFrom(Map<String, dynamic> e) {
    final Map<String, String> kernels = <String, String>{};
    final List<Map<String, String>> specs = AppDb.decodeCustomSpecs(e['custom_specs'] as String?);
    for (final Map<String, String> s in specs) {
      final String l = s['label'] ?? '', v = s['value'] ?? '';
      if (l.startsWith(_kKernelPrefix)) kernels[l.substring(_kKernelPrefix.length)] = v;
    }
    for (final MapEntry<String, String> c in kPctCoreCols.entries) {
      final Object? v = e[c.value];
      if (v is num) rows.add(PurchasePctRow(defKey: c.key, pct: _plain(v.toDouble()), kernel: kernels[labelOf(c.key)] ?? ''));
    }
    for (final Map<String, String> s in specs) {
      final String l = s['label'] ?? '', v = s['value'] ?? '';
      if (l.startsWith(_kKernelPrefix) || !v.trim().endsWith('%')) continue;
      final String? k = keyOfLabel(l);
      if (k == null || kPctCoreCols.containsKey(k)) continue;
      final double? p = _num(v);
      if (p != null) rows.add(PurchasePctRow(defKey: k, pct: _plain(p), kernel: kernels[l] ?? ''));
    }
  }

  double get sum => rows.fold<double>(0, (double s, PurchasePctRow r) => s + (_num(r.pct.text) ?? 0));

  String? validate() {
    final Set<String> seen = <String>{};
    for (final PurchasePctRow r in rows) {
      if (r.defKey == null) return 'برای هر ردیف درصد، نوع درصد را انتخاب کنید';
      if (!seen.add(r.defKey!)) return 'هر نوع درصد فقط یک‌بار می‌تواند باشد';
      final double p = _num(r.pct.text) ?? -1;
      if (p < 0 || p > 100) return 'درصد «${labelOf(r.defKey)}» باید بین ۰ و ۱۰۰ باشد';
      final double? k = r.kernel.text.trim().isEmpty ? null : _num(r.kernel.text);
      if (k != null && (k <= 0 || k > 100)) return 'گرم مغز «${labelOf(r.defKey)}» باید بین ۰ و ۱۰۰ باشد';
      if (canPrice && r.separate && (MoneyField.stored(r.q) ?? -1) < 0) return 'قیمت «${labelOf(r.defKey)}» را وارد کنید';
      if (canPrice && r.separate && r.gram) {
        final double? g = _num(r.g.text) ?? k;
        if (g == null || g <= 0 || g > 100) return '«گرم مغز در ۱۰۰ گرم» برای «${labelOf(r.defKey)}» را وارد کنید';
      }
    }
    if (sum > 100.0001) return 'جمع درصدها از ۱۰۰ بیشتر است';
    if (canPrice && baseGram && ((_num(baseG.text) ?? 0) <= 0 || (_num(baseG.text) ?? 0) > 100)) return '«گرم مغز پسته اصلی» را (۰ تا ۱۰۰) وارد کنید';
    return null;
  }

  /// ستون‌های چهار درصد اصلی (غایب ⇒ null).
  Map<String, dynamic> fields() {
    final Map<String, dynamic> out = <String, dynamic>{for (final String c in kPctCoreCols.values) c: null};
    for (final PurchasePctRow r in rows) {
      final String? col = kPctCoreCols[r.defKey];
      if (col != null) out[col] = _num(r.pct.text);
    }
    return out;
  }

  /// درصدهای غیراصلی و گرم‌های مغز ⇒ مشخصات.
  List<Map<String, String>> specRows() => <Map<String, String>>[
        for (final PurchasePctRow r in rows)
          if (r.defKey != null && !kPctCoreCols.containsKey(r.defKey) && _num(r.pct.text) != null)
            <String, String>{'label': labelOf(r.defKey), 'value': '${_plain(_num(r.pct.text)!)}%'},
        for (final PurchasePctRow r in rows)
          if (r.defKey != null && _num(r.kernel.text) != null) <String, String>{'label': '$_kKernelPrefix${labelOf(r.defKey)}', 'value': _plain(_num(r.kernel.text)!)},
      ];

  bool get pricing => canPrice && (baseGram || rows.any((PurchasePctRow r) => r.separate));

  /// قیمت‌گذاری با موتور اتاق انس. null ⇒ قیمت پایه یا وزن نامعتبر.
  PriceBlendResult? blend(num? basePrice, double netKg) {
    if (basePrice == null || basePrice <= 0 || netKg <= 0) return null;
    return priceBlend(<String, dynamic>{
      'base_price': basePrice,
      'weight_kg': netKg,
      'ref_gram': refGram,
      'items': <Map<String, dynamic>>[
        for (final PurchasePctRow r in rows)
          if (r.separate && canPrice)
            <String, dynamic>{
              'pct': _num(r.pct.text) ?? 0,
              'q': MoneyField.stored(r.q),
              'gram_mode': r.gram,
              'g': _num(r.g.text) ?? _num(r.kernel.text),
            }
          else
            <String, dynamic>{'pct': _num(r.pct.text) ?? 0, 'q': null},
      ],
      if (baseGram) ...<String, dynamic>{'base_gram_mode': true, 'base_g': _num(baseG.text)},
    });
  }

  void dispose() {
    baseG.dispose();
    for (final PurchasePctRow r in rows) {
      r.dispose();
    }
  }
}

/// بخش «درصدها» (+ قیمت‌گذاری برای مالک/حسابدار) فرم خرید.
class PurchasePctSection extends StatelessWidget {
  const PurchasePctSection({super.key, required this.ctl, required this.basePrice, required this.netKg, required this.onChanged, this.readOnly = false});
  final PurchasePctCtl ctl;
  final num? basePrice;
  final double netKg;
  final VoidCallback onChanged;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final bool price = PurchasePctCtl.canPrice;
    final PriceBlendResult? res = ctl.pricing ? ctl.blend(basePrice, netKg) : null;
    final double sum = ctl.sum;
    InputDecoration dec(String l, {String? suffix, String? helper}) => InputDecoration(labelText: l, suffixText: suffix, helperText: helper, border: const OutlineInputBorder(), isDense: true);
    TextField num(TextEditingController c, String l, {String? suffix, double? width}) => TextField(
          controller: c,
          enabled: !readOnly,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: dec(l, suffix: suffix),
          onChanged: (_) => onChanged(),
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Row(children: <Widget>[
            const Expanded(child: Text('درصدها (مثل اتاق انس)', style: TextStyle(fontWeight: FontWeight.bold))),
            Text('جمع: ${_plain(double.parse(sum.toStringAsFixed(2)))}٪', style: TextStyle(color: sum > 100.0001 ? Colors.red : null, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          for (int i = 0; i < ctl.rows.length; i++) _row(context, ctl.rows[i], i, res, price, num, dec),
          if (!readOnly)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () {
                  ctl.rows.add(PurchasePctRow());
                  onChanged();
                },
                icon: const Icon(Icons.add),
                label: const Text('افزودن درصد'),
              ),
            ),
          if (price) ...<Widget>[
            const Divider(),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('خرید گرمی (پستهٔ اصلی)'),
              value: ctl.baseGram,
              onChanged: readOnly
                  ? null
                  : (bool? v) {
                      ctl.baseGram = v == true;
                      onChanged();
                    },
            ),
            if (ctl.baseGram) num(ctl.baseG, 'گرم مغز پستهٔ اصلی در ۱۰۰ گرم'),
            if (ctl.pricing)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(8)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  const Text('نتیجهٔ قیمت‌گذاری', style: TextStyle(fontWeight: FontWeight.bold)),
                  Text('وزن خالص: ${Fmt.kg(netKg)}  •  گرم مرجع (R): ${_plain(ctl.refGram)}'),
                  if (res == null)
                    const Text('قیمت پایه و وزن را وارد کنید', style: TextStyle(color: Colors.black54))
                  else if (!res.ok)
                    Text('محاسبه ممکن نیست (${res.error})', style: const TextStyle(color: Colors.red))
                  else ...<Widget>[
                    Text('میانگین هر کیلو (فی خرید): ${Fmt.money(res.avgPerKg)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('مبلغ کل: ${Fmt.money(res.total)}'),
                  ],
                ]),
              ),
          ],
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, PurchasePctRow r, int i, PriceBlendResult? res, bool price,
      TextField Function(TextEditingController, String, {String? suffix, double? width}) num, InputDecoration Function(String, {String? suffix, String? helper}) dec) {
    double? eff;
    if (res != null && res.ok && i < res.lines.length) eff = res.lines[i].effQ;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              initialValue: ctl.defs.any((Map<String, dynamic> d) => d['key'] == r.defKey) ? r.defKey : null,
              isExpanded: true,
              decoration: dec('نوع درصد'),
              items: <DropdownMenuItem<String>>[
                for (final Map<String, dynamic> d in ctl.defs) DropdownMenuItem<String>(value: '${d['key']}', child: Text('${d['label'] ?? d['key']}')),
              ],
              onChanged: readOnly
                  ? null
                  : (String? v) {
                      r.defKey = v;
                      onChanged();
                    },
            ),
          ),
          SizedBox(width: 110, child: num(r.pct, 'درصد', suffix: '٪')),
          SizedBox(width: 150, child: num(r.kernel, 'گرم مغز (اختیاری)', suffix: 'g')),
          if (!readOnly)
            IconButton(
              tooltip: 'حذف ردیف',
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                ctl.rows.remove(r);
                r.dispose();
                onChanged();
              },
            ),
        ]),
        if (price) ...<Widget>[
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('قیمت جدا'),
            value: r.separate,
            onChanged: readOnly
                ? null
                : (bool? v) {
                    r.separate = v == true;
                    if (!r.separate) r.gram = false;
                    final double? k = _num(r.kernel.text);
                    if (r.separate && k != null) {
                      r.gram = true; // مثل اتاق انس: گرم ثبت‌شده خودکار اعمال می‌شود
                      if (r.g.text.trim().isEmpty) r.g.text = _plain(k);
                    }
                    onChanged();
                  },
          ),
          if (r.separate) ...<Widget>[
            MoneyField(controller: r.q, label: 'قیمت کیلویی «${ctl.labelOf(r.defKey)}»', onChanged: onChanged),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('خرید گرمی'),
              value: r.gram,
              onChanged: readOnly
                  ? null
                  : (bool? v) {
                      r.gram = v == true;
                      onChanged();
                    },
            ),
            if (r.gram) num(r.g, 'گرم مغز در ۱۰۰ گرم'),
            if (eff != null) Text('قیمت مؤثر کیلویی: ${Fmt.money(eff.round())}', style: const TextStyle(color: Colors.black54)),
          ],
        ],
      ]),
    );
  }
}
