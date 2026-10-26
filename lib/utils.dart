import 'dart:convert';
import 'dart:typed_data';

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// تبدیل ارقام فارسی/عربی به انگلیسی و پاکسازی جداکننده‌ها
String toEnDigits(String s) {
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var out = s;
  for (var i = 0; i < 10; i++) {
    out = out.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
  }
  return out
      .replaceAll('٫', '.')
      .replaceAll('/', '.')
      .replaceAll('٬', '')
      .replaceAll(',', '');
}

double? parseNum(String? s) {
  if (s == null) return null;
  final t = toEnDigits(s.trim());
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

String toFaDigits(String s) {
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  return s.replaceAllMapped(RegExp(r'\d'), (m) => fa[int.parse(m[0]!)]);
}

/// عدد با جداکننده هزارگان و ارقام فارسی
String faNum(num v, {int dec = 2}) {
  var s = v.toStringAsFixed(dec);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  final parts = s.split('.');
  final neg = parts[0].startsWith('-');
  final ip = neg ? parts[0].substring(1) : parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < ip.length; i++) {
    if (i > 0 && (ip.length - i) % 3 == 0) buf.write(',');
    buf.write(ip[i]);
  }
  final result =
      '${neg ? '-' : ''}$buf${parts.length > 1 ? '.${parts[1]}' : ''}';
  return toFaDigits(result).replaceAll(',', '٬').replaceAll('.', '٫');
}

/// عدد ساده (بدون جداکننده) برای پر کردن فیلدها
String plain(num v) {
  var s = v.toStringAsFixed(3);
  s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s;
}

/// فرمت‌کننده زنده اعداد با جداکننده هزارگان هنگام تایپ (برای فیلد قیمت)
class ThousandsInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits =
        toEnDigits(newValue.text).replaceAll(RegExp(r'[^0-9.]'), '');
    if (digits.isEmpty) {
      return newValue.copyWith(text: '');
    }
    final firstDot = digits.indexOf('.');
    var intPart = firstDot == -1 ? digits : digits.substring(0, firstDot);
    var decPart = firstDot == -1 ? '' : digits.substring(firstDot);
    // فقط یک نقطه اعشار مجاز است
    decPart = decPart.isEmpty ? '' : '.${decPart.substring(1).replaceAll('.', '')}';
    intPart = intPart.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    final formatted = '$buf$decPart';
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

// ==================== تبدیل دقیق شمسی <-> میلادی ====================
// پیاده‌سازی الگوریتم رسمی تقویم شمسی ایران (بر پایه شمارش روز ژولیوسی و
// جدول کبیسه‌های نامنظم رسمی)، به‌جای تخمین ساده‌ی چرخه ۳۳ ساله که در
// برخی سال‌ها (مثلاً نزدیک ۱۴۰۳-۱۴۰۴) یک روز خطا داشت. این نسخه با تست
// رفت‌وبرگشت روزانه از سال ۱۹۰۰ تا ۲۱۰۰ میلادی راستی‌آزمایی شده است.

int _divp(int a, int b) => a ~/ b;

int _g2jdn(int y, int m, int d) {
  final a = (14 - m) ~/ 12;
  final y2 = y + 4800 - a;
  final m2 = m + 12 * a - 3;
  return d +
      (153 * m2 + 2) ~/ 5 +
      365 * y2 +
      y2 ~/ 4 -
      y2 ~/ 100 +
      y2 ~/ 400 -
      32045;
}

List<int> _jdn2g(int jdn) {
  final a = jdn + 32044;
  final b = (4 * a + 3) ~/ 146097;
  final c = a - (146097 * b) ~/ 4;
  final d = (4 * c + 3) ~/ 1461;
  final e = c - (1461 * d) ~/ 4;
  final m = (5 * e + 2) ~/ 153;
  final day = e - (153 * m + 2) ~/ 5 + 1;
  final month = m + 3 - 12 * (m ~/ 10);
  final year = 100 * b + d - 4800 + m ~/ 10;
  return [year, month, day];
}

const List<int> _kJalaliBreaks = [
  -61, 9, 38, 199, 426, 686, 756, 818, 1111, 1181,
  1210, 1635, 2060, 2097, 2192, 2262, 2324, 2394, 2456, 3178, //
];

class _JalCal {
  final int leap; // ۰ یعنی jy کبیسه است (اسفند ۳۰ روزه)
  final int gy;
  final int march; // روز میلادی (در ماه مارس) که سال شمسی jy از آن آغاز می‌شود
  _JalCal(this.leap, this.gy, this.march);
}

