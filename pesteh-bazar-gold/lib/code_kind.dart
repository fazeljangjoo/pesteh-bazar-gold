import 'package:flutter/material.dart';

// T2 (ردیابی پسته) — آینهٔ Dart از public_html/backend/api/code_kind.php (منبع حقیقت = سرور).
// تست مشترک: test/code_kind_cases.json (کپی بایت‌به‌بایت از backend/tests/code_kind_cases.json).
// آینهٔ JS: public_html/app/code_kind.js (باید همین نتایج را بدهد).
// هیچ مبلغی در این فایل نیست. بخش‌های خالص (بدون Flutter-UI) = codeKindOf / codeLetterForCategoryName /
// groupColorValue / mixGroupKeys؛ فقط kindColor و CodeChip به BuildContext نیاز دارند.

/// نوع → حرف (کدهای جدید). ترتیب و مقدارها باید با PB_CODE_LETTERS سرور یکی باشد.
const Map<String, String> kCodeLetters = {
  'khandan': 'KH',
  'dombest': 'D',
  'other': 'G',
  'mix': 'M',
  'separation': 'S',
  'workshop': 'W',
  'outside': 'B',
  'consignment': 'C',
  'received': 'R',
  'orchard': 'H',
};

/// پیشوند قدیمی → نوع (فقط خواندن). KH قدیمی جدا بررسی می‌شود (KH + حداکثر ۱۱ رقم).
const Map<String, String> _kLegacyPrefix = {'MX': 'mix', 'K': 'separation', 'PR': 'outside', 'OR': 'orchard'};

/// نام فارسی هر نوع.
const Map<String, String> kCodeKindLabels = {
  'khandan': 'خندان',
  'dombest': 'دهنبست',
  'other': 'سایر دسته‌ها',
  'mix': 'مخلوط',
  'separation': 'جداسازی',
  'workshop': 'کارگاه داخلی',
  'outside': 'کارگاه بیرونی',
  'consignment': 'امانی',
  'received': 'دریافتی برای دیگران',
  'orchard': 'باغ',
  'custom': 'حرف سفارشی',
  'unknown': 'نامشخص',
};

/// نتیجهٔ تشخیص نوع از روی کد.
class CodeKind {
  /// khandan|dombest|other|mix|separation|workshop|outside|consignment|received|orchard|custom|unknown
  final String kind;

  /// حرف/پیشوند خوانده‌شده از کد (بزرگ)؛ برای unknown خالی.
  final String letter;

  /// قالب قدیمی (MX… / K… / PR… / OR… / KH+حداکثر ۱۱ رقم).
  final bool legacy;

  const CodeKind(this.kind, this.letter, this.legacy);

  /// کلید جدول رنگ: همان kind (قدیمی‌ها هم‌رنگ نوع خودشان‌اند).
  String get colorKey => kind;

  bool get isUnknown => kind == 'unknown';

  /// برچسب فارسی؛ قدیمی‌ها با توضیح («مخلوط (قدیمی)»، «خندان (قدیمی/عمومی)»، «جداسازی/کارگاه (قدیمی)»).
  String get label {
    if (!legacy) return kCodeKindLabels[kind] ?? kCodeKindLabels['unknown']!;
    switch (letter) {
      case 'MX':
        return 'مخلوط (قدیمی)';
      case 'K':
        return 'جداسازی/کارگاه (قدیمی)';
      case 'PR':
        return 'کارگاه بیرونی (قدیمی)';
      case 'OR':
        return 'باغ (قدیمی)';
      case 'KH':
        return 'خندان (قدیمی/عمومی)';
    }
    return kCodeKindLabels[kind] ?? kCodeKindLabels['unknown']!;
  }

  @override
  bool operator ==(Object o) => o is CodeKind && o.kind == kind && o.letter == letter && o.legacy == legacy;

  @override
  int get hashCode => Object.hash(kind, letter, legacy);

  @override
  String toString() => 'CodeKind($kind,$letter,legacy=$legacy)';
}

const CodeKind _kUnknown = CodeKind('unknown', '', false);

/// فقط a-z را بزرگ می‌کند (مثل strtoupper سرور؛ بدون تبدیل یونیکد).
String _upperAscii(String s) => s.replaceAllMapped(RegExp(r'[a-z]'), (m) => m[0]!.toUpperCase());

final RegExp _kLeadRe = RegExp(r'^([A-Z]{1,2})(-|\d)');
final RegExp _kKhRestRe = RegExp(r'^\d{1,11}$');

