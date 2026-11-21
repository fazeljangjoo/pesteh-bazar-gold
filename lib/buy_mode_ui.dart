import 'package:flutter/material.dart';

import 'fmt.dart' show Fmt;
import 'utils.dart' show faNum;

/// v85 — سه روش خرید (فایل مشترک اندروید و ویندوز؛ فرم خرید مالک/حسابدار و قطعی‌سازی اتاق انس) برای پستهٔ اصلی و هر درصد:
///   [BuyMode.fixed]   «خرید با یک فی»: فی کیلویی همان عدد واردشده است.
///   [BuyMode.base50]  «فی پایه ۵۰ گرم»: فی واردشده ÷ ۵۰ × گرم ⇒ فی مؤثر.
///   [BuyMode.perGram] «خرید گرمی»: فی هر گرم از کاربر؛ فی پایه ۵۰ گرم = فی × ۵۰ (نمایش)، فی مؤثر = فی × گرم.
/// موتور قیمت (pricing_engine = آینهٔ pb_price_blend) بدون تغییر: هر دو حالت گرمی با gram_mode و q = فی پایهٔ R گرمی فرستاده می‌شوند
/// (R = گرم مرجع سرور، پیش‌فرض ۵۰)؛ در «خرید گرمی» q = فی هر گرم × R ⇒ (q ÷ R) × گرم = فی هر گرم × گرم.
enum BuyMode { fixed, base50, perGram }

const Map<BuyMode, String> kBuyModeLabels = <BuyMode, String>{
  BuyMode.fixed: 'خرید با یک فی',
  BuyMode.base50: 'فی پایه ۵۰ گرم',
  BuyMode.perGram: 'خرید گرمی',
};

bool buyModeIsGram(BuyMode m) => m != BuyMode.fixed;

/// مقدار ورودی موتور (فی کیلویی یا فی پایهٔ R گرمی) از عدد واردشدهٔ کاربر.
double buyModeEngineValue(BuyMode m, double input, double ref) => m == BuyMode.perGram ? input * ref : input;

/// «فی پایه R گرم» (نام نمایشی؛ R = ۵۰ ⇒ «فی پایه ۵۰ گرم»).
String buyModeBaseName(double ref) => ref == 50 ? 'فی پایه ۵۰ گرم' : 'فی پایه ${faNum(ref, dec: ref == ref.roundToDouble() ? 0 : 2)} گرم';

/// برچسب فیلد قیمت در هر روش. [of] = نام درصد یا «پستهٔ اصلی».
String buyModeInputLabel(BuyMode m, {String? of, double ref = 50}) {
  final String sfx = of == null || of.isEmpty ? '' : ' «$of»';
  switch (m) {
    case BuyMode.fixed:
      return 'فی کیلویی$sfx';
    case BuyMode.base50:
      return '${buyModeBaseName(ref)}$sfx';
    case BuyMode.perGram:
      return 'فی هر گرم$sfx';
  }
}

/// فی مؤثر کیلویی یک روش (null = داده کافی نیست).
double? buyModeEffective(BuyMode m, double? input, double? gram, double ref) {
  if (input == null || input < 0) return null;
  if (m == BuyMode.fixed) return input;
  if (gram == null || gram <= 0 || gram > 100 || ref <= 0) return null;
  return buyModeEngineValue(m, input, ref) / ref * gram;
}

/// انتخاب روش خرید (سه تراشه).
class BuyModeChips extends StatelessWidget {
  const BuyModeChips({super.key, required this.value, required this.onChanged, this.enabled = true, this.label});
  final BuyMode value;
  final ValueChanged<BuyMode> onChanged;
  final bool enabled;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
        if (label != null) Text(label!, style: const TextStyle(fontWeight: FontWeight.w600)),
        for (final BuyMode m in BuyMode.values)
          ChoiceChip(
            label: Text(kBuyModeLabels[m]!),
            selected: value == m,
            onSelected: enabled ? (bool on) => on ? onChanged(m) : null : null,
          ),
      ]),
    );
  }
}

/// خط توضیح زیر فیلد قیمت: «خرید گرمی» ⇒ فی پایه ۵۰ گرم = فی × ۵۰؛ هر دو حالت گرمی ⇒ فی مؤثر.
Widget buyModeInfo(BuildContext context, BuyMode m, {double? input, double? gram, double ref = 50, double? effective}) {
  final List<String> parts = <String>[];
  if (m == BuyMode.perGram && input != null) parts.add('${buyModeBaseName(ref)}: ${Fmt.money((input * ref).round())}');
  if (m == BuyMode.base50 && input != null) parts.add('فی هر گرم: ${Fmt.money((input / ref).round())}');
  if (m != BuyMode.fixed && gram != null) parts.add('گرم: ${faNum(gram, dec: gram == gram.roundToDouble() ? 0 : 2)}');
  final double? eff = effective ?? buyModeEffective(m, input, gram, ref);
  if (m != BuyMode.fixed) parts.add(eff == null ? 'فی مؤثر: — (گرم را وارد کنید)' : 'فی مؤثر: ${Fmt.money(eff.round())}');
  if (parts.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(parts.join('  •  '), style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
  );
}