_JalCal _jalCal(int jy) {
  final bl = _kJalaliBreaks.length;
  final gy = jy + 621;
  var leapJ = -14;
  var jp = _kJalaliBreaks[0];
  var jump = 0;
  for (var i = 1; i < bl; i++) {
    final jm = _kJalaliBreaks[i];
    jump = jm - jp;
    if (jy < jm) break;
    leapJ = leapJ + _divp(jump, 33) * 8 + _divp(jump % 33, 4);
    jp = jm;
  }
  var n = jy - jp;
  leapJ = leapJ + _divp(n, 33) * 8 + _divp((n % 33) + 3, 4);
  if (jump % 33 == 4 && jump - n == 4) leapJ += 1;
  final leapG = _divp(gy, 4) - _divp((_divp(gy, 100) + 1) * 3, 4) - 150;
  final march = 20 + leapJ - leapG;
  if (jump - n < 6) n = n - jump + _divp(jump + 4, 33) * 33;
  var leap = ((n + 1) % 33 - 1) % 4;
  if (leap < 0) leap += 4;
  return _JalCal(leap, gy, march);
}

/// آیا سال شمسی jy کبیسه است (اسفند آن ۳۰ روز دارد)
bool isLeapJalaliYear(int jy) => _jalCal(jy).leap == 0;

/// تعداد روزهای ماه jm از سال شمسی jy
int daysInJalaliMonth(int jy, int jm) {
  if (jm <= 6) return 31;
  if (jm <= 11) return 30;
  return isLeapJalaliYear(jy) ? 30 : 29;
}

int _j2jdn(int jy, int jm, int jd) {
  final c = _jalCal(jy);
  return _g2jdn(c.gy, 3, c.march) +
      31 * (jm - 1) -
      _divp(jm, 7) * (jm - 7) +
      jd -
      1;
}

List<int> _jdn2j(int jdn) {
  final gy0 = _jdn2g(jdn)[0];
  var jy = gy0 - 621;
  var c = _jalCal(jy);
  var jdn1f = _g2jdn(c.gy, 3, c.march);
  if (jdn < jdn1f) {
    jy -= 1;
    c = _jalCal(jy);
    jdn1f = _g2jdn(c.gy, 3, c.march);
  }
  var k = jdn - jdn1f;
  int jm, jd;
  if (k <= 185) {
    jm = 1 + k ~/ 31;
    jd = (k % 31) + 1;
  } else {
    k -= 186;
    jm = 7 + k ~/ 30;
    jd = (k % 30) + 1;
  }
  return [jy, jm, jd];
}

List<int> gregorianToJalali(int gy, int gm, int gd) => _jdn2j(_g2jdn(gy, gm, gd));

/// (سال، ماه، روز) شمسی به میلادی — دقیق (بدون خطای گرد کردن)
DateTime jalaliToGregorian(int jy, int jm, int jd) {
  final g = _jdn2g(_j2jdn(jy, jm, jd));
  return DateTime(g[0], g[1], g[2]);
}

/// تاریخ شمسی از رشته ISO
String jalaliDate(String iso) {
  final d = DateTime.parse(iso);
  final j = gregorianToJalali(d.year, d.month, d.day);
  final m = j[1].toString().padLeft(2, '0');
  final day = j[2].toString().padLeft(2, '0');
  return toFaDigits('${j[0]}/$m/$day');
}

String jalaliDateFromDt(DateTime d) {
  final j = gregorianToJalali(d.year, d.month, d.day);
  final m = j[1].toString().padLeft(2, '0');
  final day = j[2].toString().padLeft(2, '0');
  return toFaDigits('${j[0]}/$m/$day');
}

const List<String> kJalaliMonthNames = [
  'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', //
  'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند', //
];

/// نام کوتاه روزهای هفته با شروع از شنبه (تقویم رسمی ایران)
const List<String> kJalaliWeekdayShort = ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج'];

/// اندیس روز هفته با شروع از شنبه=۰ برای یک تاریخ میلادی
int jalaliWeekdayIndex(DateTime d) => (d.weekday + 1) % 7;

/// عکس رسید در دیتابیس (مثل سرور/وب) به‌صورت data-URL ذخیره می‌شود؛ این تابع بایت‌های تصویر را برمی‌گرداند
Uint8List photoBytes(String dataUrl) {
  final i = dataUrl.indexOf(',');
  return base64Decode(i >= 0 ? dataUrl.substring(i + 1) : dataUrl);
}