/// تشخیص نوع از روی خودِ کد (خالص؛ همان pb_code_kind_of سرور).
/// [isMix] فقط وقتی به کار می‌آید که از روی کد چیزی فهمیده نشود: isMix==1 ⇒ مخلوط.
CodeKind codeKindOf(String? code, {int isMix = 0}) {
  final c = _upperAscii((code ?? '').trim());
  final m = _kLeadRe.firstMatch(c);
  if (c.isEmpty || m == null) {
    return isMix == 1 ? const CodeKind('mix', 'M', false) : _kUnknown;
  }
  final l = m.group(1)!;
  final rest = c.substring(l.length);
  final legacyKind = _kLegacyPrefix[l];
  if (legacyKind != null) return CodeKind(legacyKind, l, true);
  if (l == 'KH') return CodeKind('khandan', 'KH', _kKhRestRe.hasMatch(rest));
  for (final e in kCodeLetters.entries) {
    if (e.value == l) return CodeKind(e.key, l, false);
  }
  return CodeKind('custom', l, false);
}

/// کد موقتِ محلیِ هنوز ارسال‌نشده (`N<id منفی>`؛ ۱ تا ۴ رقم). کدهای سرور همیشه ≥۵ رقم‌اند.
/// عمداً داخل codeKindOf نیست تا با سرور (که N را «سفارشی» می‌داند) هم‌خوان بماند.
bool isPendingCode(String? code) => RegExp(r'^N\d{1,4}$').hasMatch((code ?? '').trim());

/// نام دسته → حرف (آینهٔ pb_code_letter_for_name): «خندان» → KH، «دهنبست/دهن‌بست/دهن بست» → D، غیر از این → G.
String codeLetterForCategoryName(String name) {
  var n = name.replaceAll('\u200C', '').replaceAll('\u200D', '').replaceAll(' ', '').replaceAll('\u00A0', '');
  n = n.replaceAll('ي', 'ی').replaceAll('ك', 'ک').replaceAll('ە', 'ه');
  if (n.contains('خندان')) return kCodeLetters['khandan']!;
  if (n.contains('دهنبست')) return kCodeLetters['dombest']!;
  return kCodeLetters['other']!;
}

// ---------------------------------------------------------------- رنگ‌ها

/// رنگ هر نوع برای چیپ حرف (تم روشن) و (تم تیره). کلید = CodeKind.colorKey.
const Map<String, int> _kKindLight = {
  'khandan': 0xFF2E7D32,
  'dombest': 0xFF6D4C41,
  'other': 0xFF607D8B,
  'mix': 0xFF7B1FA2,
  'separation': 0xFF0277BD,
  'workshop': 0xFFEF6C00,
  'outside': 0xFF00838F,
  'consignment': 0xFFAD1457,
  'received': 0xFF3949AB,
  'orchard': 0xFF827717,
  'custom': 0xFF455A64,
  'unknown': 0xFF757575,
};
const Map<String, int> _kKindDark = {
  'khandan': 0xFF81C784,
  'dombest': 0xFFBCAAA4,
  'other': 0xFF90A4AE,
  'mix': 0xFFCE93D8,
  'separation': 0xFF4FC3F7,
  'workshop': 0xFFFFB74D,
  'outside': 0xFF4DD0E1,
  'consignment': 0xFFF48FB1,
  'received': 0xFF9FA8DA,
  'orchard': 0xFFDCE775,
  'custom': 0xFFB0BEC5,
  'unknown': 0xFFBDBDBD,
};

/// مقدار عددی رنگ نوع (خالص؛ برای تست).
int kindColorValue(CodeKind k, {bool dark = false}) =>
    (dark ? _kKindDark : _kKindLight)[k.colorKey] ?? (dark ? _kKindDark : _kKindLight)['unknown']!;

/// رنگ چیپ نوع، سازگار با تم روشن/تیره.
Color kindColor(BuildContext context, CodeKind k) =>
    Color(kindColorValue(k, dark: Theme.of(context).brightness == Brightness.dark));

/// پالت ثابت ۱۰ رنگ «گروه مخلوط» (اندیس = key mod 10؛ پایدار بین دستگاه‌ها، بدون ذخیره).
/// همین ۱۰ مقدار در code_kind.js هم هست (تست مشترک group_color_cases).
const List<int> kGroupPalette = [
  0xFFE53935, // قرمز
  0xFF1E88E5, // آبی
  0xFF43A047, // سبز
  0xFFFB8C00, // نارنجی
  0xFF8E24AA, // بنفش
  0xFF00ACC1, // فیروزه‌ای
  0xFFD81B60, // صورتی
  0xFF6D4C41, // قهوه‌ای
  0xFF3949AB, // نیلی
  0xFFC0CA33, // لیمویی
];

/// اندیس پالت برای یک کلید گروه (کلید منفی = شناسهٔ موقتِ محلی هم درست جواب می‌دهد).
int groupColorIndex(int key) => ((key % kGroupPalette.length) + kGroupPalette.length) % kGroupPalette.length;

int groupColorValue(int key) => kGroupPalette[groupColorIndex(key)];

/// رنگ گروه مخلوط برای کلید [key] (شناسهٔ لات مخلوط).
Color groupColor(int key) => Color(groupColorValue(key));

int? _asInt(dynamic v) => v is num ? v.toInt() : (v == null ? null : int.tryParse(v.toString()));

