// S6.T1 — ترجمهٔ دقیق `pb_price_blend` (backend/api/pricing_engine.php).
// تابع خالص؛ بدون DB/UI. منبع حقیقت = PHP؛ هر تغییری باید با tests/pricing_cases.json هم‌خوان بماند.
//
// ورودی: base_price (P)، weight_kg (W)، ref_gram (R، پیش‌فرض 50)،
//   items: [{pct 0..100, q (قیمت کیلویی همان درصد؛ null/'' = بدون تیک → در قیمت اصلی)، gram_mode (bool)، g (گرم مغز در ۱۰۰ گرم)}]
// حالت A: میانگین = P·(1 − Σp_i/100) + Σ q_i·p_i/100   (Σ فقط روی درصدهای دارای q)
// حالت B: q مؤثر = (q / R) · g   (وقتی gram_mode فعال است؛ 0 < g ≤ 100)
// گرد: میانگین کیلویی به عدد صحیح؛ مبلغ کل = round(میانگین گردشده × W).
// خروجی: [PriceBlendResult.ok] یا کد خطا (همان کدهای PHP).

class PriceBlendLine {
  const PriceBlendLine({required this.pct, this.q, this.effQ, this.gramMode = false, this.g});
  final double pct;
  final double? q;
  final double? effQ;
  final bool gramMode;
  final double? g;
}

class PriceBlendResult {
  const PriceBlendResult._({required this.ok, this.error, this.avgPerKg = 0, this.total = 0, this.lines = const <PriceBlendLine>[]});

  factory PriceBlendResult.success(int avg, int total, List<PriceBlendLine> lines) =>
      PriceBlendResult._(ok: true, avgPerKg: avg, total: total, lines: lines);
  factory PriceBlendResult.failure(String code) => PriceBlendResult._(ok: false, error: code);

  final bool ok;
  final String? error;
  final int avgPerKg;
  final int total;
  final List<PriceBlendLine> lines;
}

/// معادل `is_numeric` در PHP برای مقادیر JSON (عدد یا رشتهٔ عددی؛ bool/null/لیست نه).
bool _isNumeric(Object? v) {
  if (v is num) return !v.isNaN && !v.isInfinite;
  if (v is String) {
    final String s = v.trim();
    if (s.isEmpty) return false;
    final double? d = double.tryParse(s);
    return d != null && !d.isNaN && !d.isInfinite;
  }
  return false;
}

double _toDouble(Object? v) => v is num ? v.toDouble() : double.parse((v as String).trim());

/// معادل `round($x, 6)` در PHP (نیم‌دور از صفر).
double _round6(double x) => (x * 1000000).roundToDouble() / 1000000;

/// معادل `(int)round($x, 6)`؛ `round()` دارت = نیم‌دور از صفر مثل PHP.
int _roundInt(double x) => x.round();

PriceBlendResult priceBlend(Map<String, dynamic> input) {
  PriceBlendResult err(String c) => PriceBlendResult.failure(c);

  for (final String k in const <String>['base_price', 'weight_kg']) {
    final Object? v = input[k];
    if (v == null || !_isNumeric(v) || _toDouble(v) < 0) return err('bad_$k');
  }
  final double P = _toDouble(input['base_price']);
  final double W = _toDouble(input['weight_kg']);
  final double R = input['ref_gram'] != null ? (_isNumeric(input['ref_gram']) ? _toDouble(input['ref_gram']) : 0.0) : 50.0;
  if (R <= 0) return err('bad_ref_gram');

  final Object? rawItems = input['items'] ?? <dynamic>[];
  if (rawItems is! List) return err('bad_items');

  double sumAll = 0.0, sumPriced = 0.0, acc = 0.0;
  final List<PriceBlendLine> lines = <PriceBlendLine>[];

  for (final Object? it in rawItems) {
    if (it is! Map || it['pct'] == null || !_isNumeric(it['pct'])) return err('bad_pct');
    final double p = _toDouble(it['pct']);
    if (p < 0 || p > 100) return err('bad_pct');
    sumAll += p;

    final Object? qRaw = it['q'];
    final bool gm = _truthy(it['gram_mode']);
    final Object? gRaw = it['g'];
    final double? g = (gRaw != null && gRaw != '') ? (_isNumeric(gRaw) ? _toDouble(gRaw) : 0.0) : null;

    if (qRaw == null || qRaw == '') {
      lines.add(PriceBlendLine(pct: p, gramMode: gm, g: g));
      continue;
    }
    if (!_isNumeric(qRaw) || _toDouble(qRaw) < 0) return err('bad_q');
    final double q = _toDouble(qRaw);
    double eff = q;
    if (gm) {
      if (g == null || g <= 0 || g > 100) return err('bad_gram');
      eff = (q / R) * g;
    }
    sumPriced += p;
    acc += eff * p / 100.0;
    lines.add(PriceBlendLine(pct: p, q: q, effQ: eff, gramMode: gm, g: g));
  }
  if (sumAll > 100.0000001) return err('sum_over_100');

  final int avg = _roundInt(_round6(P * (1 - sumPriced / 100.0) + acc));
  final int total = _roundInt(_round6(avg * W));
  return PriceBlendResult.success(avg, total, lines);
}

/// معادل `!empty()` در PHP برای مقدار gram_mode.
bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v != '' && v != '0';
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

/// پیام فارسی کدهای خطای موتور (هم‌معنی PB_INTAKE_ENGINE_ERRORS سرور؛ فقط برای نمایش پیش از پاسخ سرور).
const Map<String, String> kPriceEngineErrors = <String, String>{
  'bad_base_price': 'قیمت پایه نامعتبر است',
  'bad_weight_kg': 'وزن نامعتبر است',
  'bad_ref_gram': 'گرم مرجع نامعتبر است',
  'bad_items': 'اقلام قیمت‌گذاری نامعتبر است',
  'bad_pct': 'درصد نامعتبر است',
  'bad_q': 'قیمت درصد نامعتبر است',
  'bad_gram': '«گرم مغز» باید بیشتر از ۰ و حداکثر ۱۰۰ باشد',
  'sum_over_100': 'مجموع درصدها نمی‌تواند بیشتر از ۱۰۰ باشد',
};