/// مبلغ دلاری (پلن ارزی) با جداکننده هزارگان و ارقام فارسی
String faUsd(num v, {int dec = 2}) => '${faNum(v, dec: dec)} دلار';

double _numOf(dynamic v) => (v as num?)?.toDouble() ?? 0;

/// هزینهٔ جانبیِ هر کیلو از یک خرید (کارگر + حمل‌ونقل/باسکولِ ثبت‌شده در خرید ÷ وزن خالص همان خرید)
double purchaseExtraPerKg(Map<String, dynamic> item) {
  final net = _numOf(item['p_net_weight']);
  if (net <= 0) return 0;
  return (_numOf(item['p_labor_cost']) + _numOf(item['p_transport_cost'])) / net;
}

/// هزینهٔ جانبیِ ثبت‌شده در خودِ فروش (کارگر + حمل‌ونقل/باسکول)
double saleExtraCosts(Map<String, dynamic> sale) => _numOf(sale['labor_cost']) + _numOf(sale['transport_cost']);

/// بهای تمام‌شدهٔ اقلامِ یک فروش به تومان: (فی خرید + هزینهٔ جانبیِ خرید به‌ازای کیلو) × وزن
double saleItemsCost(Map<String, dynamic> sale) {
  var c = 0.0;
  for (final it in (sale['items'] as List)) {
    final m = it as Map<String, dynamic>;
    c += _numOf(m['weight']) * (_numOf(m['cost_price']) + purchaseExtraPerKg(m));
  }
  return c;
}

/// سود/زیان خالص یک فروش به تومان = مبلغ فروش − بهای تمام‌شده − هزینه‌های جانبیِ خرید و فروش
double saleProfit(Map<String, dynamic> sale) =>
    _numOf(sale['net_weight']) * _numOf(sale['price']) - saleItemsCost(sale) - saleExtraCosts(sale);

/// سهمِ یک قلمِ فروش از هزینه‌های جانبیِ خودِ فروش (به نسبت وزن)
double saleExtraShare(Map<String, dynamic> sale, Map<String, dynamic> item) {
  var totalW = 0.0;
  for (final it in (sale['items'] as List)) {
    totalW += _numOf((it as Map)['weight']);
  }
  if (totalW <= 0) return 0;
  return saleExtraCosts(sale) * _numOf(item['weight']) / totalW;
}

/// درآمد، بها و سود دلاریِ یک فروش (پلن ارزی).
///  * درآمد دلاری = (وزن خالص × فی فروش تومانی) ÷ قیمت دلارِ روز فروش
///  * بهای دلاری = وزن × فی دلاریِ خریدِ همان پسته (در مخلوط: میانگین وزنیِ مبدأها)
///  * هزینه‌های جانبی (کارگر، حمل‌ونقل/باسکول) تومانی‌اند و با قیمت دلارِ روز فروش به دلار تبدیل و از سود کم می‌شوند
/// اگر قیمت دلار فروش یا فی دلاریِ خرید ثبت نشده باشد (مثلاً خرید قبل از ارتقای پلن) null برمی‌گرداند.
({double revenue, double cost, double profit})? saleUsd(Map<String, dynamic> sale) {
  final rate = (sale['usd_rate'] as num?)?.toDouble();
  if (rate == null || rate <= 0) return null;
  var cost = 0.0;
  var extraToman = saleExtraCosts(sale);
  for (final it in (sale['items'] as List)) {
    final cu = (it['cost_price_usd'] as num?)?.toDouble();
    if (cu == null) return null;
    final w = (it['weight'] as num).toDouble();
    cost += w * cu;
    extraToman += w * purchaseExtraPerKg(it as Map<String, dynamic>);
  }
  cost += extraToman / rate;
  final revenue = (sale['net_weight'] as num).toDouble() * (sale['price'] as num).toDouble() / rate;
  return (revenue: revenue, cost: cost, profit: revenue - cost);
}


/// تماس با پشتیبانی: روی گوشی شماره‌گیر باز می‌شود؛ روی ویندوز (تلفن ندارد) شماره کپی می‌شود.
Future<void> callSupport(BuildContext context, String callNumber, String displayPhone) async {
  if (Platform.isWindows) {
    await Clipboard.setData(ClipboardData(text: displayPhone));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('شماره پشتیبانی کپی شد: $displayPhone')));
    }
    return;
  }
  await launchUrl(Uri.parse('tel:$callNumber'));
}