/// کلید گروه مخلوط برای هر لات (خالص). قواعد PLAN:
///  • لات مخلوط (is_mix=1) همیشه کلید خودش را دارد (حتی اگر خودش وارد مخلوط بزرگ‌تری شده باشد).
///  • لات غیرمخلوط (is_mix=0) که وارد چند مخلوط شده ⇒ کلید «جدیدترین» مخلوط (بزرگ‌ترین id).
///  • لات بدون مخلوط، و لات‌های is_mix=2/3 ⇒ null (بدون رنگ گروه).
/// [lots]: هر عنصر `id` و `is_mix`. [mixSources]: هر عنصر مخلوط و منبع آن —
/// `mix_purchase_id`/`source_purchase_id` (جدول محلی گوشی/سیستم) یا `mix_id`/`source_id`.
/// خروجی: برای «هر» لات ورودی یک ورودی (id → کلید یا null).
Map<int, int?> mixGroupKeys(Iterable<Map<String, dynamic>> lots, Iterable<Map<String, dynamic>> mixSources) {
  final newestMixOf = <int, int>{}; // sourceId → بزرگ‌ترین mixId
  for (final s in mixSources) {
    final mix = _asInt(s['mix_purchase_id'] ?? s['mix_id']);
    final src = _asInt(s['source_purchase_id'] ?? s['source_id']);
    if (mix == null || src == null) continue;
    final cur = newestMixOf[src];
    if (cur == null || mix > cur) newestMixOf[src] = mix;
  }
  final out = <int, int?>{};
  for (final l in lots) {
    final id = _asInt(l['id']);
    if (id == null) continue;
    final kind = _asInt(l['is_mix']) ?? 0;
    if (kind == 1) {
      out[id] = id;
    } else if (kind == 0) {
      out[id] = newestMixOf[id];
    } else {
      out[id] = null;
    }
  }
  return out;
}

/// یک ردیف راهنمای گروه‌های مخلوط (T3a).
class MixGroupCount {
  /// کلید گروه = شناسهٔ لات مخلوط.
  final int key;

  /// شناسهٔ لات مخلوط اگر خودش در فهرست [lots] باشد، وگرنه null (مثلاً فیلتر شده).
  final int? mixLotId;

  /// تعداد لات‌های فهرست در این گروه (خودِ مخلوط هم اگر در فهرست باشد).
  final int count;
  const MixGroupCount(this.key, this.mixLotId, this.count);

  @override
  bool operator ==(Object other) =>
      other is MixGroupCount && other.key == key && other.mixLotId == mixLotId && other.count == count;
  @override
  int get hashCode => Object.hash(key, mixLotId, count);
  @override
  String toString() => 'MixGroupCount($key, $mixLotId, $count)';
}

/// شمارش لات‌های هر گروه مخلوط برای راهنمای انبار (خالص). [keys] خروجی [mixGroupKeys] (یا همان `mix_group` سرور).
/// فقط لات‌های موجود در [lots] شمرده می‌شوند؛ لات تکراری یک‌بار؛ لات بدون کلید (null/غایب) نادیده.
/// ترتیب پایدار: key نزولی (جدیدترین مخلوط اول).
List<MixGroupCount> mixGroupCounts(Iterable<Map<String, dynamic>> lots, Map<int, int?> keys) {
  final seen = <int>{};
  final counts = <int, int>{};
  for (final l in lots) {
    final id = _asInt(l['id']);
    if (id == null || !seen.add(id)) continue;
    final k = keys[id];
    if (k == null) continue;
    counts[k] = (counts[k] ?? 0) + 1;
  }
  final ordered = counts.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final k in ordered) MixGroupCount(k, seen.contains(k) ? k : null, counts[k]!)];
}

// ---------------------------------------------------------------- ویجت

/// چیپ کوچک کد پسته: حرف نوع داخل مربع رنگی + کد کامل کنارش (همیشه چپ‌به‌راست تا خط‌تیره‌ها جابه‌جا نشوند).
/// کد موقتِ ارسال‌نشده (N…) خاکستری و با برچسب «در صف ارسال» نشان داده می‌شود.
class CodeChip extends StatelessWidget {
  final String? code;
  final int isMix;
  final double fontSize;
  const CodeChip({super.key, required this.code, this.isMix = 0, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final text = (code == null || code!.trim().isEmpty) ? '-' : code!.trim();
    final pending = isPendingCode(text);
    final k = pending ? _kUnknown : codeKindOf(text, isMix: isMix);
    final c = kindColor(context, k);
    final letter = pending ? '…' : (k.letter.isEmpty ? '?' : k.letter);
    final tip = pending ? 'هنوز به سرور ارسال نشده' : k.label;
    return Tooltip(
      message: tip,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: c.withAlpha(38),
                border: Border.all(color: c.withAlpha(140)),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(letter, style: TextStyle(fontSize: fontSize - 1, fontWeight: FontWeight.w700, color: c, height: 1.15)),
            ),
            const SizedBox(width: 5),
            Text(text, style: TextStyle(fontSize: fontSize)),
          ],
        ),
      ),
    );
  }
}
